import { constants } from 'node:fs';
import { access, lstat, mkdir, open, opendir, readFile, realpath, rename, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID, createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { validateObservation, safeReference } from './integrations.mjs';

export const DEFAULT_EXCLUDES = ['node_modules', 'Pods', 'build', '.build', '.git', '.gradle', 'vendor', 'dist'];
const executeFile = promisify(execFile);
export const identifier = (value) => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$/.test(value);

export function assertId(value, label = 'ID') {
  if (!identifier(value)) throw new Error(`${label} 형식이 잘못되었습니다`);
  return value;
}

export function isWithin(root, target) {
  const relative = path.relative(root, target);
  return relative === '' || (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative));
}

export async function canonicalPath(value, { allowMissing = false } = {}) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) throw new Error('절대 경로가 필요합니다');
  const normalized = path.resolve(value);
  try { return await realpath(normalized); } catch (error) {
    if (!allowMissing || error.code !== 'ENOENT') throw error;
    return path.join(await canonicalPath(path.dirname(normalized), { allowMissing: true }), path.basename(normalized));
  }
}

export async function requireWithin(root, target, options) {
  const [safeRoot, safeTarget] = await Promise.all([canonicalPath(root, options), canonicalPath(target, options)]);
  if (!isWithin(safeRoot, safeTarget)) throw new Error('허용한 기록 경로 밖으로 접근할 수 없습니다');
  return safeTarget;
}

export async function atomicJSON(filename, value) {
  const parent = await canonicalPath(path.dirname(filename), { allowMissing: true });
  await mkdir(parent, { recursive: true, mode: 0o700 });
  const temporary = path.join(parent, `.${path.basename(filename)}.${randomUUID()}.tmp`);
  const handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`);
    await handle.sync();
    await handle.close();
    await rename(temporary, path.join(parent, path.basename(filename)));
  } finally { await handle.close().catch(() => {}); await rm(temporary, { force: true }); }
}

export function checkKeys(value, allowed, label = '입력') {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label}은 객체여야 합니다`);
  for (const key of Object.keys(value)) {
    if (!allowed.includes(key)) throw new Error(`${label}: 허용하지 않은 필드 ${key}`);
  }
}

export async function requireWorkplanBinding(project, binding) {
  checkKeys(binding, ['workplanId', 'approvalRevision'], 'Workplan 검증 연결');
  assertId(binding.workplanId, 'Workplan ID');
  if (!/^sha256:[a-f0-9]{64}$/.test(binding.approvalRevision)) throw new Error('확인한 Workplan 승인 revision이 필요합니다');
  const bundle = path.join(project.workplanRoot, binding.workplanId);
  const filename = await requireWithin(project.workplanRoot, path.join(bundle, `${binding.workplanId}.md`));
  if ((await lstat(bundle)).isSymbolicLink() || (await lstat(filename)).isSymbolicLink()) throw new Error('Workplan 연결에는 symlink를 사용할 수 없습니다');
  const header = (await readFile(filename, 'utf8')).match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/)?.[1];
  const revision = header?.match(/^approval_revision: ["']?(sha256:[a-f0-9]{64})["']?\s*$/m)?.[1];
  if (!/^authority_status: (?:approved|"approved")\s*$/m.test(header ?? '') || revision !== binding.approvalRevision) throw new Error('현재 Workplan의 실제 승인 revision과 검증 연결이 다릅니다');
  return { workplanId: binding.workplanId, approvalRevision: revision };
}

function confirmation(value) {
  if (value.confirmed !== true || typeof value.confirmationSource !== 'string' || !value.confirmationSource.trim()) throw new Error('실제 사용자 확인 메시지 참조가 필요합니다');
}

export async function withLock(filename, action) {
  await mkdir(path.dirname(filename), { recursive: true, mode: 0o700 });
  // 두 호스트가 같은 기록을 수정할 때 먼저 얻은 한 요청만 확정한다. 남은 잠금은 자동 탈취하지 않는다.
  try { await mkdir(filename, { mode: 0o700 }); } catch (error) {
    if (error.code === 'EEXIST') throw new Error('다른 요청이 이 기록을 수정 중입니다. 잠시 후 다시 시도해 주세요');
    throw error;
  }
  try { return await action(); } finally { await rm(filename, { recursive: true }); }
}

const exists = async (filename) => access(filename).then(() => true, () => false);

export function normalizeRemote(value) {
  if (!value) return null;
  const remote = value.trim();
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(remote)) {
    const url = new URL(remote);
    if (url.password || (url.username && url.protocol !== 'ssh:') || url.search || url.hash) throw new Error('인증값이 포함된 Git remote는 저장할 수 없습니다. credential helper를 사용해 주세요');
  }
  return remote.replace(/^git@([^:]+):(.+)$/, 'https://$1/$2').replace(/\.git$/, '').replace(/\/$/, '');
}

