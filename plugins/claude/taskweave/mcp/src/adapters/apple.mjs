import { readdir, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { containedPath, runProcess } from './android.mjs';

export async function discoverApple(project, { runner = runProcess, hostCapabilities } = {}) {
  const root = await realpath(project.repositoryPath);
  const containers = (await readdir(root)).filter(name => /\.(xcworkspace|xcodeproj)$/.test(name));
  const targets = [];
  for (const container of containers) {
    const resolved = await containedPath(root, container);
    if (hostCapabilities) {
      for (const target of hostCapabilities.targets || []) {
        if (target.container !== container || typeof target.scheme !== 'string' || !target.scheme.trim()) continue;
        targets.push({ id: `apple:${container}:${target.scheme}`, platform: 'apple', kind: 'unit', executor: 'host-xcode', container, scheme: target.scheme, destinations: target.destinations || [], testIds: target.testIds || [] });
      }
      continue;
    }
    const flag = container.endsWith('.xcworkspace') ? '-workspace' : '-project';
    const listed = await runner('/usr/bin/xcodebuild', ['-list', '-json', flag, resolved], { cwd: root });
    if (listed.exitCode !== 0) continue;
    let data;
    try { data = JSON.parse(listed.stdout); } catch { continue; }
    for (const scheme of (data.workspace || data.project)?.schemes || []) {
      const destinations = await runner('/usr/bin/xcodebuild', ['-showdestinations', flag, resolved, '-scheme', scheme], { cwd: root });
      const ids = [...destinations.stdout.matchAll(/\{[^\n}]*\bid:([^,}]+)[^\n}]*\}/g)].map(match => match[1].trim()).filter(id => !id.includes('placeholder'));
      targets.push({ id: `apple:${container}:${scheme}`, platform: 'apple', kind: 'unit', executor: 'xcodebuild', container, scheme, destinations: [...new Set(ids)] });
    }
  }
  const configPaths = new Set(['Package.swift', 'Package.resolved']);
  for (const target of targets) {
    configPaths.add(path.posix.join(target.container, target.container.endsWith('.xcodeproj') ? 'project.pbxproj' : 'contents.xcworkspacedata'));
    configPaths.add(path.posix.join(target.container, 'xcshareddata', 'xcschemes', `${target.scheme}.xcscheme`));
  }
  return { platform: 'apple', repositoryPath: root, checks: targets, configPaths: [...configPaths], hostMcpAvailable: Boolean(hostCapabilities) };
}

export function appleCommand(context, check, { testIds = [], destination, resultBundlePath } = {}) {
  const known = context.checks.find(item => item.id === check.id);
  if (!known || JSON.stringify(known) !== JSON.stringify(check)) throw new Error('확인된 Apple 대상만 실행할 수 있습니다.');
  if (!known.destinations.includes(destination)) throw new Error('확인된 destination을 선택해야 합니다.');
  if (!testIds.length || testIds.some(id => typeof id !== 'string' || !/^[\w.]+(?:\/[\w.]+){1,2}$/.test(id))) throw new Error('영향 테스트의 정확한 식별자가 필요합니다.');
  if (known.executor === 'host-xcode' && (!known.testIds?.length || testIds.some(id => !known.testIds.includes(id)))) throw new Error('확인하지 않은 테스트 식별자입니다.');
  if (known.executor === 'host-xcode') return { executor: 'host-xcode', targetId: known.id, scheme: known.scheme, destination, testIds };
  const flag = known.container.endsWith('.xcworkspace') ? '-workspace' : '-project';
  return { command: '/usr/bin/xcodebuild', args: ['test', flag, path.join(context.repositoryPath, known.container), '-scheme', known.scheme, '-destination', `id=${destination}`, ...testIds.map(id => `-only-testing:${id}`), ...(resultBundlePath ? ['-resultBundlePath', resultBundlePath] : [])], cwd: context.repositoryPath };
}

