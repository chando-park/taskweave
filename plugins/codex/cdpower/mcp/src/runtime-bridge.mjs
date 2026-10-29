import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { access, lstat, mkdir, open, readFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { assertId, atomicJSON, canonicalPath, requireWithin, requireWorkplanBinding, withLock } from './settings.mjs';

const execFileAsync = promisify(execFile);
const ALLOWED_SCRIPTS = new Set(['workplan-memo.rb', 'resolve-task-context.rb', 'resolve-workplan-policy.rb']);
const here = path.dirname(fileURLToPath(import.meta.url));
const hash = (value) => createHash('sha256').update(value).digest('hex');

async function atomicText(filename, value) {
  const temporary = `${filename}.${randomUUID()}.tmp`;
  const handle = await open(temporary, 'wx', 0o600);
  try { await handle.writeFile(value); await handle.sync(); await handle.close(); await rename(temporary, filename); }
  finally { await handle.close().catch(() => {}); await rm(temporary, { force: true }); }
}

function memoBody(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 512 * 1024) throw new Error('메모 본문이 비어 있거나 너무 큽니다');
  return value;
}

function replaceBody(document, body) {
  const match = document.match(/^---\r?\n[\s\S]*?\r?\n---\r?\n/);
  if (!match) throw new Error('Workplan frontmatter를 확인할 수 없습니다');
  return `${match[0]}\n${memoBody(body).trim()}\n`;
}

function addMany(argv, flag, values = []) {
  for (const value of values) {
    if (typeof value !== 'string' || !value.trim() || value.includes('\0')) throw new Error(`${flag} 입력이 잘못되었습니다`);
    argv.push(flag, value);
  }
}

export class RuntimeBridge {
  constructor({ runtimeRoot, store, verification, timeoutMs = 30_000, runner = execFileAsync } = {}) {
    this.runtimeRoot = runtimeRoot;
    this.store = store;
    this.verification = verification;
    this.timeoutMs = Math.min(timeoutMs, 120_000);
    this.runner = runner;
  }

  async getRuntimeRoot() {
    if (this.runtimeRoot) return canonicalPath(this.runtimeRoot);
    for (const candidate of [path.resolve(here, '../../core'), path.resolve(here, '../../Codex/Runtime')]) {
      if (await access(path.join(candidate, 'scripts/workplan-memo.rb')).then(() => true, () => false)) return canonicalPath(candidate);
    }
    throw new Error('패키지 내부 Ruby Runtime이 없습니다. 플러그인을 다시 빌드해 주세요');
  }