async function gitIdentity(repositoryPath) {
  if (!await exists(path.join(repositoryPath, '.git'))) return null;
  const read = async (...args) => {
    try {
      const result = await executeFile('git', ['--no-optional-locks', '-C', repositoryPath, ...args], { shell: false, timeout: 5000, maxBuffer: 64 * 1024, env: { PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: process.env.HOME, LANG: 'en_US.UTF-8', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } });
      return result.stdout.trim();
    } catch { throw new Error('프로젝트 Git 정보를 안전하게 확인하지 못했습니다'); }
  };
  const root = await canonicalPath(await read('rev-parse', '--show-toplevel'));
  if (root !== repositoryPath) throw new Error('확인한 후보와 실제 Git root가 다릅니다');
  const gitDir = await canonicalPath(await read('rev-parse', '--absolute-git-dir'));
  const remotes = (await read('remote')).split('\n');
  const remote = remotes.includes('origin') ? normalizeRemote(await read('remote', 'get-url', 'origin')) : null;
  return { repositoryPath: root, gitDir, remote, branch: await read('branch', '--show-current') };
}

function validateRootOptions(root) {
  checkKeys(root, ['path', 'maxDepth', 'excludedNames'], '탐색 root');
  if (!Number.isInteger(root.maxDepth ?? 3) || (root.maxDepth ?? 3) < 0 || (root.maxDepth ?? 3) > 8) throw new Error('탐색 깊이는 0~8이어야 합니다');
  if (root.excludedNames && (!Array.isArray(root.excludedNames) || root.excludedNames.some((name) => typeof name !== 'string' || name.includes('/') || name === '..'))) throw new Error('제외 폴더 이름이 잘못되었습니다');
}

export class SettingsStore {
  async recordIntegration(input) {
    checkKeys(input, ['observation', 'confirmed', 'confirmationSource'], '연동 기록');
    confirmation(input);
    safeReference(input.confirmationSource);
    const observation = validateObservation(input.observation);
    if (observation.provider === 'serena' && observation.state === 'read_verified') {
      assertId(observation.projectId, 'Serena 확인 프로젝트 ID');
      await this.requireTrustedProject(observation.projectId);
    }
    return withLock(`${this.configPath}.lock`, async () => {
      const next = await this.load();
      next.integrations ??= {};
      next.integrations[observation.client] ??= {};
      const prior = next.integrations[observation.client][observation.provider];
      const entry = { ...observation, observedAt: new Date().toISOString(), confirmationSource: input.confirmationSource };
      // 실패·만료는 현재 상태만 갱신하고 마지막 읽기 근거는 과거 기록으로 보존한다.
      const lastRead = observation.state === 'read_verified' ? { connectionRef: observation.connectionRef, resourceRef: observation.resourceRef, evidenceRef: observation.evidenceRef, capabilities: observation.capabilities, checkedAt: entry.observedAt } : prior?.lastRead;
      if (lastRead) entry.lastRead = lastRead;
      next.integrations[observation.client][observation.provider] = entry;
      await atomicJSON(this.configPath, next);
      return { saved: true, connection: entry, credentialsStored: false };
    });
  }

  constructor({ configPath = path.join(os.homedir(), '.config/ai-workflow/settings.json'), dataRoot = path.join(os.homedir(), '.local/share/ai-workflow') } = {}) {
    this.configPath = configPath;
    this.dataRoot = dataRoot;
  }

  async load() {
    try {
      const data = JSON.parse(await readFile(this.configPath, 'utf8'));
      if (data.schemaVersion !== 1) throw new Error('지원하지 않는 설정 schema입니다');
      return data;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return { schemaVersion: 1, projectRoots: [], workspaces: {}, projects: {}, clients: [], services: {} };
    }
  }

