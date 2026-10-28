import { createReadStream, constants } from 'node:fs';
import { mkdir, mkdtemp, readdir, lstat, readlink, copyFile, symlink, rename, readFile, utimes } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { assertId, canonicalPath, requireWithin, atomicJSON, withLock, isWithin } from './settings.mjs';

async function present(file) {
  try { return await lstat(file); } catch (error) { if (error.code !== 'ENOENT') throw error; return null; }
}

// 원문을 해석하거나 수정하지 않고 파일 내용과 symlink의 목적지만 비교한다.
async function inventory(root) {
  const result = {};
  async function walk(relative = '') {
    for (const entry of await readdir(path.join(root, relative), { withFileTypes: true })) {
      const key = path.join(relative, entry.name), filename = path.join(root, key);
      if (entry.isSymbolicLink()) result[key] = { type: 'link', target: await readlink(filename) };
      else if (entry.isDirectory()) { result[key] = { type: 'directory' }; await walk(key); }
      else if (entry.isFile()) {
        const hash = createHash('sha256');
        for await (const bytes of createReadStream(filename)) hash.update(bytes);
        result[key] = { type: 'file', hash: hash.digest('hex') };
      } else throw new Error(`일반 기록 파일이 아닙니다: ${filename}`);
    }
  }
  await walk();
  return Object.fromEntries(Object.entries(result).sort(([a], [b]) => a.localeCompare(b)));
}
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// 명시적으로 요청한 기존 Workplan만 통합한다. 충돌·작업 중 변경은 덮어쓰지 않고 백업을 남긴다.
export async function consolidateWorkplans({ store, roots, confirmed, confirmationSource }) {
  if (confirmed !== true || !confirmationSource?.trim()) throw new Error('기록 위치 변경에 대한 사용자 요청이 필요합니다');
  if (!Array.isArray(roots) || !roots.length) throw new Error('이전할 Workplan 폴더를 지정해 주세요');
  return withLock(`${store.configPath}.lock`, async () => {
    const before = await store.load(), catalog = await store.projectCatalog();
    const managed = await requireWithin(store.dataRoot, path.join(store.dataRoot, 'workspaces/personal/projects'), { allowMissing: true });
    const groups = new Map(), sourcePaths = new Set();
    for (const item of roots) {
      assertId(item.projectId);
      const source = path.resolve(item.source), target = path.join(managed, item.projectId, 'Workplans');
      const info = await present(source);
      if (info?.isSymbolicLink() && await canonicalPath(source) === await canonicalPath(target, { allowMissing: true })) continue;
      if (!info?.isDirectory() || info.isSymbolicLink()) throw new Error(`원본 폴더를 확인해 주세요: ${source}`);
      await requireWithin(managed, target, { allowMissing: true });
      if (source === target) continue;
      if (isWithin(source, target) || isWithin(target, source) || sourcePaths.has(source)) throw new Error('중첩되거나 중복된 이전 폴더입니다');
      for (const previous of sourcePaths) if (isWithin(previous, source) || isWithin(source, previous)) throw new Error('중첩된 원본 폴더입니다');
      sourcePaths.add(source);
      const group = groups.get(item.projectId) ?? { projectId: item.projectId, target, sources: [] };
      group.sources.push({ source, snapshot: await inventory(source) });
      groups.set(item.projectId, group);
    }
    const backups = await requireWithin(store.dataRoot, path.join(store.dataRoot, 'backups'), { allowMissing: true });
    await mkdir(backups, { recursive: true, mode: 0o700 });
    const backup = await mkdtemp(path.join(backups, 'workplan-storage-'));
    await atomicJSON(path.join(backup, 'settings.json'), before);
    const viewerFile = path.join(store.dataRoot, 'viewer/roots.json');
    let viewerBefore;
    try { viewerBefore = JSON.parse(await readFile(viewerFile, 'utf8')); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (viewerBefore) await atomicJSON(path.join(backup, 'viewer-roots.json'), viewerBefore);
    const manifest = { schema: 'workplan-storage-migration-v1', confirmationSource, createdAt: new Date().toISOString(), status: 'preparing', projects: [] };
    const saveManifest = () => atomicJSON(path.join(backup, 'manifest.json'), manifest);
    await saveManifest();
    for (const group of groups.values()) {
      const info = await present(group.target);
      if (info && (!info.isDirectory() || info.isSymbolicLink())) throw new Error('기본 기록 위치가 일반 폴더가 아닙니다');
      const existing = info ? await inventory(group.target) : {};
      const inputs = [...(info ? [{ source: group.target, snapshot: existing }] : []), ...group.sources];
      const staged = path.join(backup, 'staging', group.projectId), expected = {};
      await mkdir(staged, { recursive: true, mode: 0o700 });
      for (const input of inputs) for (const [relative, item] of Object.entries(input.snapshot)) {
        if (expected[relative]) {
          if (!equal(expected[relative], item)) throw new Error(`같은 이름의 내용이 다릅니다. 원문을 보존했습니다: ${group.projectId}/${relative}`);
          continue;
        }
        expected[relative] = item;
        const destination = path.join(staged, relative);
        await mkdir(path.dirname(destination), { recursive: true, mode: 0o700 });
        if (item.type === 'directory') await mkdir(destination, { recursive: true, mode: 0o700 });
        else if (item.type === 'link') await symlink(item.target, destination);
        else {
          const source = path.join(input.source, relative);
          await copyFile(source, destination, constants.COPYFILE_EXCL);
          const dates = await lstat(source);
          await utimes(destination, dates.atime, dates.mtime);
        }
      }
      if (!equal(await inventory(staged), Object.fromEntries(Object.entries(expected).sort(([a], [b]) => a.localeCompare(b))))) throw new Error('복사한 기록의 내용 확인 실패');
      group.staged = staged; group.existing = existing; group.existed = Boolean(info);
      manifest.projects.push({ projectId: group.projectId, target: group.target, sources: group.sources.map(item => item.source), files: Object.values(expected).filter(item => item.type === 'file').length, status: 'copied' });
      await saveManifest();
    }
    // 모든 충돌 검사가 끝난 뒤에만 기존 폴더 이름을 바꾼다. 원본은 백업에 남고 예전 경로는 연결이 된다.
    for (const group of groups.values()) {
      for (const source of group.sources) if (!equal(await inventory(source.source), source.snapshot)) throw new Error('이전 준비 중 원본이 바뀌었습니다. 원문을 보존하고 중단합니다');
      if (group.existed && !equal(await inventory(group.target), group.existing)) throw new Error('이전 준비 중 기본 기록이 바뀌었습니다');
      await mkdir(path.dirname(group.target), { recursive: true, mode: 0o700 });
      if (group.existed) await rename(group.target, path.join(backup, `${group.projectId}-previous-target`));
      await rename(group.staged, group.target);
      for (let index = 0; index < group.sources.length; index++) {
        const source = group.sources[index];
        await rename(source.source, path.join(backup, `${group.projectId}-source-${index}`));
        await symlink(group.target, source.source);
      }
      manifest.projects.find(item => item.projectId === group.projectId).status = 'linked';
      await saveManifest();
    }
    const next = await store.load();
    if (!equal(next, before)) throw new Error('다른 요청이 설정을 바꿨습니다. 설정 백업과 이전 기록을 보존합니다');
    next.workplanStorage = 'managed-default-v1';
    next.projectAliases = { ...next.projectAliases, ...catalog.aliases };
    next.workspaces = { ...catalog.workspaces, ...next.workspaces };
    for (const [projectId, project] of Object.entries(catalog.projects)) next.projects[projectId] = { ...project, workplanRoot: path.join(managed, projectId, 'Workplans') };
    for (const [alias, canonical] of Object.entries(next.projectAliases)) if (next.projects[canonical]) next.projects[alias] = { ...next.projects[canonical], aliasOf: canonical };
    await atomicJSON(store.configPath, next);
    await atomicJSON(viewerFile, { roots: [managed] });
    manifest.status = 'complete';
    await saveManifest();
    return { root: managed, backup, projects: manifest.projects, preservedOriginals: true };
  });
}