export function assessApple({ process: result, summary, rawEvidence, scope }) {
  const counts = { executed: 0, passed: 0, failed: 0, skipped: 0 };
  if (summary) {
    for (const key of Object.keys(counts)) {
      if (!Number.isSafeInteger(summary[key]) || summary[key] < 0) throw new Error('실제 결과의 테스트 건수가 필요합니다.');
      counts[key] = summary[key];
    }
    if (counts.executed !== counts.passed + counts.failed) throw new Error('Apple 결과 건수가 일치하지 않습니다.');
  }
  const log = `${result?.stdout || ''}\n${result?.stderr || ''}`;
  let status = 'not_run';
  let reason = 'no_result_bundle_summary';
  if (result?.outputTruncated) { status = 'blocked'; reason = 'output_limit_exceeded'; }
  else if (result?.timedOut) { status = 'blocked'; reason = 'timeout'; }
  else if (/Unable to find a destination|not available|device.*offline/i.test(log)) { status = 'blocked'; reason = 'destination_unavailable'; }
  else if (result?.exitCode !== 0 || counts.failed) { status = 'failed'; reason = 'execution_failed'; }
  else if (counts.executed > 0) { status = counts.skipped ? 'partial' : 'passed'; reason = counts.skipped ? 'skipped_tests' : 'fresh_test_results'; }
  return { platform: 'apple', status, reason, ...counts, scope, coverage: summary?.coverage || { measured: false, line: null, branch: null }, rawEvidence: rawEvidence || { stdout: result?.stdout, stderr: result?.stderr, exitCode: result?.exitCode } };
}

export async function executeApple(context, check, selection, { runner = runProcess, hostResult } = {}) {
  const invocation = appleCommand(context, check, selection);
  const startedAt = Date.now();
  if (invocation.executor === 'host-xcode') {
    if (!hostResult) return { status: 'awaiting_host', reason: '호스트 AI가 Xcode MCP를 직접 실행한 뒤 결과를 연결해야 합니다.', invocation, executed: 0, passed: 0, failed: 0, skipped: 0 };
    if (hostResult.targetId !== check.id || hostResult.destination !== selection.destination || JSON.stringify(hostResult.testIds) !== JSON.stringify(selection.testIds)) throw new Error('호스트 실행 결과가 승인 대상과 다릅니다.');
    if (!Number.isFinite(hostResult.startedAt) || hostResult.startedAt < selection.approvedAt || !Number.isFinite(hostResult.finishedAt) || hostResult.finishedAt < hostResult.startedAt) throw new Error('이번 승인 이후 호스트 실행 결과가 필요합니다.');
    if (typeof hostResult.rawEvidence !== 'string' || !hostResult.rawEvidence.trim()) throw new Error('호스트의 원본 결과가 필요합니다.');
    return { ...assessApple({ process: { exitCode: hostResult.exitCode, stdout: hostResult.rawEvidence }, summary: hostResult.summary, rawEvidence: hostResult.rawEvidence, scope: invocation }), startedAt: hostResult.startedAt, finishedAt: hostResult.finishedAt };
  }
  // 별도 DerivedData 생성·clean 없이 승인된 직접 테스트만 실행한다.
  const result = await runner(invocation.command, invocation.args, { cwd: invocation.cwd });
  let summary;
  let rawSummary;
  let bundle;
  if (selection.resultBundlePath) {
    bundle = selection.resultBundlePath;
    if ((await stat(bundle)).mtimeMs >= startedAt) {
      const parsed = await runner('/usr/bin/xcrun', ['xcresulttool', 'get', 'test-results', 'summary', '--path', bundle, '--compact'], { cwd: context.repositoryPath });
      if (parsed.exitCode === 0) {
        rawSummary = parsed.stdout;
        const data = JSON.parse(parsed.stdout);
        summary = { passed: data.passedTests, failed: data.failedTests, skipped: data.skippedTests, executed: data.passedTests + data.failedTests };
      }
    }
  }
  return { ...assessApple({ process: result, summary, rawEvidence: { ...result, bundle, rawSummary }, scope: invocation }), invocation, startedAt, finishedAt: Date.now() };
}
