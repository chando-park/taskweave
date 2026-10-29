import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { atomicJSON, assertId, checkKeys, requireWithin, requireWorkplanBinding } from './settings.mjs';
import { containedPath, discoverAndroid, executeAndroid, androidCommand, runProcess, validateReportPath } from './adapters/android.mjs';
import { discoverApple, executeApple, appleCommand } from './adapters/apple.mjs';

const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const clone = value => JSON.parse(JSON.stringify(value));
const approvalDigest = plan => digest({ checks: plan.checks, inputPaths: plan.inputPaths, ...(plan.workplanBinding ? { workplanBinding: plan.workplanBinding } : {}) });
async function hashInputs(root, paths, { allowMissing = false } = {}) {
  const inputs = [];
  let latestModifiedAt = 0;
  for (const relative of [...new Set(paths)].sort()) {
    if (typeof relative !== 'string' || path.isAbsolute(relative) || relative.split(/[\\/]/).includes('..')) throw new Error('정확한 프로젝트 상대 파일 경로가 필요합니다.');
    const filename = await containedPath(root, relative, { mustExist: !allowMissing });
    try {
      const info = await stat(filename);
      if (!info.isFile()) throw new Error('검증 입력은 폴더가 아닌 정확한 파일이어야 합니다.');
      latestModifiedAt = Math.max(latestModifiedAt, info.mtimeMs);
      inputs.push([relative, createHash('sha256').update(await readFile(filename)).digest('hex')]);
    } catch (error) {
      if (!allowMissing || error.code !== 'ENOENT') throw error;
      inputs.push([relative, null]);
    }
  }
  return { digest: digest(inputs), latestModifiedAt };
}

const configurationDigest = async (root, paths) => (await hashInputs(root, paths, { allowMissing: true })).digest;

