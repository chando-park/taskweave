import { lstat, readlink, readFile, readdir, realpath, mkdir, rename, symlink, writeFile, unlink } from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

const hosts = ['codex', 'claude'];
const inside = (root, file) => file === root || file.startsWith(`${root}${path.sep}`);
const digest = value => createHash('sha256').update(value).digest('hex');
const entryName = host => host === 'codex' ? 'AGENTS.md' : 'CLAUDE.md';
const pointerPath = (home, host) => path.join(home, '.local/share/ai-workflow/active', host, 'taskweave');

async function state(file) {
  let stat;
  try { stat = await lstat(file, { bigint: true }); } catch (error) { if (error.code === 'ENOENT') return { type: 'missing' }; throw error; }
  const identity = { dev: String(stat.dev), ino: String(stat.ino), mtime: String(stat.mtimeNs) };
  if (stat.isSymbolicLink()) return { type: 'symlink', target: await readlink(file), ...identity };
  if (stat.isFile()) return { type: 'file', hash: digest(await readFile(file)), ...identity };
  return { type: 'other', ...identity };
}

async function safeParents(root, file) {
  if (!inside(root, file) || file === root) throw new Error(`경계 밖 경로: ${file}`);
  let current = root;
  for (const name of path.relative(root, path.dirname(file)).split(path.sep).filter(Boolean)) {
    current = path.join(current, name);
    const value = await state(current);
    if (value.type === 'symlink' || value.type === 'file') throw new Error(`상위 symlink/파일 보존: ${current}`);
    if (value.type === 'other' && !(await lstat(current)).isDirectory()) throw new Error(`상위 경로가 디렉터리가 아님: ${current}`);
  }
}

async function resource(root, relative, directory = false) {
  const file = path.join(root, relative);
  const resolved = await realpath(file);
  if (!inside(root, resolved)) throw new Error(`설치본 밖 자원: ${relative}`);
  const stat = await lstat(resolved);
  if (directory ? !stat.isDirectory() : !stat.isFile()) throw new Error(`설치본 자원 종류 오류: ${relative}`);
  return file;
}

async function verifyPlugin(input, host) {
  const root = await realpath(path.resolve(input));
  const manifest = JSON.parse(await readFile(await resource(root, host === 'codex' ? 'plugin.json' : '.claude-plugin/plugin.json'), 'utf8'));
  if (manifest.name !== 'taskweave' || typeof manifest.version !== 'string' || !manifest.version) throw new Error(`Taskweave 설치본 아님: ${host}`);
  for (const relative of [entryName(host), 'references/task-workflow.md', 'mcp/src/server.mjs', 'mcp/src/viewer/main.mjs', 'mcp/src/viewer/public/index.html']) await resource(root, relative);
  for (const relative of ['skills', 'core/scripts', 'core/agents']) await resource(root, relative, true);
  return { root, version: manifest.version };
}

function managedEntry(home, host) {
  const target = path.join(pointerPath(home, host), entryName(host));
  return `<!-- taskweave-managed-entry-v1 -->\n# Taskweave\n\n매 작업 시작 전에 [활성 Taskweave 지침](${target})을 반드시 읽고 적용한다. 세부 규칙은 이 파일에 복사하지 않고 설치된 플러그인의 지침을 따른다.\n`;
}

async function children(directory) {
  try { return (await readdir(directory)).sort(); } catch (error) { if (error.code === 'ENOENT') return []; throw error; }
}

