import path from 'node:path';
import os from 'node:os';
import { readFile, writeFile, mkdir, mkdtemp, readdir, lstat, rename, rm, access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { canonicalPath, requireWithin, atomicJSON, assertId } from './settings.mjs';

const execute = promisify(execFile);
const pluginRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const TYPES = new Set(['architecture', 'workflow', 'sequence', 'dataflow', 'lifecycle', 'erd', 'class', 'tree', 'timeline', 'waterfall']);
const COMPLEX = new Set(['cross-module', 'async-lifecycle', 'cross-system']);

async function treeManifest(root, relative = '') {
  const result = {};
  for (const entry of await readdir(path.join(root, relative), { withFileTypes: true })) {
    if (relative === '' && entry.name === '.ai-workflow-archify.json') continue;
    const name = path.join(relative, entry.name);
    const info = await lstat(path.join(root, name));
    if (info.isSymbolicLink()) throw new Error('Archify 실행 파일에는 symlink를 허용하지 않습니다');
    if (info.isDirectory()) Object.assign(result, await treeManifest(root, name));
    else if (info.isFile()) result[name] = digest(await readFile(path.join(root, name)));
    else throw new Error('일반 파일이 아닌 Archify 항목입니다');
  }
  return Object.fromEntries(Object.entries(result).sort(([a], [b]) => a.localeCompare(b)));
}

export async function provisionArchify({ destination, confirmed = false, lockPath = path.join(pluginRoot, 'third-party/archify.lock.json') }) {
  if (confirmed !== true) throw new Error('Archify 선택 다운로드 확인이 필요합니다');
  const lock = JSON.parse(await readFile(lockPath, 'utf8'));
  const target = await canonicalPath(destination, { allowMissing: true });
  try { await access(target); throw new Error('Archify 설치 위치가 이미 존재합니다'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'ai-workflow-archify-'));
  try {
    const response = await fetch(lock.archiveUrl, { signal: AbortSignal.timeout(30_000), redirect: 'error' });
    if (!response.ok) throw new Error(`Archify 다운로드 실패: ${response.status}`);
    const bytes = Buffer.from(await response.arrayBuffer());
    if (bytes.length > 50 * 1024 * 1024 || digest(bytes) !== lock.sha256) throw new Error('Archify 고정 archive 무결성 불일치');
    const archive = path.join(temporary, 'source.tar.gz');
    await writeFile(archive, bytes, { mode: 0o600, flag: 'wx' });
    const output = path.join(temporary, 'source');
    await mkdir(output);
    // 고정 해시의 원본 중 archify 하위만 푼다. 사용자 입력을 tar 인자로 전달하지 않는다.
    await execute('tar', ['-xzf', archive, '-C', output, '--strip-components=2', lock.archiveDirectory], { timeout: 30_000 });
    const files = await treeManifest(output);
    if (!files[lock.entrypoint] || !files.LICENSE || !files['THIRD_PARTY_NOTICES.md']) throw new Error('Archify 실행 파일 또는 라이선스 누락');
    await atomicJSON(path.join(output, '.ai-workflow-archify.json'), { commit: lock.commit, files });
    await mkdir(path.dirname(target), { recursive: true });
    await rename(output, target);
    return { status: 'installed', destination: target, version: lock.version, commit: lock.commit };
  } finally { await rm(temporary, { recursive: true, force: true }); }
}

export class DiagramService {
  constructor({ store, archifyRoot, lockPath = path.join(pluginRoot, 'third-party/archify.lock.json'), runner = execute } = {}) {
    this.store = store;
    this.archifyRoot = archifyRoot || path.join(store.dataRoot, 'tools', 'archify');
    this.lockPath = lockPath;
    this.runner = runner;
  }

  async visualize({ projectId, workplanId, diagram, complexity, enabled = true, perspective, sourceReferences = [], attempt = 1 }) {
    if (!enabled || !COMPLEX.has(complexity)) return { status: 'skipped', reason: '단순 변경이거나 시각화를 선택하지 않았습니다' };
    assertId(workplanId, 'Workplan ID');
    if (!['current', 'proposed', 'comparison'].includes(perspective)) throw new Error('현재/제안 구분이 필요합니다');
    if (!Number.isInteger(attempt) || attempt < 1 || attempt > 2) throw new Error('그림 생성은 최대 두 번으로 제한합니다');
    if (!diagram || !TYPES.has(diagram.diagram_type) || !Array.isArray(sourceReferences) || !sourceReferences.length) throw new Error('그림 종류와 이미 조사한 근거가 필요합니다');
    if (JSON.stringify(diagram).length > 1_000_000) throw new Error('그림 입력이 너무 큽니다');
    const project = await this.store.requireProject(projectId);
    const bundle = await requireWithin(project.workplanRoot, path.join(project.workplanRoot, workplanId));
    const memo = await readFile(path.join(bundle, `${workplanId}.md`), 'utf8');
    const output = await requireWithin(bundle, path.join(bundle, 'Artifacts', 'plan-diagram'), { allowMissing: true });
    const lock = JSON.parse(await readFile(this.lockPath, 'utf8'));
    let receipt;
    try { receipt = JSON.parse(await readFile(path.join(this.archifyRoot, '.ai-workflow-archify.json'), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return { status: 'unavailable', reason: '고정 버전 Archify를 선택 설치해야 합니다. 다른 작업은 계속할 수 있습니다.' }; throw error; }
    if (receipt.commit !== lock.commit || JSON.stringify(await treeManifest(this.archifyRoot)) !== JSON.stringify(receipt.files)) throw new Error('설치된 Archify 무결성이 변경되었습니다');
    // 원본 meta.output/파일 URL이 Workplan 밖 쓰기나 코드 유출을 유도하지 못하게 한다.
    const text = JSON.stringify(diagram);
    if (/https?:\/\/|file:\/\//i.test(text)) throw new Error('외부 URL 대신 확인한 프로젝트의 상대 코드 위치를 사용해 주세요');
    for (const source of sourceReferences) {
      if (typeof source !== 'string' || path.isAbsolute(source) || source.split(/[\\/]/).includes('..')) throw new Error('원천은 현재 프로젝트의 상대 파일 경로여야 합니다');
      await requireWithin(project.repositoryPath, path.join(project.repositoryPath, source.split('#')[0]));
    }
    // 같은 계획의 attempt=1을 반복 호출해 무한 재생성하지 못하게 한다.
    // 상태·시각 같은 frontmatter 변경은 새 그림 예산으로 간주하지 않는다.
    const body = memo.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '');
    const revision = digest(Buffer.from(body)).slice(0, 16);
    const revisionRoot = await requireWithin(output, path.join(output, revision), { allowMissing: true });
    await mkdir(revisionRoot, { recursive: true, mode: 0o700 });
    const run = await requireWithin(output, path.join(revisionRoot, `attempt-${attempt}`), { allowMissing: true });
    await mkdir(run, { mode: 0o700 });
    const input = path.join(run, 'diagram.json');
    const html = path.join(run, 'diagram.html');
    const candidate = structuredClone(diagram);
    candidate.meta = { ...candidate.meta, output: 'diagram.html', title: `${perspective}: ${candidate.meta?.title || '작업 구조'}` };
    await atomicJSON(input, candidate);
    await atomicJSON(path.join(run, 'sources.json'), { perspective, sourceReferences, evidenceMeaning: '계획 설명용 그림. 코드·시각 적합성 통과 근거가 아님' });
    const entry = await requireWithin(this.archifyRoot, path.join(this.archifyRoot, lock.entrypoint));
    try {
      await this.runner(process.execPath, [entry, 'render', candidate.diagram_type, input, html, '--quality', 'standard'], {
        cwd: run, timeout: 30_000, maxBuffer: 1024 * 1024,
        env: { PATH: process.env.PATH || '', HOME: run, ARCHIFY_UPDATE_CHECK_DISABLED: '1' }, shell: false,
      });
      await requireWithin(run, html);
      return { status: 'rendered', input, html, perspective, productVerified: false, visualReviewed: false };
    } catch (error) {
      return { status: 'failed', input, reason: String(error.message).slice(0, 2000), productVerified: false };
    }
  }
}
