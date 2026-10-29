import { constants } from 'node:fs';
import { lstat, mkdir, open, opendir, readFile, rename, rm, stat } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { assertId, canonicalPath, isWithin, requireWithin, atomicJSON, withLock } from './settings.mjs';

const MAX_BYTES = 256 * 1024;
const DOCUMENT = /\.(md|txt|json|ya?ml)$/i;
const hash = value => createHash('sha256').update(value).digest('hex');
const present = filename => lstat(filename).catch(error => { if (error.code === 'ENOENT') return null; throw error; });

async function safePath(root, relative, { missing = false } = {}) {
  if (!relative || path.isAbsolute(relative) || relative.includes('\\') || relative.includes('\0') || relative.split('/').some(part => !part || part === '.' || part === '..' || part.startsWith('.'))) throw new Error('기록 ID가 잘못되었습니다');
  const base = await canonicalPath(root, { allowMissing: missing });
  if (base !== path.resolve(root)) throw new Error('허용한 기록 root의 실제 경로가 바뀌었습니다');
  let current = base;
  for (const part of relative.split('/')) {
    current = path.join(current, part);
    const info = await present(current);
    if (info?.isSymbolicLink()) throw new Error('기록 경로에는 symlink를 사용할 수 없습니다');
  }
  return requireWithin(base, current, { allowMissing: missing });
}

async function readDocument(filename) {
  const handle = await open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await handle.stat();
    if (!info.isFile() || info.size > MAX_BYTES) throw new Error('문서는 최대 256 KiB까지 조회할 수 있습니다');
    const buffer = Buffer.alloc(MAX_BYTES + 1);
    let bytesRead = 0;
    while (bytesRead < buffer.length) {
      const chunk = await handle.read(buffer, bytesRead, buffer.length - bytesRead, bytesRead);
      if (!chunk.bytesRead) break;
      bytesRead += chunk.bytesRead;
    }
    if (bytesRead > MAX_BYTES) throw new Error('문서는 최대 256 KiB까지 조회할 수 있습니다');
    const bytes = buffer.subarray(0, bytesRead);
    return { content: bytes.toString('utf8'), contentHash: hash(bytes), modifiedAt: info.mtime.toISOString() };
  } finally { await handle.close(); }
}

async function listing(kind, directory, relative = '', limit = 100) {
  if (await canonicalPath(directory, { allowMissing: true }) !== path.resolve(directory)) throw new Error('허용한 기록 root의 실제 경로가 바뀌었습니다');
  const documents = [];
  let examined = 0;
  let truncated = false;
  try {
    for await (const entry of await opendir(directory)) {
      if (++examined > 100 || documents.length >= limit) { truncated = true; break; }
      if (entry.name.startsWith('.') || entry.isSymbolicLink()) continue;
      const suffix = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory() || (entry.isFile() && DOCUMENT.test(entry.name))) documents.push({ documentId: `${kind}:${suffix}${entry.isDirectory() ? '/' : ''}`, directory: entry.isDirectory() });
    }
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  return { documents, examined, truncated };
}

export class RecordService {
  constructor({ store }) { this.store = store; }

  async scope({ projectId, workspaceId, currentPath } = {}) {
    if (projectId || currentPath) {
      const project = await this.store.projectContext({ projectId, ...(projectId ? {} : { currentPath }) });
      if (project.status !== 'registered') return { ...project, candidates: project.candidates.slice(0, 20) };
      if (workspaceId && workspaceId !== project.workspaceId) throw new Error('선택 프로젝트와 작업공간이 다릅니다');
      const policyPath = path.join(project.workspacePath, 'workspace.yaml');
      const policy = await present(policyPath);
      // 조회할 원문 위치일 뿐 record_save에 새 쓰기 root를 허용하지 않는다.
      const contextSources = {
        projectInstructions: project.instructionsRoot,
        workspacePolicy: { path: policy?.isFile() ? policyPath : null, status: policy?.isFile() ? 'available' : 'not_found' }
      };
      return { projectId: project.projectId, workspaceId: project.workspaceId, recordLinks: project.recordLinks ?? {}, taskLinks: project.taskLinks ?? {}, contextSources, roots: { instructions: project.instructionsRoot, memory: project.productMemoryRoot, workplans: project.workplanRoot } };
    }
    if (!workspaceId) throw new Error('확인된 project ID·workspace ID 또는 호스트 현재 폴더가 필요합니다');
    assertId(workspaceId, 'workspace ID');
    const settings = await this.store.projectCatalog();
    if (!Object.hasOwn(settings.workspaces, workspaceId)) throw new Error('등록되지 않은 작업공간입니다');
    return { workspaceId, roots: { documents: settings.workspaces[workspaceId].root } };
  }