  // 두 호스트가 같은 설정과 기록을 사용한다. 기존 외부 경로·신뢰·서비스는 덮어쓰지 않는다.
  async initializeRecords({ clients = [], confirmed, confirmationSource }) {
    confirmation({ confirmed, confirmationSource });
    if (!Array.isArray(clients) || clients.some(client => !['codex', 'claude'].includes(client))) throw new Error('지원하지 않는 클라이언트입니다');
    return withLock(`${this.configPath}.lock`, async () => {
      const settings = await this.load();
      const managedRoot = await requireWithin(this.dataRoot, path.join(this.dataRoot, 'workspaces/personal'), { allowMissing: true });
      const projectsRoot = await requireWithin(managedRoot, path.join(managedRoot, 'projects'), { allowMissing: true });
      await mkdir(projectsRoot, { recursive: true, mode: 0o700 });
      settings.clients = [...new Set([...settings.clients, ...clients])];
      settings.workspaces.personal ??= { root: managedRoot, trusted: false };
      await atomicJSON(this.configPath, settings);
      return { recordsRoot: managedRoot, projectsRoot, configPath: this.configPath };
    });
  }

  async save(patch) {
    checkKeys(patch, ['confirmed', 'confirmationSource', 'clients', 'projectRoots', 'workspaces', 'services']);
    confirmation(patch);
    return withLock(`${this.configPath}.lock`, async () => {
      const next = await this.load();
      if (patch.clients) {
        if (!Array.isArray(patch.clients) || patch.clients.some((client) => !['codex', 'claude'].includes(client))) throw new Error('지원하지 않는 클라이언트입니다');
        next.clients = [...new Set(patch.clients)];
      }
      if (patch.projectRoots) {
        if (!Array.isArray(patch.projectRoots) || patch.projectRoots.length > 30) throw new Error('탐색 root는 최대 30개입니다');
        next.projectRoots = await Promise.all(patch.projectRoots.map(async (root) => {
          validateRootOptions(root);
          const rootPath = await canonicalPath(root.path);
          if (rootPath === path.parse(rootPath).root || rootPath === await canonicalPath(os.homedir())) throw new Error('홈 전체 또는 파일 시스템 전체는 탐색할 수 없습니다');
          return { path: rootPath, maxDepth: root.maxDepth ?? 3, excludedNames: [...new Set([...DEFAULT_EXCLUDES, ...(root.excludedNames ?? [])])] };
        }));
      }
      if (patch.workspaces) {
        checkKeys(patch.workspaces, Object.keys(patch.workspaces), '작업공간 목록');
        for (const [id, workspace] of Object.entries(patch.workspaces)) {
          assertId(id, 'workspace ID');
          checkKeys(workspace, ['root', 'trusted', 'trustSource'], '작업공간');
          if (workspace.trusted === true && !workspace.trustSource?.trim()) throw new Error('작업공간 실행 신뢰는 별도 사용자 확인 참조가 필요합니다');
          const root = await canonicalPath(workspace.root, { allowMissing: true });
          if (root === path.parse(root).root || root === await canonicalPath(os.homedir())) throw new Error('작업공간 root가 너무 넓습니다');
          next.workspaces[id] = { root, trusted: workspace.trusted === true, ...(workspace.trusted ? { trustSource: workspace.trustSource } : {}) };
        }
      }
      if (patch.services) {
        checkKeys(patch.services, ['jira', 'figma', 'datadog', 'serena', 'xcode']);
        for (const [name, service] of Object.entries(patch.services)) {
          // 값 자체가 아닌 connector/환경 변수 이름만 저장한다. 토큰을 받는 범용 필드는 제공하지 않는다.
          checkKeys(service, ['connectionRef', 'environmentVariable', 'projectId', 'assigneeId', 'startStatusId', 'available']);
          for (const [key, value] of Object.entries(service)) {
            if (key === 'available' ? typeof value !== 'boolean' : typeof value !== 'string' || value.length > 200) throw new Error('서비스 설정 형식이 잘못되었습니다');
            if (typeof value === 'string' && /(?:Bearer\s|gh[pousr]_|sk-[A-Za-z0-9]|-----BEGIN)/i.test(value)) throw new Error('비밀정보는 설정에 저장할 수 없습니다');
          }
          if (service.environmentVariable && !/^[A-Z_][A-Z0-9_]*$/.test(service.environmentVariable)) throw new Error('환경 변수 이름만 저장할 수 있습니다');
          next.services[name] = service;
        }
      }
      await atomicJSON(this.configPath, next);
      return next;
    });
  }