async function confirmTestIds(context, check, selection, inputPaths) {
  if (check.executor === 'host-xcode') return;
  const sources = [];
  const modulePrefix = check.module && check.module !== ':' ? `${check.module.slice(1).replaceAll(':', '/')}/` : '';
  for (const relative of inputPaths) {
    if (!/\.(?:kt|java|swift)$/.test(relative)) continue;
    if (context.platform === 'android' && (!relative.startsWith(`${modulePrefix}src/`) || !relative.slice(modulePrefix.length).match(check.kind === 'device' ? /^src\/androidTest[^/]*\// : /^src\/test[^/]*\//))) continue;
    sources.push(await readFile(await containedPath(context.repositoryPath, relative), 'utf8'));
  }
  for (const id of selection.testIds) {
    const found = sources.some(source => {
      if (context.platform === 'apple') {
        const [, suite, method] = id.split('/');
        return new RegExp(`\\b(?:class|struct)\\s+${suite}\\b`).test(source) && (!method || new RegExp(`\\bfunc\\s+${method}\\s*\\(`).test(source));
      }
      const packageName = source.match(/\bpackage\s+([\w.]+)/)?.[1] || '';
      return [...source.matchAll(/\b(?:class|object)\s+(\w+)/g)].some(([, name]) => {
        const fullName = packageName ? `${packageName}.${name}` : name;
        const separator = check.kind === 'device' ? '#' : '.';
        if (id === fullName) return /@(?:[\w.]+\.)?Test\b/.test(source);
        if (!id.startsWith(`${fullName}${separator}`)) return false;
        const method = id.slice(fullName.length + 1);
        return /^[\w$]+$/.test(method) && /@(?:[\w.]+\.)?Test\b/.test(source) && new RegExp(`\\b(?:fun|void)\\s+${method}\\s*\\(`).test(source);
      });
    });
    if (!found) throw new Error(`현재 테스트 소스에서 식별자를 확인하지 못했습니다: ${id}`);
  }
}

export class VerificationService {
  constructor({ store, runner = runProcess } = {}) {
    if (!store) throw new Error('SettingsStore가 필요합니다.');
    this.store = store;
    this.runner = runner;
  }

  async recordPath(projectId, type, id) {
    assertId(projectId); assertId(id);
    const root = path.join(this.store.dataRoot, 'verification', projectId, type);
    return requireWithin(root, path.join(root, `${id}.json`), { allowMissing: true });
  }

  async write(projectId, type, value) {
    await atomicJSON(await this.recordPath(projectId, type, value.id), value);
    return clone(value);
  }

  async read(projectId, type, id) {
    return JSON.parse(await readFile(await this.recordPath(projectId, type, id), 'utf8'));
  }

  async context(input) {
    checkKeys(input, ['project', 'projectId', 'platform', 'targetId', 'hostCapabilities', 'includeDevices']);
    const projectId = input.projectId || input.project;
    const project = await this.store.requireTrustedProject(projectId);
    if (!['apple', 'android'].includes(input.platform)) throw new Error('변경한 플랫폼 하나를 선택해 주세요.');
    const context = input.platform === 'android'
      ? await discoverAndroid(project, { runner: this.runner, includeDevices: input.includeDevices === true })
      : await discoverApple(project, { runner: this.runner, hostCapabilities: input.hostCapabilities });
    if (input.targetId) context.checks = context.checks.filter(check => check.id === input.targetId);
    if (!context.checks.length) throw new Error('실제 실행 가능한 테스트 대상을 찾지 못했습니다.');
    return this.write(projectId, 'contexts', { ...context, id: randomUUID(), projectId, references: ['references/verification-planning.md', 'references/verification-evidence.md', `references/verification-${input.platform}.md`], configurationDigest: await configurationDigest(project.repositoryPath, context.configPaths), createdAt: Date.now() });
  }

  async select(input) {
    checkKeys(input, ['context', 'change', 'requestedChecks', 'exclusions', 'uiTier', 'inputPaths']);
    const contextId = typeof input.context === 'string' ? input.context : input.context?.id;
    const projectId = typeof input.context === 'object' ? input.context.projectId : undefined;
    if (!projectId) throw new Error('저장된 context와 projectId가 필요합니다.');
    await this.store.requireTrustedProject(projectId);
    const context = await this.read(projectId, 'contexts', contextId);
    if (context.configurationDigest !== await configurationDigest(context.repositoryPath, context.configPaths)) throw new Error('대상 탐색 뒤 설정이 바뀌었습니다. context를 다시 확인해 주세요.');
    if (!Array.isArray(input.inputPaths) || !input.inputPaths.length || input.inputPaths.length > 500) throw new Error('확인한 source/test/config/dependency의 정확한 inputPaths 파일 목록이 필요합니다.');
    await hashInputs(context.repositoryPath, input.inputPaths);
    if (!input.change || !['logic', 'integration', 'interaction', 'visual'].includes(input.change.kind)) throw new Error('변경 종류를 지정해 주세요.');
    const tier = input.uiTier || 'none';
    if (!['none', 'regression', 'conformance', 'full'].includes(tier)) throw new Error('UI 검증 tier가 잘못되었습니다.');
    if (input.change.kind === 'visual' && tier === 'none') throw new Error('시각 계약 변경에는 명시 UI 검증 tier가 필요합니다.');
    let selected = input.requestedChecks;
    if (input.change.kind === 'visual' && !selected?.length) throw new Error('스크린샷 task 전체 실행은 requestedChecks로 명시 선택해야 합니다.');
    if (!selected?.length) {
      const kind = input.change.kind === 'logic' ? 'unit' : input.change.kind === 'visual' ? 'screenshot' : 'device';
      const candidates = context.checks.filter(check => check.kind === kind);
      if (candidates.length !== 1) throw new Error('영향 모듈·variant·테스트 대상을 명시적으로 선택해 주세요.');
      selected = [{ id: candidates[0].id, testIds: input.change.testIds || [], destination: input.change.destination, deviceId: input.change.deviceId }];
    }
    const checks = [];
    for (const selection of selected) {
      checkKeys(selection, ['id', 'testIds', 'destination', 'deviceId', 'coverage', 'resultPaths', 'taskScopeConfirmed']);
      const check = context.checks.find(item => item.id === selection.id);
      if (!check) throw new Error('발견하지 않은 검증 대상입니다.');
      if (!Array.isArray(selection.testIds) || (check.kind !== 'screenshot' && !selection.testIds.length)) throw new Error('변경에 직접 연결된 테스트 식별자가 필요합니다.');
      if (check.kind === 'screenshot') {
        if (selection.taskScopeConfirmed !== true || selection.testIds.length || !Array.isArray(selection.resultPaths) || !selection.resultPaths.length || selection.resultPaths.length > 100 || new Set(selection.resultPaths).size !== selection.resultPaths.length) throw new Error('필터 없는 task 전체 범위와 정확한 XML 결과 경로를 명시 승인해야 합니다.');
        for (const relative of selection.resultPaths) { validateReportPath(check, relative); await containedPath(context.repositoryPath, relative, { mustExist: false }); }
      } else if (selection.resultPaths || selection.taskScopeConfirmed) throw new Error('task 전체 범위 옵션은 스크린샷에만 사용할 수 있습니다.');
      if (selection.coverage) {
        if (context.platform !== 'android') throw new Error('이 XML 커버리지 연결은 Android JaCoCo/Kover만 지원합니다.');
        checkKeys(selection.coverage, ['reportPath', 'format', 'scope', 'exclusions']);
        if (!['jacoco', 'kover'].includes(selection.coverage.format) || typeof selection.coverage.scope !== 'string' || !selection.coverage.scope.trim() || (selection.coverage.exclusions && (!Array.isArray(selection.coverage.exclusions) || selection.coverage.exclusions.some(value => typeof value !== 'string')))) throw new Error('기존 커버리지 형식·측정 범위·제외 항목이 필요합니다.');
        validateReportPath(check, selection.coverage.reportPath);
        await containedPath(context.repositoryPath, selection.coverage.reportPath, { mustExist: false });
      }
      const safe = clone(selection);
      const invocation = context.platform === 'android' ? androidCommand(context, check, safe) : appleCommand(context, check, safe);
      await confirmTestIds(context, check, safe, input.inputPaths);
      checks.push({ ...check, selection: safe, invocation });
    }
    if (new Set(checks.map(check => check.id)).size !== checks.length) throw new Error('중복 대상을 선택할 수 없습니다.');
    const configPaths = context.configPaths.filter(relative => {
      if (!relative.includes('/') || relative.startsWith('gradle/')) return true;
      return checks.some(check => context.platform === 'android'
        ? check.module !== ':' && relative.startsWith(`${check.module.slice(1).replaceAll(':', '/')}/`)
        : relative.startsWith(`${check.container}/`));
    });
    return this.write(projectId, 'plans', { id: randomUUID(), projectId, contextId, configPaths, configurationDigest: await configurationDigest(context.repositoryPath, configPaths), inputPaths: [...new Set(input.inputPaths)].sort(), change: clone(input.change), checks, uiTier: tier, exclusions: input.exclusions || [], selectedAt: Date.now(), status: 'selected' });
  }

  async approve(input) {
    checkKeys(input, ['project', 'projectId', 'planId', 'approvalSource', 'confirmed', 'workplanBinding']);
    const projectId = input.projectId || input.project;
    await this.store.requireTrustedProject(projectId);
    if (input.confirmed !== true || typeof input.approvalSource !== 'string' || !input.approvalSource.trim()) throw new Error('실제 사용자 검증 승인 참조가 필요합니다.');
    const plan = await this.read(projectId, 'plans', input.planId);
    const project = await this.store.requireTrustedProject(projectId);
    if (plan.configurationDigest !== await configurationDigest(project.repositoryPath, plan.configPaths)) throw new Error('대상 설정이 바뀌었습니다. 검증 계획을 다시 선택해 주세요.');
    const workplanBinding = input.workplanBinding ? await requireWorkplanBinding(project, input.workplanBinding) : undefined;
    const bound = { ...plan, ...(workplanBinding ? { workplanBinding } : {}) };
    const approval = { ...bound, id: randomUUID(), planId: plan.id, status: 'approved', approvedAt: Date.now(), approvalSource: input.approvalSource, selectedDigest: approvalDigest(bound) };
    return this.write(projectId, 'approvals', approval);
  }

  async run(input) {
    checkKeys(input, ['project', 'projectId', 'approvedPlanId', 'checkIds', 'hostResults']);
    const projectId = input.projectId || input.project;
    const project = await this.store.requireTrustedProject(projectId);
    const plan = await this.read(projectId, 'approvals', input.approvedPlanId);
    if (plan.status !== 'approved' || !plan.approvalSource || plan.selectedDigest !== approvalDigest(plan)) throw new Error('승인된 불변 검증 계획이 필요합니다.');
    if (plan.workplanBinding) await requireWorkplanBinding(project, plan.workplanBinding);
    if (plan.configurationDigest !== await configurationDigest(project.repositoryPath, plan.configPaths)) throw new Error('승인 뒤 프로젝트 설정이 바뀌었습니다.');
    if (!Array.isArray(input.checkIds) || !input.checkIds.length || new Set(input.checkIds).size !== input.checkIds.length || input.checkIds.some(id => !plan.checks.some(check => check.id === id))) throw new Error('승인된 검증 ID만 실행할 수 있습니다.');
    const context = await this.read(projectId, 'contexts', plan.contextId);
    if (await realpath(project.repositoryPath) !== context.repositoryPath) throw new Error('등록된 프로젝트 경로가 바뀌었습니다.');
    const inputs = await hashInputs(project.repositoryPath, plan.inputPaths);
    const runId = randomUUID();
    const results = [];
    // 기기·결과 디렉터리 충돌을 피하기 위해 기본 실행은 직렬이다.
    for (const id of input.checkIds) {
      const selected = plan.checks.find(check => check.id === id);
      const check = context.checks.find(item => item.id === id);
      const selection = { ...selected.selection, approvedAt: Math.max(plan.approvedAt, inputs.latestModifiedAt) };
      let result;
      try {
        if (context.platform === 'apple' && check.executor === 'xcodebuild') {
          const outputRoot = await requireWithin(this.store.dataRoot, path.join(this.store.dataRoot, 'verification', projectId, 'artifacts', runId), { allowMissing: true });
          await mkdir(outputRoot, { recursive: true, mode: 0o700 });
          selection.resultBundlePath = path.join(outputRoot, `${results.length}.xcresult`);
        }
        result = context.platform === 'android'
          ? await executeAndroid(context, check, selection, { runner: this.runner })
          : await executeApple(context, check, selection, { runner: this.runner, hostResult: input.hostResults?.[id] });
      } catch (error) { result = { status: 'blocked', reason: error.message, executed: 0, passed: 0, failed: 0, skipped: 0 }; }
      results.push({ checkId: id, platform: context.platform, module: check.module, variant: check.variant, scheme: check.scheme, ...result });
    }
    const finalInputs = await hashInputs(project.repositoryPath, plan.inputPaths);
    return this.write(projectId, 'runs', { id: runId, projectId, approvedPlanId: plan.id, ...(plan.workplanBinding ? { workplanBinding: plan.workplanBinding } : {}), results, inputDigest: inputs.digest, inputsChangedDuringRun: inputs.digest !== finalInputs.digest, uiTier: plan.uiTier, exclusions: plan.exclusions, recordedAt: Date.now() });
  }

  async report(input) {
    checkKeys(input, ['project', 'projectId', 'runId']);
    const projectId = input.projectId || input.project;
    const project = await this.store.requireTrustedProject(projectId);
    const run = await this.read(projectId, 'runs', input.runId);
    const plan = await this.read(projectId, 'approvals', run.approvedPlanId);
    if (plan.status !== 'approved' || plan.selectedDigest !== approvalDigest(plan) || JSON.stringify(run.workplanBinding) !== JSON.stringify(plan.workplanBinding)) throw new Error('검증 실행과 승인 계획의 연결이 다릅니다');
    if (plan.workplanBinding) await requireWorkplanBinding(project, plan.workplanBinding);
    const missingChecks = plan.checks.map(check => check.id).filter(id => !run.results.some(result => result.checkId === id));
    const inputsCurrent = !run.inputsChangedDuringRun && run.inputDigest === (await hashInputs(project.repositoryPath, plan.inputPaths)).digest && plan.configurationDigest === await configurationDigest(project.repositoryPath, plan.configPaths);
    const passed = inputsCurrent && !missingChecks.length && run.results.every(result => result.status === 'passed');
    const requiresUiGate = run.uiTier !== 'none';
    return { ...run, status: passed && !requiresUiGate ? 'passed' : 'incomplete', inputsCurrent, missingChecks, ui: { tier: run.uiTier, status: requiresUiGate ? 'not_evaluated' : 'not_applicable', reason: requiresUiGate ? '기존 UI 원천·Golden receipt gate를 별도로 통과해야 합니다. 테스트 성공은 원천 적합성을 증명하지 않습니다.' : '승인 범위에 시각 검증이 없습니다.' }, summary: run.results.map(item => `${item.checkId}: ${item.executed}건 실행, ${item.passed}건 통과, ${item.failed}건 실패, ${item.skipped}건 건너뜀 (${item.status})`).join('\n') };
  }
}

export const verificationContext = (options, dependencies) => new VerificationService(dependencies).context(options);
export const selectVerification = (options, dependencies) => new VerificationService(dependencies).select(options);
export const verificationRun = (options, dependencies) => new VerificationService(dependencies).run(options);
export const verificationReport = (options, dependencies) => new VerificationService(dependencies).report(options);