  async runBundledRuby(script, argv, { project } = {}) {
    if (!ALLOWED_SCRIPTS.has(script)) throw new Error('허용하지 않은 Runtime 프로그램입니다');
    if (!Array.isArray(argv) || argv.some((value) => typeof value !== 'string' || value.includes('\0'))) throw new Error('잘못된 Runtime 인자입니다');
    const root = await this.getRuntimeRoot();
    const executable = await requireWithin(root, path.join(root, 'scripts', script));
    const env = { PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: process.env.HOME, LANG: 'en_US.UTF-8', AI_WORKFLOW_REGISTRY: this.store.configPath, AI_WORKFLOW_DATA_ROOT: this.store.dataRoot };
    let registrySnapshot;
    if (project) {
      // 회사 목록에서 찾은 연결도 Ruby에 같은 값으로 전달한다. 사용자 설정은 바꾸지 않는다.
      const catalog = await this.store.projectCatalog();
      if (!catalog.projects[project.projectId] || !catalog.workspaces[project.workspaceId]) throw new Error('현재 프로젝트 연결을 다시 확인하세요');
      registrySnapshot = await requireWithin(this.store.dataRoot, path.join(this.store.dataRoot, 'runtime', `context-${randomUUID()}.json`), { allowMissing: true });
      await atomicJSON(registrySnapshot, { schemaVersion: 1, workplanStorage: catalog.workplanStorage,
        projects: { [project.projectId]: catalog.projects[project.projectId] },
        workspaces: { [project.workspaceId]: catalog.workspaces[project.workspaceId] } });
      env.AI_WORKFLOW_REGISTRY = registrySnapshot;
      env.AI_WORKFLOW_PROJECT_ID = project.projectId;
      // 회사 스크립트는 문서 등록과 별개인 workspace 실행 신뢰가 있을 때만 연결한다.
      env.COMPANY_WORKSPACE = project.workspaceTrusted ? project.workspacePath : path.join(this.store.dataRoot, 'disabled-company-workspace');
      if (project.workspaceTrusted) env.AI_WORKFLOW_WORKSPACE = project.workspacePath;
    }
    let stdout;
    try {
      ({ stdout } = await this.runner('ruby', [executable, ...argv], { cwd: project?.repositoryPath ?? root, env, shell: false, timeout: this.timeoutMs, maxBuffer: 2 * 1024 * 1024, killSignal: 'SIGKILL' }));
    } catch (error) {
      // 환경 변수나 임의 stderr 전문은 AI에 되돌리지 않는다.
      const detail = typeof error.stderr === 'string' ? error.stderr.trim().slice(0, 1800) : '';
      throw new Error(error.killed ? 'Runtime 실행 시간이 초과되었습니다' : `Runtime 실행 실패${detail ? `: ${detail}` : ''}`);
    } finally {
      if (registrySnapshot) await rm(registrySnapshot, { force: true });
    }
    // 승인 검증 CLI만 한글 보고서를 반환한다. 그 외 프로그램의 깨진 JSON을 성공으로 바꾸지 않는다.
    if (script === 'workplan-memo.rb' && argv[0] === 'validate' && argv.includes('approval')) {
      const revision = stdout.match(/계획 버전: `(sha256:[a-f0-9]{64})`/u)?.[1];
      if (!revision || !stdout.startsWith('Workplan memo valid: approval')) throw new Error('Runtime 승인 보고서 형식이 잘못되었습니다');
      return { approvalRevision: revision, planReport: stdout.trim() };
    }
    try { return JSON.parse(stdout); } catch { throw new Error('Runtime이 유효한 JSON 결과를 반환하지 않았습니다'); }
  }

  async runtimeStatus() {
    const runtimeRoot = await this.getRuntimeRoot();
    const checks = {};
    for (const script of ALLOWED_SCRIPTS) checks[script] = await access(path.join(runtimeRoot, 'scripts', script)).then(() => true, () => false);
    return { runtimeRoot, scripts: checks, nodeVersion: process.version, ready: Object.values(checks).every(Boolean) };
  }

  async workplanFile(project, workplanId) {
    assertId(workplanId, 'Workplan ID');
    const bundle = path.join(project.workplanRoot, workplanId);
    const filename = path.join(bundle, `${workplanId}.md`);
    if ((await lstat(bundle)).isSymbolicLink() || (await lstat(filename)).isSymbolicLink()) throw new Error('Workplan bundle과 메모 파일 symlink는 허용하지 않습니다');
    return requireWithin(project.workplanRoot, filename);
  }

