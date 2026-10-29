import { spawn } from 'node:child_process';
import { access, readdir, readFile, realpath, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

export async function runProcess(command, args, { cwd, env, timeoutMs = 120000, maxOutputBytes = 1024 * 1024 } = {}) {
  return new Promise((resolve) => {
    const grouped = process.platform !== 'win32';
    const child = spawn(command, args, { cwd, shell: false, detached: grouped, env: { ...process.env, ...env } });
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let outputTruncated = false;
    let outputBytes = 0;
    let settled = false;
    let forceTimer;
    const signal = name => { try { if (grouped && child.pid) process.kill(-child.pid, name); else child.kill(name); } catch (error) { if (error.code !== 'ESRCH') stderr = `${stderr.slice(0, 1024)}\nprocess 종료 실패: ${error.message}`; } };
    const stop = () => { signal('SIGTERM'); forceTimer ??= setTimeout(() => signal('SIGKILL'), 1500); };
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeoutMs);
    const append = (chunk, stream) => {
      const remaining = Math.max(0, maxOutputBytes - outputBytes);
      const accepted = chunk.subarray(0, remaining).toString();
      if (stream === 'stdout') stdout += accepted; else stderr += accepted;
      outputBytes += chunk.length;
      if (outputBytes > maxOutputBytes && !outputTruncated) { outputTruncated = true; stop(); }
    };
    const finish = (exitCode, error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer); clearTimeout(forceTimer);
      // 부모만 종료돼도 같은 실행 그룹의 남은 테스트 프로세스를 함께 정리한다.
      if (timedOut || outputTruncated) signal('SIGKILL');
      if (error) stderr = `${stderr.slice(0, Math.max(0, maxOutputBytes - 1000))}${error.message.slice(0, 1000)}`;
      resolve({ exitCode, stdout, stderr, timedOut, outputTruncated });
    };
    child.stdout?.on('data', chunk => append(chunk, 'stdout'));
    child.stderr?.on('data', chunk => append(chunk, 'stderr'));
    child.once('error', error => finish(null, error));
    child.once('close', exitCode => finish(exitCode));
  });
}

export async function containedPath(root, relative, { mustExist = true } = {}) {
  const base = await realpath(root);
  const candidate = path.resolve(base, relative);
  if (candidate !== base && !candidate.startsWith(`${base}${path.sep}`)) throw new Error('프로젝트 밖 경로는 사용할 수 없습니다.');
  let resolved;
  try { resolved = await realpath(candidate); } catch (error) {
    if (mustExist || error.code !== 'ENOENT') throw error;
    const ancestor = await containedPath(base, path.relative(base, path.dirname(candidate)), { mustExist: false });
    resolved = path.join(ancestor, path.basename(candidate));
  }
  if (resolved !== base && !resolved.startsWith(`${base}${path.sep}`)) throw new Error('프로젝트 밖 symlink는 사용할 수 없습니다.');
  return resolved;
}

export function parseGradleTasks(output) {
  const tasks = [];
  for (const line of output.split(/\r?\n/)) {
    const match = line.match(/^\s*(:?[\w:-]+)\s+-\s+/);
    if (!match) continue;
    const task = match[1].startsWith(':') ? match[1] : `:${match[1]}`;
    const name = task.split(':').at(-1);
    const module = task.slice(0, -(name.length + 1));
    let kind;
    let variant;
    let screenshotFramework;
    if (/^test[A-Z]\w*UnitTest$/.test(name)) { kind = 'unit'; variant = name.slice(4, -8); }
    else if (name === 'test') { kind = 'unit'; variant = null; }
    else if (/^connected[A-Z]\w*AndroidTest$/.test(name)) { kind = 'device'; variant = name.slice(9, -11); }
    else if (/^validate[A-Z]\w*ScreenshotTest$/.test(name)) { kind = 'screenshot'; variant = name.slice(8, -14); screenshotFramework = 'compose-preview'; }
    else if (/^verifyPaparazzi[A-Z]\w*$/.test(name)) { kind = 'screenshot'; variant = name.slice(15); screenshotFramework = 'paparazzi'; }
    else continue;
    if (!tasks.some(item => item.task === task)) tasks.push({ id: `android:${task}`, platform: 'android', task, module: module || ':', variant, kind, ...(screenshotFramework ? { screenshotFramework } : {}), executor: 'gradle-wrapper' });
  }
  return tasks;
}