/** 읽기 전용 사전 조사. 반환된 inspection을 apply에 넘기면 조사 이후 변경을 거부한다. */
export async function inspectLegacyLinks({ home, sourceRoot, pluginRoots }) {
  home = await realpath(path.resolve(home));
  const sourceAlias = path.resolve(sourceRoot);
  sourceRoot = await realpath(path.resolve(sourceRoot));
  const plugins = {};
  for (const host of hosts) plugins[host] = await verifyPlugin(pluginRoots[host], host);
  const operations = [];
  const preserved = [];
  const add = async (file, replacement, reason) => {
    await safeParents(home, file);
    operations.push({ path: file, before: await state(file), replacement, reason });
  };
  const runtimes = [...new Set([sourceAlias, sourceRoot])].flatMap(root => [path.join(root, '20_AI/Codex/Runtime'), path.join(root, '20_AI/Claude_Code/Runtime')]);
  for (const host of hosts) {
    const base = path.join(home, `.${host}`);
    const pointer = pointerPath(home, host);
    await safeParents(home, pointer);
    const pointerState = await state(pointer);
    if (pointerState.type === 'missing') await add(pointer, { type: 'symlink', target: plugins[host].root }, 'active-pointer');
    else if (pointerState.type === 'symlink') {
      const current = path.resolve(path.dirname(pointer), pointerState.target);
      if (current !== plugins[host].root) {
        await verifyPlugin(current, host);
        await add(pointer, { type: 'symlink', target: plugins[host].root }, 'active-pointer-update');
      }
    } else throw new Error(`활성 pointer 사용자 파일 보존: ${pointer}`);
    for (const category of ['skills', 'bin', 'agents']) {
      const directory = path.join(base, category);
      await safeParents(home, path.join(directory, '_probe'));
      for (const name of await children(directory)) {
        const file = path.join(directory, name);
        const original = await state(file);
        const sourceCategory = category === 'bin' ? 'scripts' : category;
        const target = original.type === 'symlink' ? path.resolve(directory, original.target) : null;
        const targetName = target && path.basename(target);
        const owned = runtimes.some(root => category === 'bin'
          ? target && path.dirname(target) === path.join(root, sourceCategory)
          : target === path.join(root, sourceCategory, name));
        if (!owned) { preserved.push({ path: file, reason: 'unowned' }); continue; }
        const resourceName = category === 'bin' ? targetName : name;
        const relative = category === 'skills' ? `skills/${name}/SKILL.md` : `core/${sourceCategory}/${resourceName}`;
        try { await resource(plugins[host].root, relative); } catch (error) { preserved.push({ path: file, reason: 'replacement-unavailable' }); continue; }
        const replacement = category === 'skills' ? { type: 'missing' } : { type: 'symlink', target: path.join(pointer, 'core', sourceCategory, resourceName) };
        await add(file, replacement, `legacy-${category}`);
      }
    }
    for (const name of ['references', entryName(host)]) {
      const file = path.join(base, name);
      await safeParents(home, file);
      const original = await state(file);
      const target = original.type === 'symlink' ? path.resolve(base, original.target) : null;
      const owned = runtimes.some(root => target === path.join(root, name));
      if (!owned) { preserved.push({ path: file, reason: 'unowned-or-already-migrated' }); continue; }
      if (name === 'references') {
        await resource(plugins[host].root, 'references', true);
        await add(file, { type: 'symlink', target: path.join(pointer, 'references') }, 'legacy-references');
      } else await add(file, { type: 'file', content: managedEntry(home, host) }, 'legacy-entry');
    }
  }
  return { schema: 'taskweave-migration-inspection-v1', home, sourceRoot, plugins, operations, preserved };
}

const equal = (left, right) => JSON.stringify(left) === JSON.stringify(right);
async function saveManifest(file, manifest) { await writeFile(file, `${JSON.stringify(manifest, null, 2)}\n`, { mode: 0o600 }); }