  async resolve(input, recordId, missing = false) {
    const scope = await this.scope(input);
    if (!scope.roots) throw new Error('기록의 프로젝트를 명시해 주세요');
    recordId = scope.recordLinks?.[recordId] ?? recordId;
    const separator = recordId.indexOf(':');
    const kind = recordId.slice(0, separator);
    let relative = recordId.slice(separator + 1).replace(/\/$/, '');
    if (kind === 'workplans') {
      const [taskId, ...remaining] = relative.split('/');
      if (scope.taskLinks?.[taskId]) relative = [scope.taskLinks[taskId], ...remaining].join('/');
    }
    if (separator < 0 || !Object.hasOwn(scope.roots, kind)) throw new Error('기록 ID의 허용 자료 종류를 확인해 주세요');
    return { ...scope, kind, relative, root: scope.roots[kind], filename: await safePath(scope.roots[kind], relative, { missing }) };
  }

  async readContext(input = {}) {
    const scope = await this.scope(input);
    if (!scope.roots) return scope;
    const { roots, ...identity } = scope;
    if (!input.documentId) {
      const documents = [];
      let truncated = false;
      for (const [kind, root] of Object.entries(roots)) {
        const result = await listing(kind, root, '', 100 - documents.length);
        documents.push(...result.documents);
        truncated ||= result.truncated;
      }
      return { ...identity, documents, limit: 100, truncated, untrustedContent: true };
    }
    const target = await this.resolve(input, input.documentId);
    const info = await stat(target.filename);
    if (info.isDirectory()) return { ...identity, documentId: input.documentId, source: target.filename, ...await listing(target.kind, target.filename, target.relative), limit: 100, untrustedContent: true };
    if (!DOCUMENT.test(target.relative)) throw new Error('허용한 문서 형식이 아닙니다');
    return { ...identity, documentId: input.documentId, source: target.filename, ...await readDocument(target.filename), untrustedContent: true };
  }

  async currentTask(input = {}) {
    if (!Number.isInteger(input.limit ?? 10) || (input.limit ?? 10) < 1 || (input.limit ?? 10) > 20) throw new Error('작업 후보는 1~20개까지 조회할 수 있습니다');
    const scope = await this.scope(input);
    if (!scope.roots) return scope;
    const root = scope.roots.workplans ?? path.join(scope.roots.documents, 'Workplans');
    const identity = { ...(scope.projectId ? { projectId: scope.projectId } : {}), workspaceId: scope.workspaceId };
    if (input.taskId) {
      input = { ...input, taskId: scope.taskLinks?.[input.taskId] ?? input.taskId };
      assertId(input.taskId, 'task ID');
      for (const relative of [input.taskId, `${input.taskId}.md`]) {
        const filename = await safePath(root, relative, { missing: true });
        const info = await present(filename);
        if (info?.isDirectory() || (info?.isFile() && DOCUMENT.test(relative))) return { ...identity, status: 'found', taskId: input.taskId, recordPath: filename, artifactPath: info.isDirectory() ? path.join(filename, 'Artifacts') : null };
      }
      return { ...identity, status: 'not_found', taskId: input.taskId, searchedHistory: false };
    }
    const result = await listing('workplans', root, '', input.limit ?? 10);
    const candidates = result.documents.filter(document => document.directory || /\.md$/i.test(document.documentId)).map(document => ({ taskId: document.documentId.slice('workplans:'.length).replace(/\/$/, '').replace(/\.md$/i, ''), recordPath: path.join(root, document.documentId.slice('workplans:'.length)) }));
    return { ...identity, status: candidates.length ? 'candidates' : 'not_found', candidates, requiresConfirmation: candidates.length > 0, truncated: result.truncated, examined: result.examined, searchedHistory: false };
  }