export async function discoverAndroid(project, { runner = runProcess, includeDevices = false } = {}) {
  const root = await realpath(project.repositoryPath);
  const wrapper = await containedPath(root, 'gradlew');
  await access(wrapper, constants.X_OK);
  const properties = await containedPath(root, 'gradle/wrapper/gradle-wrapper.properties');
  const jar = await containedPath(root, 'gradle/wrapper/gradle-wrapper.jar');
  const result = await runner(wrapper, ['--console=plain', 'tasks', '--all'], { cwd: root });
  if (result.exitCode !== 0 || result.timedOut) throw new Error(`Gradle task 확인 실패: ${result.stderr}`);
  const checks = parseGradleTasks(result.stdout);
  let devices = [];
  if (includeDevices) {
    const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
    if (!sdk) throw new Error('기기 검증에는 등록된 Android SDK 경로가 필요합니다.');
    const adb = path.join(await realpath(sdk), 'platform-tools', 'adb');
    await access(adb, constants.X_OK);
    const listed = await runner(adb, ['devices'], { cwd: root });
    if (listed.exitCode !== 0) throw new Error('Android 기기 목록을 확인하지 못했습니다.');
    devices = listed.stdout.split(/\r?\n/).map(line => line.match(/^([\w.:-]+)\s+device$/)?.[1]).filter(Boolean);
  }
  const configPaths = new Set(['gradlew', 'gradle/wrapper/gradle-wrapper.properties', 'gradle/wrapper/gradle-wrapper.jar', 'settings.gradle', 'settings.gradle.kts', 'build.gradle', 'build.gradle.kts', 'gradle.properties', 'gradle/libs.versions.toml', 'gradle.lockfile']);
  for (const check of checks) {
    const module = check.module === ':' ? '' : check.module.slice(1).replaceAll(':', '/');
    for (const name of ['build.gradle', 'build.gradle.kts', 'gradle.properties', 'gradle.lockfile']) configPaths.add(path.posix.join(module, name));
  }
  return { platform: 'android', repositoryPath: root, wrapper, wrapperProperties: properties, wrapperJar: jar, checks, devices, configPaths: [...configPaths], discovery: result };
}