  async discover({ root, maxDepth = 3, excludedNames = [] }) {
    validateRootOptions({ path: root, maxDepth, excludedNames });
    const scanRoot = await canonicalPath(root);
    if (scanRoot === path.parse(scanRoot).root || scanRoot === await canonicalPath(os.homedir())) throw new Error('홈 전체 또는 파일 시스템 전체는 탐색할 수 없습니다');
    const excluded = new Set([...DEFAULT_EXCLUDES, ...excludedNames]);
    const candidates = [];
    let visited = 0;
    let examinedEntries = 0;
    let truncated = false;
    const walk = async (directory, depth) => {
      if (++visited > 2000) { truncated = true; return; }
      const entries = [];
      for await (const entry of await opendir(directory)) {
        if (++examinedEntries > 10_000) { truncated = true; break; }
        entries.push(entry);
      }
      const names = new Set(entries.map((entry) => entry.name));
      const markers = ['.git', 'Package.swift', 'package.json', 'settings.gradle', 'settings.gradle.kts', 'build.gradle', 'build.gradle.kts'].filter((name) => names.has(name));
      markers.push(...entries.filter((entry) => /\.(xcodeproj|xcworkspace)$/.test(entry.name)).map((entry) => entry.name));
      if (markers.length) {
        candidates.push({ candidateId: createHash('sha256').update(directory).digest('hex').slice(0, 24), repositoryPath: directory, markers, git: names.has('.git') });
        return;
      }
      if (depth >= maxDepth) { if (entries.some((entry) => entry.isDirectory() && !excluded.has(entry.name))) truncated = true; return; }
      for (const entry of entries) {
        if (visited >= 2000 || examinedEntries >= 10_000) { truncated = true; break; }
        if (!entry.isDirectory() || entry.isSymbolicLink() || excluded.has(entry.name) || entry.name.startsWith('.')) continue;
        await walk(path.join(directory, entry.name), depth + 1).catch((error) => { if (['EACCES', 'ENOENT'].includes(error.code)) truncated = true; else throw error; });
      }
    };
    await walk(scanRoot, 0);
    const discoveryId = randomUUID();
    const result = { discoveryId, root: scanRoot, maxDepth, excludedNames: [...excluded], candidates, visited, examinedEntries, truncated, warning: '표식은 후보일 뿐입니다. 중첩 앱과 제한 밖 폴더는 자동 등록하지 않습니다' };
    await atomicJSON(path.join(this.dataRoot, 'discoveries', `${discoveryId}.json`), result);
    return result;
  }