  async execute(operation, input) {
    const operations = ['workplan_create', 'workplan_update', 'workplan_prepare', 'workplan_approve', 'workplan_start', 'workplan_feedback', 'workplan_result'];
    if (!operations.includes(operation)) throw new Error('허용하지 않은 Workplan 작업입니다');
    assertId(input.requestId, '요청 ID');
    const project = await this.store.requireTrustedProject(input.projectId);
    if (!project.git) throw new Error('Git 없는 프로젝트에서는 승인·diff 기반 Workplan 실행을 지원하지 않습니다');
    const workplanId = assertId(input.workplanId, 'Workplan ID');
    const runtimeData = path.join(this.store.dataRoot, 'workspaces', project.workspaceId, 'projects', project.projectId, '.runtime');
    const lockRoot = await canonicalPath(path.join(runtimeData, 'locks'), { allowMissing: true });
    const receipts = await canonicalPath(path.join(runtimeData, 'requests'), { allowMissing: true });
    await mkdir(receipts, { recursive: true, mode: 0o700 });
    return withLock(path.join(lockRoot, `${project.projectId}-${workplanId}.lock`), async () => {
      const receipt = await requireWithin(receipts, path.join(receipts, `${input.requestId}.json`), { allowMissing: true });
      const digest = hash(JSON.stringify({ operation, input }));
      let previous;
      try { previous = JSON.parse(await readFile(receipt, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
      if (previous) {
        if (previous.digest !== digest) throw new Error('같은 요청 ID를 다른 입력에 재사용할 수 없습니다');
        if (previous.state !== 'complete') throw new Error('이전 요청의 실행이 중단되었습니다. 실제 메모 상태를 확인한 후 새 요청 ID를 사용해 주세요');
        return { ...previous.result, replayed: true };
      }
      const contextArgs = [project.repositoryPath, '--require-workplan'];
      if (project.remote) contextArgs.push('--expect-remote', project.remote);
      const context = await this.runBundledRuby('resolve-task-context.rb', contextArgs, { project });
      if (await canonicalPath(context.repository_root) !== project.repositoryPath || await canonicalPath(context.workplan_root, { allowMissing: true }) !== await canonicalPath(project.workplanRoot, { allowMissing: true })) throw new Error('등록 정보와 Runtime resolver의 저장소 또는 Workplan 경로가 다릅니다');
      await atomicJSON(receipt, { state: 'pending', digest, operation, workplanId });
      const result = await this.perform(operation, input, project);
      await atomicJSON(receipt, { state: 'complete', digest, result });
      return result;
    });
  }

  async perform(operation, input, project) {
    const base = ['--repository', project.repositoryPath];
    let argv;
    let filename;
    if (operation === 'workplan_create') {
      memoBody(input.memoBody);
      argv = ['create', ...base, '--root', project.workplanRoot, '--project-id', project.projectId, '--id', input.workplanId, '--title', input.title, '--kind', input.kind, '--reason', input.reason];
      addMany(argv, '--scope', input.scopePaths);
      addMany(argv, '--exclude', input.excludedPaths);
      addMany(argv, '--verification', input.verification);
      if (input.jiraKey) argv.push('--jira-key', input.jiraKey);
      if (input.uiTier) argv.push('--ui-tier', input.uiTier, '--ui-reason', input.uiReason ?? 'UI 영향 범위 명시');
      await this.runBundledRuby('workplan-memo.rb', argv, { project });
      filename = await this.workplanFile(project, input.workplanId);
      const document = replaceBody(await readFile(filename, 'utf8'), input.memoBody);
      await atomicText(filename, document);
      return { status: 'created', workplanId: input.workplanId, workplan: filename, contentHash: hash(document), approvalRequired: true };
    }
    filename = await this.workplanFile(project, input.workplanId);
    if (operation === 'workplan_update') {
      const document = await readFile(filename, 'utf8');
      if (hash(document) !== input.expectedContentHash) throw new Error('메모가 변경되었습니다. 최신 내용을 다시 확인해 주세요');
      const header = document.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/)?.[1];
      if (!header || !/^authority_status: (?:proposal|"proposal")\s*$/m.test(header) || !/^status: (?:draft|"draft")\s*$/m.test(header) || !/^approval_revision:\s*(?:null)?\s*$/m.test(header)) throw new Error('승인 준비/승인된 메모는 덮어쓸 수 없습니다. feedback 절차를 사용해 주세요');
      const updated = replaceBody(document, input.memoBody);
      await atomicText(filename, updated);
      return { status: 'updated', workplan: filename, contentHash: hash(updated), approvalRequired: true };
    }
    if (operation === 'workplan_prepare') {
      const prepared = await this.runBundledRuby('workplan-memo.rb', ['prepare', ...base, filename], { project });
      const approval = await this.runBundledRuby('workplan-memo.rb', ['validate', ...base, '--phase', 'approval', filename], { project });
      return { ...prepared, ...approval };
    }
    if (operation === 'workplan_approve') {
      if (!/^sha256:[a-f0-9]{64}$/.test(input.expectedRevision) || !input.approvalSource?.trim()) throw new Error('확인한 revision과 실제 사용자 승인 메시지 참조가 필요합니다');
      argv = ['approve', '--expected-revision', input.expectedRevision, '--approved-by', 'user', '--source', input.approvalSource, filename];
    }
    if (operation === 'workplan_start') argv = ['apply', ...base, filename];
    if (operation === 'workplan_feedback') {
      const command = { correction: 'correction-start', scope_change: 'feedback-prepare', approved_scope_change: 'feedback-apply' }[input.mode];
      if (!command) throw new Error('지원하지 않는 feedback 분기입니다');
      if (command === 'feedback-prepare') {
        const document = await readFile(filename, 'utf8');
        if (hash(document) !== input.expectedContentHash) throw new Error('추가 계획 작성 전 메모가 변경되었습니다');
        memoBody(input.memoBody);
      }
      argv = [command, ...base];
      if (command !== 'feedback-apply') {
        argv.push('--reason', input.reason);
        addMany(argv, '--scope', input.scopePaths);
        addMany(argv, '--verification', input.verification);
      }
      argv.push(filename);
    }
    if (operation === 'workplan_result') {
      if (!input.summary?.trim()) throw new Error('실제 변경 설명이 필요합니다');
      argv = ['result', ...base, '--summary', input.summary, '--verification-status', input.verificationStatus];
      addMany(argv, '--verification', input.verification);
      for (const [scope, explanation] of Object.entries(input.explanations ?? {})) {
        if (scope.includes('=') || !explanation.trim()) throw new Error('파일별 실제 변경 설명이 잘못되었습니다');
        argv.push('--explanation', `${scope}=${explanation}`);
      }
      if (input.verificationRunId) {
        assertId(input.verificationRunId, '검증 실행 ID');
        if (!this.verification) throw new Error('실제 검증 보고 서비스가 연결되지 않았습니다');
        const report = await this.verification.report({ projectId: project.projectId, runId: input.verificationRunId });
        if (report.workplanBinding?.workplanId !== input.workplanId) throw new Error('다른 Workplan 또는 미연결 검증 실행을 현재 메모의 통과 증거로 사용할 수 없습니다');
        await requireWorkplanBinding(project, report.workplanBinding);
        const testCount = report.results?.reduce((count, item) => count + item.executed, 0);
        if (input.verificationStatus !== 'passed' || report.status !== 'passed' || !report.inputsCurrent || !Number.isInteger(testCount) || testCount <= 0 || report.ui?.tier !== 'none') throw new Error('현재 코드와 일치하는 tier none의 실제 통과 검증만 연결할 수 있습니다');
        const resultFile = await requireWithin(path.dirname(filename), path.join(path.dirname(filename), 'Artifacts', 'verification', `${input.verificationRunId}.json`), { allowMissing: true });
        await atomicJSON(resultFile, { schema: 'verification-result-v1', kind: 'test', status: 'passed', exit_status: 0, test_count: testCount, project_id: project.projectId, workplanBinding: report.workplanBinding, source_run: report.id, results: report.results });
        argv.push('--verification-result', resultFile);
      } else if (input.verificationResultId) {
        throw new Error('원천을 확인하지 않은 검증 JSON 대신 현재 Workplan에 연결된 verificationRunId를 사용해 주세요');
      }
      argv.push(filename);
    }
    const result = await this.runBundledRuby('workplan-memo.rb', argv, { project });
    if (operation === 'workplan_feedback' && input.mode === 'scope_change') {
      // 기존 CLI가 승인 권한을 proposal로 돌린 뒤에만 추가 계획 본문을 쓴다.
      await atomicText(filename, replaceBody(await readFile(filename, 'utf8'), input.memoBody));
      const approval = await this.runBundledRuby('workplan-memo.rb', ['validate', ...base, '--phase', 'approval', filename], { project });
      return { ...result, ...approval };
    }
    return result;
  }
}