export function androidCommand(context, check, { testIds = [], deviceId } = {}) {
  const known = context.checks.find(item => item.id === check.id);
  if (!known || JSON.stringify(known) !== JSON.stringify(check)) throw new Error('실제 발견한 Android 대상만 실행할 수 있습니다.');
  if (known.kind === 'screenshot' && (testIds.length || deviceId)) throw new Error('이 스크린샷 실행기는 필터를 지원하지 않습니다. 확인한 task 전체 범위만 명시 승인할 수 있습니다.');
  if (testIds.some(id => typeof id !== 'string' || !/^[\w.$]+(?:#[\w$]+)?$/.test(id))) throw new Error('정확한 테스트 식별자가 필요합니다.');
  const args = ['--console=plain', known.task];
  if (known.kind === 'unit') {
    if (deviceId) throw new Error('JVM 테스트는 기기를 사용하지 않습니다.');
    if (testIds.some(id => id.includes('#'))) throw new Error('JVM 식별자는 class.method 형식을 사용합니다.');
    for (const id of testIds) args.push('--tests', id);
  } else if (known.kind === 'device') {
    if (!deviceId || !context.devices?.includes(deviceId)) throw new Error('확인된 Android 기기를 선택해야 합니다.');
    if (testIds.length) args.push(`-Pandroid.testInstrumentationRunnerArguments.class=${testIds.join(',')}`);
  }
  return { command: context.wrapper, args, cwd: context.repositoryPath, env: deviceId ? { ANDROID_SERIAL: deviceId } : undefined };
}

const decode = value => value.replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');

export function parseJUnit(xml, scope = '') {
  if (!/<testsuite(?:s)?\b/.test(xml) || /<!DOCTYPE|<!ENTITY/i.test(xml)) throw new Error('유효한 JUnit XML이 아닙니다.');
  const stack = [];
  const structural = xml.replace(/<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>/g, '');
  for (const token of structural.matchAll(/<([^>]+)>/g)) {
    const closing = token[1].startsWith('/');
    const name = token[1].match(/^\/?([\w:-]+)/)?.[1];
    if (!name) throw new Error('XML 태그가 잘못되었습니다.');
    if (closing) { if (stack.pop() !== name) throw new Error('닫히지 않은 JUnit XML입니다.'); }
    else if (!token[1].endsWith('/')) stack.push(name);
  }
  if (stack.length) throw new Error('닫히지 않은 JUnit XML입니다.');
  for (const suite of xml.matchAll(/<testsuite\b([^>]*?)(?:\/>|>([\s\S]*?)<\/testsuite\s*>)/g)) {
    if (/<testsuite\b/.test(suite[2] || '')) continue;
    const declared = suite[1].match(/\btests\s*=\s*["'](\d+)["']/)?.[1];
    const actual = [...(suite[2] || '').matchAll(/<testcase\b/g)].length;
    if (declared !== undefined && Number(declared) !== actual) throw new Error('JUnit 선언 건수와 실제 testcase 수가 다릅니다.');
  }
  const tests = [];
  for (const match of xml.matchAll(/<testcase\b([^>]*)(?:\/>|>([\s\S]*?)<\/testcase\s*>)/g)) {
    const attrs = Object.fromEntries([...match[1].matchAll(/([\w:-]+)\s*=\s*["']([^"']*)["']/g)].map(([, key, value]) => [key, decode(value)]));
    if (!attrs.name) throw new Error('테스트 이름이 없는 XML입니다.');
    const body = match[2] || '';
    tests.push({ id: `${scope}:${attrs.classname || ''}#${attrs.name}`, classname: attrs.classname || '', name: attrs.name, status: /<(?:failure|error)\b/.test(body) ? 'failed' : /<(?:skipped|disabled)\b/.test(body) ? 'skipped' : 'passed' });
  }
  if (new Set(tests.map(test => test.id)).size !== tests.length) throw new Error('중복 테스트 결과를 합칠 수 없습니다.');
  return { tests, executed: tests.filter(test => test.status !== 'skipped').length, passed: tests.filter(test => test.status === 'passed').length, failed: tests.filter(test => test.status === 'failed').length, skipped: tests.filter(test => test.status === 'skipped').length };
}

export async function collectJUnit(root, relativeDirectory, startedAt, scope) {
  let directory;
  try { directory = await containedPath(root, relativeDirectory); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  const results = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.isDirectory()) results.push(...await collectJUnit(root, path.join(relativeDirectory, entry.name), startedAt, scope));
    if (!entry.isFile() || !entry.name.endsWith('.xml')) continue;
    const file = await containedPath(root, path.join(relativeDirectory, entry.name));
    const info = await stat(file);
    if (info.mtimeMs < startedAt) continue;
    const raw = await readFile(file, 'utf8');
    results.push({ path: file, modifiedAt: info.mtimeMs, raw, ...parseJUnit(raw, scope) });
  }
  return results;
}

export function validateReportPath(check, relative) {
  const module = check.module === ':' ? '' : `${check.module.slice(1).replaceAll(':', '/')}/`;
  if (typeof relative !== 'string' || path.isAbsolute(relative) || relative.includes('\\') || relative.split('/').includes('..') || !relative.startsWith(`${module}build/`) || !relative.endsWith('.xml')) throw new Error('선택 모듈 build 아래의 정확한 XML 상대 경로가 필요합니다.');
}

export function parseCoverageXML(xml, { format, scope, exclusions = [] }) {
  if (!['jacoco', 'kover'].includes(format) || !scope?.trim() || /<!ENTITY/i.test(xml)) throw new Error('JaCoCo/Kover report 형식과 실제 측정 범위가 필요합니다.');
  const stack = [];
  const counters = {};
  let rootSeen = false;
  const clean = xml.replace(/<\?[\s\S]*?\?>|<!--[\s\S]*?-->|<!DOCTYPE[^>]*>/g, '');
  for (const [, token] of clean.matchAll(/<([^>]+)>/g)) {
    const name = token.match(/^\/?([\w:-]+)/)?.[1];
    if (!name) throw new Error('커버리지 XML 태그가 잘못되었습니다.');
    if (token.startsWith('/')) { if (stack.pop() !== name) throw new Error('커버리지 XML 구조가 잘못되었습니다.'); continue; }
    if (!stack.length) { if (rootSeen || name !== 'report') throw new Error('단일 JaCoCo 호환 report root만 지원합니다.'); rootSeen = true; }
    if (name === 'counter' && stack.length === 1 && stack[0] === 'report') {
      const attrs = Object.fromEntries([...token.matchAll(/(\w+)\s*=\s*["']([^"']*)["']/g)].map(([, key, value]) => [key, value]));
      if (['LINE', 'BRANCH'].includes(attrs.type)) {
        if (counters[attrs.type] || !/^\d+$/.test(attrs.covered || '') || !/^\d+$/.test(attrs.missed || '')) throw new Error('커버리지 root counter가 중복되거나 잘못되었습니다.');
        const numerator = Number(attrs.covered);
        const missed = Number(attrs.missed);
        const denominator = numerator + missed;
        if (!Number.isSafeInteger(denominator)) throw new Error('커버리지 counter 범위를 넘었습니다.');
        counters[attrs.type] = { numerator, denominator, missed, percentage: denominator ? numerator / denominator * 100 : null };
      }
    }
    if (!token.endsWith('/')) stack.push(name);
  }
  if (!rootSeen || stack.length || !Object.keys(counters).length) throw new Error('측정 가능한 root LINE/BRANCH counter가 없습니다.');
  return { measured: true, format, scope, exclusions, line: counters.LINE || null, branch: counters.BRANCH || null, unsupported: ['LINE', 'BRANCH'].filter(type => !counters[type]) };
}

export async function collectCoverage(root, check, spec, startedAt) {
  if (!spec) return { measured: false, reason: 'not_requested', line: null, branch: null };
  validateReportPath(check, spec.reportPath);
  try {
    const file = await containedPath(root, spec.reportPath);
    const info = await stat(file);
    if (!info.isFile() || info.mtimeMs < startedAt) return { measured: false, reason: 'stale_report', scope: spec.scope, line: null, branch: null };
    const xml = await readFile(file, 'utf8');
    return { ...parseCoverageXML(xml, spec), artifact: { path: file, modifiedAt: info.mtimeMs, sha256: createHash('sha256').update(xml).digest('hex') } };
  } catch (error) { return { measured: false, reason: error.code === 'ENOENT' ? 'missing_report' : 'unsupported_report', detail: error.message, scope: spec.scope, line: null, branch: null }; }
}

export function assessAndroid({ process: result, artifacts = [], task, relatedTasks = [] }) {
  const log = `${result.stdout}\n${result.stderr}`;
  const counts = artifacts.reduce((sum, item) => ({ executed: sum.executed + item.executed, passed: sum.passed + item.passed, failed: sum.failed + item.failed, skipped: sum.skipped + item.skipped }), { executed: 0, passed: 0, failed: 0, skipped: 0 });
  const taskStates = [...log.matchAll(/^> Task ([^\s]+)(?: (NO-SOURCE|UP-TO-DATE|FROM-CACHE|SKIPPED))?\s*$/gm)].map(([, task, state]) => ({ task, state: state || 'EXECUTED' }));
  let status;
  let reason;
  if (result.outputTruncated) { status = 'blocked'; reason = 'output_limit_exceeded'; }
  else if (result.timedOut) { status = 'blocked'; reason = 'timeout'; }
  else if (/no connected devices|no devices|device.*offline|unauthorized|SDK location not found/i.test(log)) { status = 'blocked'; reason = 'device_or_environment'; }
  else if (result.exitCode !== 0 || counts.failed > 0) { status = 'failed'; reason = 'execution_failed'; }
  else if (taskStates.some(item => (!task || item.task === task || relatedTasks.includes(item.task)) && ['UP-TO-DATE', 'FROM-CACHE', 'NO-SOURCE', 'SKIPPED'].includes(item.state))) { status = 'not_run'; reason = 'cached_or_unexecuted_task'; }
  else if (counts.executed === 0) { status = 'not_run'; reason = 'no_executed_tests'; }
  else if (counts.skipped > 0) { status = 'partial'; reason = 'skipped_tests'; }
  else { status = 'passed'; reason = 'fresh_test_results'; }
  return { status, reason, ...counts, taskStates, artifacts, coverage: { measured: false, line: null, branch: null }, rawEvidence: { stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode } };
}

export async function executeAndroid(context, check, selection, { runner = runProcess } = {}) {
  const invocation = androidCommand(context, check, selection);
  const startedAt = Date.now();
  const result = await runner(invocation.command, invocation.args, { cwd: invocation.cwd, env: invocation.env });
  const moduleDirectory = check.module === ':' ? '' : check.module.slice(1).replaceAll(':', '/');
  const scope = `${check.module}/${check.variant}/${selection.deviceId || 'jvm'}`;
  let artifacts;
  if (check.kind === 'screenshot') {
    if (!selection.taskScopeConfirmed || !selection.resultPaths?.length) throw new Error('스크린샷 task 전체 범위 승인과 정확한 결과 XML 경로가 필요합니다.');
    artifacts = [];
    for (const relative of selection.resultPaths) {
      validateReportPath(check, relative);
      try {
        const file = await containedPath(context.repositoryPath, relative);
        const info = await stat(file);
        if (info.mtimeMs < startedAt) continue;
        const raw = await readFile(file, 'utf8');
        artifacts.push({ path: file, modifiedAt: info.mtimeMs, raw, ...parseJUnit(raw, scope) });
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
  } else {
    const reportDirectory = check.kind === 'unit' ? `build/test-results/${check.task.split(':').at(-1)}` : `build/outputs/androidTest-results/connected/${check.variant[0].toLowerCase()}${check.variant.slice(1)}`;
    artifacts = await collectJUnit(context.repositoryPath, path.join(moduleDirectory, reportDirectory), startedAt, scope);
  }
  const taskPrefix = check.module === ':' ? ':' : `${check.module}:`;
  const relatedTasks = check.screenshotFramework === 'paparazzi' ? [`${taskPrefix}test${check.variant}`, `${taskPrefix}test${check.variant}UnitTest`] : [];
  const assessed = assessAndroid({ process: result, artifacts, task: check.task, relatedTasks });
  const tests = artifacts.flatMap(artifact => artifact.tests);
  if (new Set(tests.map(test => test.id)).size !== tests.length) throw new Error('동일 대상의 중복 결과 XML을 합산할 수 없습니다.');
  const matches = (id, test) => id === test.classname || id === `${test.classname}${check.kind === 'device' ? '#' : '.'}${test.name.replace(/\(.*$|\[.*$/, '')}`;
  const missingTestIds = check.kind === 'screenshot' ? [] : selection.testIds.filter(id => !tests.some(test => matches(id, test) && test.status !== 'skipped'));
  const unexpectedTestIds = check.kind === 'screenshot' ? [] : tests.filter(test => !selection.testIds.some(id => matches(id, test))).map(test => test.id);
  if (assessed.status === 'passed' && (missingTestIds.length || unexpectedTestIds.length)) { assessed.status = 'incomplete'; assessed.reason = 'selected_test_scope_mismatch'; }
  if (check.kind === 'screenshot' && artifacts.length !== selection.resultPaths.length && assessed.status === 'passed') { assessed.status = 'incomplete'; assessed.reason = 'missing_fresh_screenshot_results'; }
  const coverage = await collectCoverage(context.repositoryPath, check, selection.coverage, startedAt);
  return { ...assessed, coverage, ...(selection.coverage && !coverage.measured && assessed.status === 'passed' ? { status: 'incomplete', reason: 'requested_coverage_not_measured' } : {}), executionScope: check.kind === 'screenshot' ? 'explicit_task_all_tests_no_filter' : 'selected_tests', missingTestIds, unexpectedTestIds, invocation, startedAt, finishedAt: Date.now() };
}