/** dryRun이 기본이다. 실제 전환은 confirmed=true와 변경되지 않은 사전 조사 결과를 요구한다. */
export async function migrateLegacyLinks(options) {
  const inspection = options.inspection ?? await inspectLegacyLinks(options);
  if (inspection.schema !== 'taskweave-migration-inspection-v1') throw new Error('사전 조사 형식 오류');
  const fresh = await inspectLegacyLinks(options);
  if (!equal(inspection, fresh)) throw new Error('사전 조사 이후 변경됨; 다시 조사하세요.');
  if (options.dryRun !== false) return { dryRun: true, inspection, changes: inspection.operations.length };
  if (options.confirmed !== true) throw new Error('명시 승인 필요: confirmed=true');
  if (!inspection.operations.length) return { dryRun: false, changes: 0, manifestPath: null };
  const backupRoot = path.resolve(options.backupRoot ?? path.join(inspection.home, '.local/share/ai-workflow/backups'));
  if (inside(inspection.sourceRoot, backupRoot) || !inside(inspection.home, backupRoot)) throw new Error('백업은 checkout 밖 로컬 홈 데이터에만 저장합니다.');
  await safeParents(inspection.home, path.join(backupRoot, '_probe'));
  await mkdir(backupRoot, { recursive: true, mode: 0o700 });
  const directory = path.join(backupRoot, `migration-${Date.now()}-${randomUUID()}`);
  await mkdir(directory, { mode: 0o700 });
  const manifestPath = path.join(directory, 'manifest.json');
  const manifest = { schema: 'taskweave-migration-backup-v1', home: inspection.home, sourceRoot: inspection.sourceRoot, entries: [] };
  await writeFile(manifestPath, JSON.stringify(manifest), { mode: 0o600, flag: 'wx' });
  for (const operation of inspection.operations) {
    await safeParents(inspection.home, operation.path);
    if (!equal(await state(operation.path), operation.before)) throw new Error(`적용 전 변경됨: ${operation.path}`);
  }
  for (const [index, operation] of inspection.operations.entries()) {
    await safeParents(inspection.home, operation.path);
    if (!equal(await state(operation.path), operation.before)) throw new Error(`적용 직전 변경됨: ${operation.path}; 복구: ${manifestPath}`);
    const entry = { ...operation, backup: path.join(directory, `original-${index}`), status: 'pending' };
    manifest.entries.push(entry);
    await saveManifest(manifestPath, manifest);
    await mkdir(path.dirname(operation.path), { recursive: true, mode: 0o700 });
    // 원본 링크 자체만 이동한다. 링크 대상인 원본 규칙·기록·인증은 읽거나 복사하지 않는다.
    if (operation.before.type !== 'missing') await rename(operation.path, entry.backup);
    if (operation.replacement.type === 'symlink') await symlink(operation.replacement.target, operation.path);
    else if (operation.replacement.type === 'file') await writeFile(operation.path, operation.replacement.content, { mode: 0o600, flag: 'wx' });
    entry.after = await state(operation.path);
    entry.status = 'applied';
    await saveManifest(manifestPath, manifest);
  }
  return { dryRun: false, changes: manifest.entries.length, manifestPath };
}

/** 현재 replacement가 그대로인 경우에만 원본 링크를 되돌린다. 사용자 변경은 덮어쓰지 않는다. */
export async function restoreMigration(manifestPath, { confirmed = false } = {}) {
  if (!confirmed) throw new Error('복구 명시 승인 필요');
  manifestPath = path.resolve(manifestPath);
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  if (manifest.schema !== 'taskweave-migration-backup-v1' || !Array.isArray(manifest.entries)) throw new Error('복구 manifest 오류');
  const home = await realpath(manifest.home);
  await safeParents(home, manifestPath);
  if ((await state(manifestPath)).type !== 'file') throw new Error('복구 manifest는 일반 파일이어야 합니다.');
  const directory = path.dirname(manifestPath);
  for (const entry of manifest.entries) {
    if (entry.status === 'restored') continue;
    await safeParents(home, entry.path);
    if (path.dirname(entry.backup) !== directory) throw new Error('백업 경계 오류');
    const current = await state(entry.path);
    const backup = await state(entry.backup);
    // 이동 전 또는 이동 직후 중단은 식별자가 남은 원본으로만 복구한다.
    // replacement 생성 뒤 기록 전 중단은 소유권을 증명할 수 없으므로 거부한다.
    if (entry.status === 'pending') {
      if (backup.type === 'missing' && equal(current, entry.before)) { entry.status = 'restored'; continue; }
      if (current.type === 'missing' && entry.before.type !== 'missing' && equal(backup, entry.before)) {
        entry.after = current;
        entry.status = 'applied';
      }
    }
    if (entry.status !== 'applied' || !equal(current, entry.after)) throw new Error(`복구 충돌: ${entry.path}`);
    if (entry.before.type !== 'missing' && !equal(backup, entry.before)) throw new Error(`원본 백업 변경됨: ${entry.path}`);
  }
  let restored = 0;
  for (const entry of [...manifest.entries].reverse()) {
    if (entry.status === 'restored') continue;
    await safeParents(home, entry.path);
    if (!equal(await state(entry.path), entry.after)) throw new Error(`복구 직전 변경됨: ${entry.path}`);
    if (entry.after.type !== 'missing') await unlink(entry.path);
    if (entry.before.type !== 'missing') await rename(entry.backup, entry.path);
    entry.status = 'restored';
    await saveManifest(manifestPath, manifest);
    restored += 1;
  }
  return { restored, manifestPath };
}