  async confirmProject(input) {
    checkKeys(input, ['discoveryId', 'candidateId', 'projectId', 'workspaceId', 'confirmed', 'confirmationSource', 'executionTrusted', 'trustSource', 'workplanRoot', 'productMemoryRoot', 'instructionsRoot']);
    confirmation(input);
    for (const field of ['discoveryId', 'candidateId', 'projectId', 'workspaceId']) assertId(input[field], field);
    if (input.executionTrusted === true && !input.trustSource?.trim()) throw new Error('프로젝트 등록과 실행 신뢰 확인은 별개입니다');
    const discoveryFile = await requireWithin(path.join(this.dataRoot, 'discoveries'), path.join(this.dataRoot, 'discoveries', `${input.discoveryId}.json`));
    const discovery = JSON.parse(await readFile(discoveryFile, 'utf8'));
    const candidate = discovery.candidates.find((item) => item.candidateId === input.candidateId);
    if (!candidate) throw new Error('확인할 탐색 후보가 없습니다');
    const repositoryPath = await requireWithin(discovery.root, candidate.repositoryPath);
    const identity = await gitIdentity(repositoryPath);
    return withLock(`${this.configPath}.lock`, async () => {
      const settings = await this.load();
      const workspace = settings.workspaces[input.workspaceId];
      if (!workspace) throw new Error('먼저 작업공간을 확인해 주세요');
      if (settings.projects[input.projectId] && settings.projects[input.projectId].repositoryPath !== repositoryPath) throw new Error('같은 project ID가 다른 위치에 등록되어 있습니다');
      if (Object.hasOwn(settings.projects, input.projectId) && settings.projects[input.projectId].workspaceId !== input.workspaceId) throw new Error('다른 작업공간에는 별도 project ID를 사용해 기록을 분리해 주세요');
      const managed = path.join(this.dataRoot, 'workspaces', input.workspaceId, 'projects', input.projectId);
      const project = { workspaceId: input.workspaceId, repositoryPath, ...(identity ? { gitIdentity: identity, remote: identity.remote } : {}), executionTrusted: input.executionTrusted === true, ...(input.executionTrusted ? { trustSource: input.trustSource } : {}) };
      for (const [key, folder] of [['workplanRoot', 'Workplans'], ['productMemoryRoot', 'ProductMemory'], ['instructionsRoot', 'Instructions']]) {
        const recordRoot = input[key]
          ? await requireWithin(workspace.root, input[key], { allowMissing: true })
          : await requireWithin(managed, path.join(managed, folder), { allowMissing: true });
        if (isWithin(repositoryPath, recordRoot)) throw new Error('제품 코드 저장소 안에 AI 기록을 만들 수 없습니다');
        project[key] = recordRoot;
      }
      if (['workplanRoot', 'productMemoryRoot', 'instructionsRoot'].some((key) => !input[key])) {
        const ownedRoot = await requireWithin(this.dataRoot, managed, { allowMissing: true });
        await mkdir(path.dirname(ownedRoot), { recursive: true, mode: 0o700 });
        let created = false;
        try { await mkdir(ownedRoot, { mode: 0o700 }); created = true; } catch (error) { if (error.code !== 'EEXIST') throw error; }
        const ownershipId = `${input.workspaceId}--${input.projectId}`;
        const id = ownershipId.length <= 100 ? ownershipId : `project-${createHash('sha256').update(ownershipId).digest('hex')}`;
        const marker = await requireWithin(ownedRoot, path.join(ownedRoot, '.ai-workflow-owned.json'), { allowMissing: true });
        const ownership = { schemaVersion: 1, owner: 'ai-workflow', id, path: ownedRoot, external: false };
        if (created) await atomicJSON(marker, ownership);
        let existing;
        try { existing = JSON.parse(await readFile(marker, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        // 기존 외부/무표시 폴더를 삭제 대상인 자기 소유로 승격하지 않는다.
        if (existing?.owner === ownership.owner && existing?.id === id && existing?.path === ownedRoot && existing?.external === false) {
          const registry = await requireWithin(this.dataRoot, path.join(this.dataRoot, 'owned-records', `${id}.json`), { allowMissing: true });
          await atomicJSON(registry, ownership);
        }
      }
      for (const key of ['workplanRoot', 'productMemoryRoot', 'instructionsRoot']) await mkdir(project[key], { recursive: true, mode: 0o700 });
      settings.projects[input.projectId] = project;
      await atomicJSON(this.configPath, settings);
      return { projectId: input.projectId, ...project, git: await exists(path.join(repositoryPath, '.git')) };
    });
  }

  async requireProject(projectId, { trusted = false } = {}) {
    assertId(projectId, 'project ID');
    const settings = await this.load();
    if (!Object.hasOwn(settings.projects, projectId)) throw new Error('등록되지 않은 프로젝트입니다');
    const project = settings.projects[projectId];
    const workspace = settings.workspaces[project.workspaceId];
    if (!workspace) throw new Error('프로젝트 작업공간이 없습니다');
    if (trusted && (!project.executionTrusted || !project.trustSource)) throw new Error('이 프로젝트의 실행 신뢰를 먼저 확인해 주세요');
    const repositoryPath = await canonicalPath(project.repositoryPath);
    const workspacePath = await canonicalPath(workspace.root, { allowMissing: true });
    const managed = await canonicalPath(path.join(this.dataRoot, 'workspaces', project.workspaceId, 'projects', projectId), { allowMissing: true });
    for (const key of ['workplanRoot', 'productMemoryRoot', 'instructionsRoot']) {
      const recordRoot = await canonicalPath(project[key], { allowMissing: true });
      if (!isWithin(workspacePath, recordRoot) && !isWithin(managed, recordRoot)) throw new Error('선택한 프로젝트의 기록 경로 밖입니다');
      if (isWithin(repositoryPath, recordRoot)) throw new Error('제품 저장소 내부 기록은 허용하지 않습니다');
    }
    const git = await exists(path.join(repositoryPath, '.git'));
    if (trusted) {
      const actual = await gitIdentity(repositoryPath);
      if (git && (!project.gitIdentity || !actual || actual.repositoryPath !== project.gitIdentity.repositoryPath || actual.gitDir !== project.gitIdentity.gitDir || actual.remote !== project.gitIdentity.remote)) throw new Error('등록 이후 Git root·gitdir·remote가 바뀌었습니다. 현재 위치와 실행 신뢰를 다시 확인해 주세요');
      if (!git && project.gitIdentity) throw new Error('등록된 Git 저장소가 사라졌습니다. 프로젝트를 다시 확인해 주세요');
    }
    return { projectId, ...project, repositoryPath, workspacePath, workspaceTrusted: workspace.trusted === true, git };
  }

  async requireTrustedProject(projectId) { return this.requireProject(projectId, { trusted: true }); }

  async projectContext({ projectId, currentPath } = {}) {
    if (!projectId) {
      if (!currentPath) throw new Error('호스트의 현재 폴더 또는 project ID가 필요합니다');
      const current = await canonicalPath(currentPath);
      const matches = [];
      for (const [id, project] of Object.entries((await this.load()).projects)) {
        if (isWithin(await canonicalPath(project.repositoryPath), current)) matches.push(id);
      }
      if (matches.length !== 1) return { status: matches.length ? 'ambiguous' : 'unregistered', candidates: matches, requiresConfirmation: true };
      [projectId] = matches;
    }
    const project = await this.requireProject(projectId);
    if (currentPath && !isWithin(project.repositoryPath, await canonicalPath(currentPath))) throw new Error('현재 폴더와 선택 프로젝트가 다릅니다');
    return { status: 'registered', ...project, capabilities: { contextRead: true, workplanExecution: project.git && project.executionTrusted } };
  }

  async readContext({ projectId, documentId } = {}) {
    const project = await this.requireProject(projectId);
    const roots = { instructions: project.instructionsRoot, memory: project.productMemoryRoot, workplans: project.workplanRoot };
    const list = async (kind, directory, relative = '', limit = 100) => {
      const documents = [];
      let visited = 0;
      let truncated = false;
      for await (const entry of await opendir(directory)) {
        if (++visited > limit) { truncated = true; break; }
        const documentPath = path.posix.join(relative, entry.name);
        if (entry.isDirectory()) documents.push({ documentId: `${kind}:${documentPath}/`, directory: true });
        else if (entry.isFile() && /\.(md|json|ya?ml)$/.test(entry.name)) documents.push({ documentId: `${kind}:${documentPath}` });
      }
      return { documents, truncated };
    };
    if (!documentId) {
      const documents = [];
      let truncated = false;
      for (const [kind, root] of Object.entries(roots)) {
        if (!await exists(root)) continue;
        const listing = await list(kind, root, '', 100 - documents.length);
        documents.push(...listing.documents);
        truncated ||= listing.truncated;
      }
      return { projectId, documents, limit: 100, truncated };
    }
    const separator = documentId.indexOf(':');
    const kind = documentId.slice(0, separator);
    const relative = documentId.slice(separator + 1);
    if (separator < 0 || !Object.hasOwn(roots, kind) || path.isAbsolute(relative) || relative.includes('\0') || relative.split(/[\\/]/).some((part) => part === '..')) throw new Error('문서 ID가 잘못되었습니다');
    const filename = await requireWithin(roots[kind], path.join(roots[kind], relative));
    const info = await stat(filename);
    if (info.isDirectory()) {
      return { projectId, documentId, source: filename, ...await list(kind, filename, relative), limit: 100, untrustedContent: true };
    }
    if (!/\.(md|json|ya?ml)$/.test(relative)) throw new Error('문서 ID가 잘못되었습니다');
    if (!info.isFile() || info.size > 256 * 1024) throw new Error('문서는 최대 256 KiB까지 조회할 수 있습니다');
    const content = await readFile(filename, 'utf8');
    return { projectId, documentId, source: filename, modifiedAt: info.mtime.toISOString(), contentHash: createHash('sha256').update(content).digest('hex'), content, untrustedContent: true };
  }
}