  async save(input) {
    assertId(input.requestId, 'request ID');
    if (typeof input.content !== 'string' || Buffer.byteLength(input.content) > MAX_BYTES) throw new Error('기록 내용은 최대 256 KiB입니다');
    if (input.expectedContentHash !== undefined && !/^[a-f0-9]{64}$/.test(input.expectedContentHash)) throw new Error('읽었던 내용의 SHA-256 지문이 필요합니다');
    const target = await this.resolve(input, input.recordId, true);
    if (!DOCUMENT.test(target.relative)) throw new Error('허용한 문서 형식이 아닙니다');
    const fingerprint = hash(JSON.stringify({ filename: target.filename, content: input.content, expectedContentHash: input.expectedContentHash ?? null }));
    const metadataRoot = await requireWithin(this.store.dataRoot, path.join(this.store.dataRoot, 'record-saves'), { allowMissing: true });
    const dataRoot = await canonicalPath(this.store.dataRoot, { allowMissing: true });
    // 넓은 작업공간을 연결해도 설치 소유권·복구·저널은 일반 기록으로 덮어쓸 수 없다.
    const internalMetadata = isWithin(dataRoot, target.filename) && !isWithin(path.join(dataRoot, 'workspaces'), target.filename);
    if (internalMetadata || target.filename === await canonicalPath(this.store.configPath, { allowMissing: true })) throw new Error('설정과 저장 안전 메타데이터는 기록 대상으로 사용할 수 없습니다');
    const requestPath = await requireWithin(metadataRoot, path.join(metadataRoot, 'requests', `${hash(input.requestId)}.json`), { allowMissing: true });
    const conflict = reason => ({ status: 'conflict', saved: false, reason });
    try {
      return await withLock(`${requestPath}.lock`, async () => {
        let previous;
        try { previous = JSON.parse(await readFile(requestPath, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
        if (previous && previous.fingerprint !== fingerprint) return conflict('request_id_reused');
        if (previous?.status === 'complete') return { ...previous.result, replayed: true };
        const targetLock = await requireWithin(metadataRoot, path.join(metadataRoot, 'locks', hash(target.filename)), { allowMissing: true });
        return withLock(targetLock, async () => {
          await safePath(target.root, target.relative, { missing: true });
          const info = await present(target.filename);
          if (info && (!info.isFile() || info.nlink > 1)) throw new Error('일반 단일 기록 파일만 저장할 수 있습니다');
          const current = info ? await readDocument(target.filename) : null;
          const contentHash = hash(input.content);
          const result = { status: 'saved', saved: true, recordId: input.recordId, source: target.filename, contentHash, requestId: input.requestId };
          if (previous?.status === 'pending' && current?.contentHash === contentHash) {
            // rename 뒤 응답 전에 끊긴 요청만 복구하며, 다른 내용의 사용자 수정은 CAS로 보존한다.
            await atomicJSON(requestPath, { fingerprint, status: 'complete', result });
            return { ...result, replayed: true };
          }
          if (current ? current.contentHash !== input.expectedContentHash : input.expectedContentHash !== undefined) return conflict('content_changed');
          await mkdir(path.dirname(target.filename), { recursive: true, mode: 0o700 });
          await safePath(target.root, target.relative, { missing: true });
          await atomicJSON(requestPath, { fingerprint, status: 'pending' });
          const temporary = path.join(path.dirname(target.filename), `.cdpower-${randomUUID()}.tmp`);
          const handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | constants.O_NOFOLLOW, 0o600);
          try {
            await handle.writeFile(input.content);
            await handle.sync();
            await handle.close();
            await safePath(target.root, target.relative, { missing: true });
            const latest = await present(target.filename);
            if ((latest ? (await readDocument(target.filename)).contentHash : null) !== (current?.contentHash ?? null)) return conflict('content_changed');
            await rename(temporary, target.filename);
            await atomicJSON(requestPath, { fingerprint, status: 'complete', result });
            return result;
          } finally { await handle.close().catch(() => {}); await rm(temporary, { force: true }); }
        });
      });
    } catch (error) {
      if (/다른 요청이 이 기록을 수정 중/.test(error.message)) return conflict('locked');
      throw error;
    }
  }
}
