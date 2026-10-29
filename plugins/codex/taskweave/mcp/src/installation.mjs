import { mkdir, readFile, writeFile, rename, lstat, realpath, readdir, rmdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { IntegrationService, PROVIDERS } from './integrations.mjs';
import { SettingsStore, canonicalPath } from './settings.mjs';
import { inspectOwnedLegacyCleanup, cleanupOwnedLegacyLinks } from './legacy-migration.mjs';
import { stopOwnedViewer } from './viewer/lifecycle.mjs';
import { PRODUCT_NAME, PLUGIN_ID, LEGACY_PLUGIN_ID } from './product.mjs';

const execute = promisify(execFile);
const CLIENTS = ['codex', 'claude'];
const PLUGIN = PLUGIN_ID;
const selector = (pluginName = PLUGIN) => `${pluginName}@my-ai-toolbox`;
const installedName = installed => installed?.pluginName ?? 'ai-workflow';
const START = '<!-- ai-workflow:managed:start -->';
const END = '<!-- ai-workflow:managed:end -->';
const digest = value => createHash('sha256').update(value).digest('hex');
const catalogRelative = host => host === 'codex' ? '.agents/plugins/marketplace.json' : '.claude-plugin/marketplace.json';
const exists = async file => { try { await lstat(file); return true; } catch (error) { if (error.code === 'ENOENT') return false; throw error; } };
const readJSON = async (file, fallback) => { try { return JSON.parse(await readFile(file, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return fallback; throw error; } };
const selected = client => { if (client === 'both') return CLIENTS; if (CLIENTS.includes(client)) return [client]; throw new Error('client는 both|codex|claude 중 선택하세요.'); };

export async function provisionSerena({ client = 'both', dryRun = true, confirmed = false, check = false, runner = execute, installerPath = fileURLToPath(new URL('../../Codex/Runtime/scripts/install-serena-mcp.rb', import.meta.url)) } = {}) {
  selected(client);
  if (!dryRun && !confirmed) throw new Error('Serena 설치 명시 확인 필요');
  let result;
  try { result = await runner('ruby', [installerPath, '--client', client, check ? '--check' : dryRun ? '--dry-run' : '--apply']); }
  catch { throw new Error(`Serena ${client}: 설치/등록 명령 실패. 호스트에서 권한·설정을 확인하세요. 인증값이 포함될 수 있는 원본 출력은 반환하지 않습니다.`); }
  try { return JSON.parse(result.stdout); } catch { throw new Error('Serena 설치 결과 JSON 확인 실패'); }
}

export function integrationSelection(value = '') {
  const providers = typeof value === 'string' ? value.split(',').map(item => item.trim()).filter(Boolean) : value;
  if (!Array.isArray(providers) || providers.some(provider => !PROVIDERS.includes(provider))) throw new Error('연동은 serena,figma,jira 중 선택하세요.');
  return [...new Set(providers)];
}

export async function prepareIntegrations({ store, client = 'both', providers = [], hostObservations = [], manager, dryRun = true, confirmed = false, check = false }) {
  const service = new IntegrationService({ store });
  const chosen = integrationSelection(providers);
  const observations = hostObservations.map(item => ({ ...item }));
  if (chosen.includes('serena') && manager) {
    // 기존 고정 버전 설치기의 지원 형식을 재사용하며 홈 탐색·추정 설정 변환을 추가하지 않는다.
    const inspected = await provisionSerena({ client, runner: manager.runner, check: true });
    for (const host of selected(client)) {
      const registration = inspected.clients?.[host]?.registration;
      const supplied = observations.find(item => item.client === host && item.provider === 'serena');
      if (supplied) {
        // 오래된 부족 관찰이 현재 사용자 등록의 변환을 허가하지 않는다.
        if (registration && registration !== 'absent' && supplied.state === 'unavailable') Object.assign(supplied, { state: 'registered', connectionRef: supplied.connectionRef ?? 'host:serena' });
        continue;
      }
      if (registration) observations.push({ client: host, provider: 'serena', state: registration === 'absent' ? 'unavailable' : 'registered', ...(registration !== 'absent' ? { connectionRef: 'host:serena' } : {}) });
    }
  }
  const plan = await service.plan({ clients: selected(client), providers: chosen, hostObservations: observations });
  if (dryRun || check) return plan;
  if (!confirmed) throw new Error('연동 설정은 변경 미리보기 후 명시 확인이 필요합니다.');
  const applied = [];
  for (const item of plan.changes) {
    if (!manager) throw new Error('확인된 설치 실행기가 없습니다.');
    const result = await provisionSerena({ client: item.client, dryRun: false, confirmed: true, runner: manager.runner });
    // 설치 소유권은 사용자 기존 연결·OAuth 인증과 별도로 기록한다.
    await manager.withLock(async () => {
      const state = await manager.state();
      state.integrations ??= {};
      state.integrations[item.client] ??= {};
      state.integrations[item.client].serena = { owner: 'ai-workflow', registrationRef: 'host:serena', installedAt: new Date().toISOString(), removal: 'preserve-unless-separately-confirmed' };
      await manager.save(state);
    });
    applied.push({ client: item.client, provider: 'serena', registered: true, readVerified: false, requiresFreshSession: result.requires_fresh_session !== false });
  }
  return { ...plan, applied, requiresFreshSession: applied.length > 0, next: '인증은 각 호스트 공식 화면에서, 읽기 확인은 그 호스트 도구에서 수행하세요. 토큰을 입력하지 마세요.' };
}

export function replaceManagedBlock(text, content) {
  const starts = text.split(START).length - 1;
  const ends = text.split(END).length - 1;
  if (starts !== ends || starts > 1) throw new Error('관리 블록 충돌: 사용자 확인이 필요합니다.');
  const block = content === null ? '' : `${START}\n${content.trim()}\n${END}`;
  if (!starts) return block ? `${text}${text && !text.endsWith('\n') ? '\n' : ''}${block}\n` : text;
  const begin = text.indexOf(START);
  const finish = text.indexOf(END) + END.length;
  if (finish < begin) throw new Error('잘못된 관리 블록 순서');
  return `${text.slice(0, begin)}${block}${text.slice(finish)}`;
}

async function inspectHostPlugins(host, runner) {
  try {
    const result = JSON.parse((await runner(host, ['plugin', 'list', '--json'])).stdout);
    const entries = Array.isArray(result) ? result : result.installed;
    if (!Array.isArray(entries)) throw new Error('unknown-list-shape');
    const plugins = [];
    let unknown = false;
    for (const entry of entries) {
      const id = typeof entry === 'string' ? entry : [entry.pluginId, entry.id, entry.name].find(value => typeof value === 'string' && value.includes('@')) ?? entry.name;
      if (typeof id !== 'string') { unknown = true; continue; }
      const [name, embeddedMarketplace] = id.split('@');
      if (![PLUGIN, LEGACY_PLUGIN_ID, 'ai-workflow'].includes(name)) continue;
      const marketplace = embeddedMarketplace ?? entry.marketplaceName ?? (typeof entry.marketplace === 'string' ? entry.marketplace : entry.marketplace?.name);
      if (!marketplace || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name) || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(marketplace) || id.split('@').length > 2 || typeof entry === 'object' && entry.scope && entry.scope !== 'user') { unknown = true; continue; }
      const root = typeof entry === 'object' ? entry.installPath ?? entry.installedPath ?? entry.pluginRoot ?? entry.path : null;
      plugins.push({ selector: `${name}@${marketplace}`, pluginName: name, ...(typeof root === 'string' && path.isAbsolute(root) ? { root: path.resolve(root) } : {}) });
    }
    if (new Set(plugins.map(plugin => plugin.selector)).size !== plugins.length) unknown = true;
    return { status: unknown ? 'unknown' : 'known', plugins };
  } catch { return { status: 'unknown', plugins: [] }; }
}

async function safeInstructionPath(root, file) {
  if (!path.resolve(file).startsWith(`${path.resolve(root)}${path.sep}`)) throw new Error('instruction-outside-boundary');
  if (await exists(root) && (await lstat(root)).isSymbolicLink()) throw new Error('instruction-root-symlink');
  let current = path.resolve(root);
  for (const part of path.relative(current, file).split(path.sep)) {
    current = path.join(current, part);
    try { if ((await lstat(current)).isSymbolicLink()) throw new Error('instruction-symlink'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}

export async function inspectOwnedUninstall({ home, dataDir, settingsPath, client, state, runner, selectors = {} }) {
  const hosts = selected(client);
  const observations = {};
  for (const host of hosts) observations[host] = await inspectHostPlugins(host, runner);
  const targets = [];
  const ambiguities = [];
  const pluginRoots = {};
  for (const host of hosts) {
    const observation = observations[host];
    const candidates = observation.plugins.filter(plugin => [PLUGIN, LEGACY_PLUGIN_ID].includes(plugin.pluginName) || plugin.pluginName === installedName(state.clients[host]) && state.clients[host]);
    const requested = selectors[host];
    if (observation.status !== 'known' || requested && !candidates.some(plugin => plugin.selector === requested) || !requested && candidates.length > 1) {
      ambiguities.push({ client: host, reason: observation.status === 'unknown' ? 'host-list-unverifiable' : 'select-exact-plugin', choices: candidates.map(plugin => plugin.selector) });
      continue;
    }
    const target = requested ? candidates.find(plugin => plugin.selector === requested) : candidates[0];
    targets.push({ client: host, selector: target?.selector ?? null, absent: !target, before: state.clients[host] ?? null });
    pluginRoots[host] = observation.plugins.flatMap(plugin => plugin.root ? [plugin.root] : []);
    const installed = state.clients[host];
    if (installed?.distributionRoot) pluginRoots[host].push(path.resolve(installed.distributionRoot, 'plugins', host, installedName(installed)));
  }
  let projects = [];
  try {
    const settings = await readJSON(settingsPath, null);
    projects = Object.values(settings?.projects ?? {}).map(project => project.repositoryPath).filter(value => typeof value === 'string' && path.isAbsolute(value));
  } catch { /* 미확인 설정은 지침 정리 대상을 늘리지 않는다. */ }
  const legacy = await inspectOwnedLegacyCleanup({ home, dataDir, clients: hosts, projects, pluginRoots });
  const blocks = [];
  const preserved = [];
  for (const host of hosts) {
    const file = path.join(home, host === 'codex' ? '.codex/AGENTS.md' : '.claude/CLAUDE.md');
    const owned = state.managedBlocks[file];
    if (!owned) continue;
    try {
      await safeInstructionPath(home, file);
      const before = await readFile(file, 'utf8');
      const starts = before.split(START).length - 1;
      const ends = before.split(END).length - 1;
      const block = before.slice(before.indexOf(START), before.indexOf(END) + END.length);
      if (starts !== 1 || ends !== 1 || owned.hash !== digest(block)) throw new Error('unowned-or-modified');
      blocks.push({ client: host, path: file, before, after: replaceManagedBlock(before, null), owned });
    } catch { preserved.push({ path: file, reason: 'managed-block-unverifiable' }); }
  }
  const commands = targets.filter(target => !target.absent).map(target => [target.client, 'plugin', target.client === 'codex' ? 'remove' : 'uninstall', target.selector, ...(target.client === 'claude' ? ['--scope', 'user'] : [])]);
  let viewerState = null;
  let viewerKnown = true;
  try {
    const file = path.join(dataDir, 'viewer/service.json');
    await safeInstructionPath(dataDir, file);
    viewerState = await readJSON(file, null);
  } catch { viewerKnown = false; }
  return { client, targets, commands, ambiguities, observations, legacy, blocks, preserved, home, dataDir, viewerState, viewerKnown, requiresFreshSession: true };
}

export async function removeSelectedHostPlugins(plan, runner) {
  const removed = [];
  for (const target of plan.targets) {
    if (target.absent) { removed.push({ ...target, status: 'absent', remaining: plan.observations[target.client] }); continue; }
    try { await runner(target.client, ['plugin', target.client === 'codex' ? 'remove' : 'uninstall', target.selector, ...(target.client === 'claude' ? ['--scope', 'user'] : [])]); }
    catch { removed.push({ ...target, status: 'failed', reason: 'host-command-failed' }); continue; }
    const remaining = await inspectHostPlugins(target.client, runner);
    const verified = remaining.status === 'known' && !remaining.plugins.some(plugin => plugin.selector === target.selector);
    removed.push({ ...target, status: verified ? 'removed' : 'failed', ...(!verified ? { reason: 'host-removal-unverified' } : {}), remaining });
  }
  return removed;
}

export async function cleanupOwnedInstructions({ plan, removed }) {
  const clients = removed.filter(item => ['removed', 'absent'].includes(item.status) && item.remaining.status === 'known' && item.remaining.plugins.length === 0).map(item => item.client);
  const result = await cleanupOwnedLegacyLinks({ inspection: plan.legacy, clients, dataDir: plan.dataDir });
  result.preserved.push(...plan.preserved);
  for (const block of plan.blocks) {
    if (!clients.includes(block.client)) { result.preserved.push({ path: block.path, reason: 'host-still-installed-or-unverified' }); continue; }
    try {
      await safeInstructionPath(plan.home, block.path);
      if (await readFile(block.path, 'utf8') !== block.before) throw new Error('changed-after-inspection');
      const backup = path.join(plan.dataDir, 'backups', `uninstall-${randomUUID()}`);
      if (path.resolve(plan.dataDir).startsWith(`${path.resolve(plan.home)}${path.sep}`)) await safeInstructionPath(plan.home, backup);
      await safeInstructionPath(plan.dataDir, backup);
      await mkdir(path.dirname(backup), { recursive: true, mode: 0o700 });
      await writeFile(backup, block.before, { mode: 0o600, flag: 'wx' });
      await writeFile(block.path, block.after);
      result.cleaned.push({ path: block.path, backup, managedBlock: true, owned: block.owned });
    } catch { result.preserved.push({ path: block.path, reason: 'changed-or-cleanup-failed' }); }
  }
  // 관리 블록을 지운 뒤 남은 자기 소유 짧은 입구도 정리한다. 사용자 문구는 일치하지 않아 보존된다.
  if (clients.length) {
    const refreshed = await inspectOwnedLegacyCleanup({ home: plan.home, dataDir: plan.dataDir, clients });
    const tail = await cleanupOwnedLegacyLinks({ inspection: refreshed, clients, dataDir: plan.dataDir });
    result.cleaned.push(...tail.cleaned);
    result.preserved.push(...tail.preserved);
  }
  for (const operation of plan.legacy.operations.filter(operation => !clients.includes(operation.host))) result.preserved.push({ path: operation.path, reason: 'host-still-installed-or-unverified' });
  return result;
}

export async function stopViewerAfterLastRemoval({ plan, removed, runner, store }) {
  if (removed.some(item => item.status === 'failed')) return { status: 'preserved', reason: 'partial-or-unverified-removal' };
  for (const host of CLIENTS) {
    const remaining = await inspectHostPlugins(host, runner);
    if (remaining.status !== 'known') return { status: 'preserved', reason: `${host}-installations-unknown` };
    if (remaining.plugins.length) return { status: 'preserved', reason: 'other-installations-remain' };
  }
  if (!plan.viewerKnown) return { status: 'preserved', reason: 'pre-removal-viewer-state-unknown' };
  return stopOwnedViewer({ store, expectedState: plan.viewerState });
}

export function mergeUninstallResult(state, removed, instructions = { cleaned: [] }) {
  for (const item of removed) {
    if (!['removed', 'absent'].includes(item.status) || JSON.stringify(state.clients[item.client] ?? null) !== JSON.stringify(item.before)) continue;
    const recordedSelector = item.before?.selector ?? (item.before ? selector(installedName(item.before)) : null);
    if (item.selector && item.selector !== recordedSelector) continue;
    delete state.clients[item.client];
  }
  for (const item of instructions.cleaned.filter(item => item.managedBlock)) {
    if (JSON.stringify(state.managedBlocks[item.path]) === JSON.stringify(item.owned)) delete state.managedBlocks[item.path];
  }
  return state;
}

export class InstallationManager {
  constructor({ home = os.homedir(), dataDir, settingsPath, runner } = {}) {
    this.home = path.resolve(home);
    this.dataDir = path.resolve(dataDir ?? path.join(this.home, '.local/share/ai-workflow'));
    this.settingsPath = settingsPath ?? path.join(this.home, '.config/ai-workflow/settings.json');
    this.stateFile = path.join(this.dataDir, 'installation.json');
    this.runner = runner ?? (async (command, args) => {
      const env = { ...process.env, HOME: this.home, CLAUDE_CONFIG_DIR: path.join(this.home, '.claude'), XDG_CONFIG_HOME: path.join(this.home, '.config'), XDG_DATA_HOME: path.join(this.home, '.local/share'), XDG_CACHE_HOME: path.join(this.home, '.cache') };
      // Codex rejects an explicit nonexistent CODEX_HOME, even for --help. Without
      // the override it can inspect a fresh home without creating state.
      delete env.CODEX_HOME;
      if (await exists(path.join(this.home, '.codex'))) env.CODEX_HOME = path.join(this.home, '.codex');
      return execute(command, args, { env, timeout: 60_000, maxBuffer: 4 * 1024 * 1024 });
    });
  }

  async state() {
    const state = await readJSON(this.stateFile, { schemaVersion: 1, owner: 'ai-workflow', clients: {}, managedBlocks: {}, ownedRecords: [] });
    if (state.owner !== 'ai-workflow' || state.schemaVersion !== 1) throw new Error('지원하지 않는 설치 소유 기록');
    const records = [...(state.ownedRecords ?? [])];
    const registry = path.join(this.dataDir, 'owned-records');
    if (await exists(registry)) {
      if ((await lstat(registry)).isSymbolicLink()) throw new Error('기록 소유 registry symlink 보존');
      for (const entry of await readdir(registry, { withFileTypes: true })) {
        if (!entry.isFile() || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*\.json$/.test(entry.name)) continue;
        try { records.push(await readJSON(path.join(registry, entry.name))); } catch { /* Invalid ownership cannot authorize removal. */ }
      }
    }
    const verified = new Map();
    for (const record of records) {
      try { await this.verifyOwnedRecord(record); verified.set(record.id, record); } catch { /* Existing/external/unverifiable directories are never claimed. */ }
    }
    state.ownedRecords = [...verified.values()];
    return state;
  }

  async verifyOwnedRecord(record) {
    if (!record || record.schemaVersion !== 1 || record.owner !== 'ai-workflow' || record.external !== false || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$/.test(record.id)) throw new Error('소유 marker 형식 오류');
    const root = await realpath(this.dataDir);
    const target = await realpath(record.path);
    if (!target.startsWith(`${root}${path.sep}workspaces${path.sep}`) || (await lstat(record.path)).isSymbolicLink()) throw new Error('관리 기록 경계 밖 경로 보존');
    const markerFile = path.join(target, '.ai-workflow-owned.json');
    if ((await lstat(markerFile)).isSymbolicLink()) throw new Error('소유 marker symlink 금지');
    const marker = await readJSON(markerFile);
    if (marker.schemaVersion !== 1 || marker.owner !== 'ai-workflow' || marker.external !== false || marker.id !== record.id || await realpath(marker.path) !== target) throw new Error('소유 marker 불일치');
    return target;
  }

  async save(state) {
    await mkdir(this.dataDir, { recursive: true, mode: 0o700 });
    if ((await lstat(this.dataDir)).isSymbolicLink()) throw new Error('관리 데이터 symlink 금지');
    const temporary = `${this.stateFile}.${randomUUID()}.tmp`;
    await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    await rename(temporary, this.stateFile);
  }

  async withLock(action) {
    await mkdir(this.dataDir, { recursive: true, mode: 0o700 });
    const lock = path.join(this.dataDir, '.installation-lock');
    try { await mkdir(lock); } catch (error) { if (error.code === 'EEXIST') throw new Error('다른 설치 작업이 진행 중입니다.'); throw error; }
    try { return await action(); } finally { await rmdir(lock); }
  }

  async checkDependencies(client) {
    const checks = [['node', ['--version']], ['ruby', ['--version']], ['git', ['--version']]];
    for (const host of selected(client)) checks.push([host, ['plugin', '--help']], [host, ['plugin', 'marketplace', '--help']], [host, ['plugin', host === 'codex' ? 'add' : 'install', '--help']]);
    const results = [];
    for (const [command, args] of checks) {
      let result;
      try { result = await this.runner(command, args); } catch { throw new Error(`필수 의존성/명령 없음: ${command} ${args.join(' ')}. 공식 설치 안내를 확인하세요. 자동 설치하지 않습니다.`); }
      const output = result.stdout ?? '';
      if (command === 'node' && args[0] === '--version' && Number(output.match(/v?(\d+)/)?.[1] ?? 0) < 22) throw new Error('Node >=22 필요');
      if (CLIENTS.includes(command) && args.at(-1) === '--help') {
        const required = args[1] === 'marketplace' ? ['add', 'list', command === 'codex' ? 'upgrade' : 'update'] : args.length === 2 ? ['marketplace', command === 'codex' ? 'add' : 'install'] : command === 'claude' ? ['--scope'] : [];
        if (required.some(token => !output.includes(token))) throw new Error(`${command}: 현재 CLI가 필요한 plugin 명령을 지원하지 않습니다.`);
      }
      results.push({ command, args, output });
    }
    return results;
  }

  async preview({ client = 'both', distributionRoot, pluginName = PLUGIN, preserveLegacySkills = false }) {
    const state = await this.state();
    const conflicts = [];
    const preservedSkills = [];
    const hosts = selected(client);
    for (const host of hosts) {
      const oldSkills = path.join(this.home, `.${host}/skills`);
      if (await exists(oldSkills)) {
        for (const name of await readdir(oldSkills)) {
          if (!['setup', 'code-change', 'feature-plan', 'feature-apply', 'bugfix-plan', 'bugfix-apply', 'complete-work', 'cpm', 'apply-workplan-feedback', 'project-baseline', 'promote-codex-rule', 'plan-ui-with-design-system', 'implement-ui-with-design-system', 'plan-design-system-component', 'author-design-system-component'].includes(name)) continue;
          const item = { client: host, path: path.join(oldSkills, name), reason: `기존 스킬 보존; namespaced ${PRODUCT_NAME} 설치는 이 경로를 수정하지 않음` };
          if (preserveLegacySkills && pluginName === PLUGIN) preservedSkills.push(item);
          else conflicts.push(item);
        }
      }
      const listed = await this.runner(host, ['plugin', 'list', '--json']);
      let plugins;
      try { plugins = JSON.parse(listed.stdout); } catch { throw new Error(`${host} plugin list JSON 확인 실패`); }
      const entries = Array.isArray(plugins) ? plugins : plugins.installed;
      if (!Array.isArray(entries)) throw new Error(`${host} 설치 플러그인 목록 형식 확인 실패`);
      // 관리 폴더 이름(ai-workflow)은 플러그인 ID가 아니다. 실제 식별 필드만 비교한다.
      const identities = entries.flatMap(entry => typeof entry === 'string' ? [{ id: entry }] : ['pluginId', 'id', 'name'].filter(key => typeof entry[key] === 'string').map(key => ({ id: entry[key], marketplace: entry.marketplaceName })));
      for (const name of ['ai-workflow', LEGACY_PLUGIN_ID, PLUGIN]) {
        const matches = identities.filter(entry => entry.id.split('@')[0] === name);
        const present = matches.length > 0;
        const otherCatalog = matches.some(entry => (entry.id.includes('@') ? entry.id.split('@')[1] : entry.marketplace) && (entry.id.includes('@') ? entry.id.split('@')[1] : entry.marketplace) !== 'my-ai-toolbox');
        if (otherCatalog || (present && (!state.clients[host] || installedName(state.clients[host]) !== name))) conflicts.push({ client: host, reason: `기존 미소유 ${name} 플러그인 보존` });
      }
      const catalogs = await this.runner(host, ['plugin', 'marketplace', 'list', '--json']);
      let marketplaces;
      try { marketplaces = JSON.parse(catalogs.stdout); } catch { throw new Error(`${host} marketplace list JSON 확인 실패`); }
      if (JSON.stringify(marketplaces).includes('my-ai-toolbox') && !state.clients[host]) conflicts.push({ client: host, reason: '기존 미소유 my-ai-toolbox catalog 보존' });
    }
    const migrations = hosts.filter(host => state.clients[host] && installedName(state.clients[host]) !== pluginName).map(host => ({ client: host, from: installedName(state.clients[host]), to: pluginName, requiresExplicitReplacement: true }));
    return { client, distributionRoot: path.resolve(distributionRoot), conflicts, preservedSkills, migrations, commands: hosts.flatMap(host => [[host, 'plugin', 'marketplace', 'add', path.resolve(distributionRoot)], [host, 'plugin', host === 'codex' ? 'add' : 'install', selector(pluginName), ...(host === 'claude' ? ['--scope', 'user'] : [])]]), preservesRecords: true, requiresFreshSession: true };
  }

  async install({ client = 'both', distributionRoot, version, confirmed = false, dryRun = true, replaceLegacy = false, preserveLegacySkills = false, pluginName = PLUGIN }) {
    if (!['ai-workflow', LEGACY_PLUGIN_ID, PLUGIN].includes(pluginName)) throw new Error('지원하지 않는 플러그인 식별자');
    await this.checkDependencies(client);
    const preview = await this.preview({ client, distributionRoot, pluginName, preserveLegacySkills });
    if (dryRun) return preview;
    if (!confirmed) throw new Error('설치는 명시 확인이 필요합니다.');
    if (preview.migrations.length && !replaceLegacy) throw new Error('기존 소유 플러그인 이름 전환은 --replace-legacy 별도 확인이 필요합니다.');
    if (preview.conflicts.length) throw new Error(`설치 충돌 ${preview.conflicts.length}건: 기존 항목을 보존했습니다.`);
    const snapshots = {};
    for (const host of selected(client)) {
      const catalogText = await readFile(path.join(preview.distributionRoot, catalogRelative(host)), 'utf8');
      const catalog = JSON.parse(catalogText);
      if (catalog.name !== 'my-ai-toolbox' || catalog.plugins?.length !== 1 || catalog.plugins[0].name !== pluginName) throw new Error('설치 생성물의 단일 소유 catalog를 확인할 수 없습니다.');
      snapshots[host] = digest(catalogText);
    }
    return this.withLock(async () => {
      const state = await this.state();
      const completed = [];
      for (const host of selected(client)) {
        const prior = state.clients[host];
        let catalogAdded = false;
        let priorCatalogRemoved = false;
        let priorPluginRemoved = false;
        try {
          if (prior) {
            const before = await readFile(path.join(prior.distributionRoot, catalogRelative(host)), 'utf8');
            if (prior.catalogHash !== digest(before)) throw new Error('기존 소유 catalog가 변경되었습니다. 미소유/사용자 추가 항목을 보존합니다.');
          }
          if (prior && (prior.distributionRoot !== preview.distributionRoot || installedName(prior) !== pluginName)) {
            if (installedName(prior) !== pluginName) {
              await this.runner(host, ['plugin', host === 'codex' ? 'remove' : 'uninstall', selector(installedName(prior)), ...(host === 'claude' ? ['--scope', 'user'] : [])]);
              priorPluginRemoved = true;
            }
            // Only our single-plugin catalog is replaceable; unrelated marketplaces are never removed.
            await this.runner(host, ['plugin', 'marketplace', 'remove', 'my-ai-toolbox']);
            priorCatalogRemoved = true;
          }
          if (!prior || priorCatalogRemoved) { await this.runner(host, ['plugin', 'marketplace', 'add', preview.distributionRoot]); catalogAdded = true; }
          await this.runner(host, ['plugin', host === 'codex' ? 'add' : 'install', selector(pluginName), ...(host === 'claude' ? ['--scope', 'user'] : [])]);
          state.clients[host] = { pluginName, preserveLegacySkills, version, distributionRoot: preview.distributionRoot, catalogHash: snapshots[host], installedAt: new Date().toISOString(), previous: prior ?? null };
          await this.save(state);
          completed.push(host);
        } catch (error) {
          if (catalogAdded) {
            try { await this.runner(host, ['plugin', host === 'codex' ? 'remove' : 'uninstall', selector(pluginName), ...(host === 'claude' ? ['--scope', 'user'] : [])]); } catch { /* The host may have failed before installation. */ }
            try { await this.runner(host, ['plugin', 'marketplace', 'remove', 'my-ai-toolbox']); } catch { /* Report manual recovery without touching unrelated settings. */ }
          }
          if (priorCatalogRemoved || priorPluginRemoved) {
            try {
              if (priorCatalogRemoved) await this.runner(host, ['plugin', 'marketplace', 'add', prior.distributionRoot]);
              await this.runner(host, ['plugin', host === 'codex' ? 'add' : 'install', selector(installedName(prior)), ...(host === 'claude' ? ['--scope', 'user'] : [])]);
            } catch { error.message += ' 이전 소유 catalog 복원 실패; installation.json의 이전 경로에서 수동 복구가 필요합니다.'; }
          }
          error.message = `${host} 설치 실패; 완료 클라이언트 ${completed.join(',') || '없음'} 보존. ${error.message}`;
          throw error;
        }
      }
      const store = new SettingsStore({ configPath: this.settingsPath, dataRoot: this.dataDir });
      const records = await store.initializeRecords({ clients: completed, confirmed: true, confirmationSource: '사용자가 승인한 플러그인 설치의 공통 기록 준비' });
      return { ...preview, installed: completed, version, records, loadedVersion: '새 세션에서 확인 필요' };
    });
  }

  async update({ client = 'both', confirmed = false, dryRun = true } = {}) {
    const state = await this.state();
    const commands = [];
    for (const host of selected(client)) {
      if (!state.clients[host]) throw new Error(`${host}: 소유 설치 기록 없음`);
      commands.push([host, 'plugin', 'marketplace', host === 'codex' ? 'upgrade' : 'update', 'my-ai-toolbox']);
      if (host === 'claude') commands.push([host, 'plugin', 'update', selector(installedName(state.clients[host])), '--scope', 'user']);
    }
    if (!dryRun) {
      if (!confirmed) throw new Error('업데이트 명시 확인 필요');
      for (const [host, ...args] of commands) await this.runner(host, args);
    }
    return { commands, catalogRefreshed: !dryRun, codexPackageApplication: '앱 플러그인 관리에서 설치 버전 확인', loadedVersion: '새 세션에서 확인 필요', preservesRecords: true };
  }

  async rollback({ client, confirmed = false, dryRun = true }) {
    if (!CLIENTS.includes(client)) throw new Error('롤백은 단일 client를 선택하세요.');
    const current = (await this.state()).clients[client];
    const previous = current?.previous;
    if (!previous) throw new Error('이전 소유 설치 버전이 없습니다.');
    return this.install({ client, distributionRoot: previous.distributionRoot, version: previous.version, pluginName: installedName(previous), preserveLegacySkills: current.preserveLegacySkills === true, replaceLegacy: true, confirmed, dryRun });
  }

  async manageBlock({ client, content, confirmed = false, dryRun = true }) {
    if (!CLIENTS.includes(client)) throw new Error('단일 client 필요');
    const file = path.join(this.home, client === 'codex' ? '.codex/AGENTS.md' : '.claude/CLAUDE.md');
    if (await exists(file) && (await lstat(file)).isSymbolicLink()) throw new Error('전역 지침 symlink 보존');
    const before = await exists(file) ? await readFile(file, 'utf8') : '';
    const state = await this.state();
    const owned = state.managedBlocks[file];
    const oldBlock = before.includes(START) ? before.slice(before.indexOf(START), before.indexOf(END) + END.length) : null;
    if (oldBlock && (!owned || owned.hash !== digest(oldBlock))) throw new Error('미소유 또는 변경된 관리 블록 보존');
    const after = replaceManagedBlock(before, content);
    if (!dryRun) {
      if (!confirmed) throw new Error('전역 지침 연결 명시 확인 필요');
      await mkdir(path.dirname(file), { recursive: true });
      const backup = path.join(this.dataDir, 'backups', randomUUID());
      await mkdir(path.dirname(backup), { recursive: true, mode: 0o700 });
      await writeFile(backup, before, { mode: 0o600 });
      await writeFile(file, after);
      const block = content === null ? null : after.slice(after.indexOf(START), after.indexOf(END) + END.length);
      if (block) state.managedBlocks[file] = { hash: digest(block), backup }; else delete state.managedBlocks[file];
      await this.save(state);
    }
    return { file, before, after, dryRun };
  }

  async uninstall({ client = 'both', confirmed = false, dryRun = true, purgeRecordIds = [], confirmRecords = false, selectors = {} } = {}) {
    const state = await this.state();
    const hosts = selected(client);
    const otherClients = Object.keys(state.clients).filter(host => !hosts.includes(host));
    if (purgeRecordIds.length && otherClients.length) throw new Error('다른 클라이언트가 사용하는 공유 기록 보존');
    const records = [];
    for (const id of purgeRecordIds) {
      if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,255}$/.test(id)) throw new Error('안전한 기록 ID 필요');
      const record = state.ownedRecords.find(value => value.id === id && value.owner === 'ai-workflow');
      if (!record || record.external) throw new Error('자기 소유 관리 기록만 선택할 수 있습니다.');
      const real = await this.verifyOwnedRecord(record);
      const data = await realpath(this.dataDir);
      if (!real.startsWith(`${data}${path.sep}workspaces${path.sep}`) || (await lstat(record.path)).isSymbolicLink()) throw new Error('관리 기록 경계 밖 경로 보존');
      records.push({ id, path: real, recovery: path.join(this.dataDir, 'recovery', `${id}-${randomUUID()}`) });
    }
    const plan = await inspectOwnedUninstall({ home: this.home, dataDir: this.dataDir, settingsPath: this.settingsPath, client, state, runner: this.runner, selectors });
    const base = { ...plan, records, availableOwnedRecords: state.ownedRecords.map(record => ({ id: record.id, path: record.path })), otherClients, preservedBlocks: [], preservesRecords: records.length === 0, dryRun };
    if (dryRun) return base;
    if (!confirmed || (records.length && !confirmRecords)) throw new Error('제거 및 선택 기록의 별도 확인 필요');
    if (plan.ambiguities.length) throw new Error('제거 대상 확인 필요: 정확한 plugin@marketplace를 선택하고 호스트 목록 조회 문제를 해결하세요.');
    await safeInstructionPath(this.dataDir.startsWith(`${this.home}${path.sep}`) ? this.home : this.dataDir, path.join(this.dataDir, '_probe'));
    return this.withLock(async () => {
      const current = await this.state();
      if (plan.targets.some(target => JSON.stringify(current.clients[target.client] ?? null) !== JSON.stringify(target.before))) throw new Error('사전 조사 이후 설치 상태 변경; 다시 확인하세요.');
      const removed = await removeSelectedHostPlugins(plan, this.runner);
      const instructions = await cleanupOwnedInstructions({ plan, removed });
      const store = new SettingsStore({ configPath: this.settingsPath, dataRoot: this.dataDir });
      const viewer = await stopViewerAfterLastRemoval({ plan, removed, runner: this.runner, store });
      const latest = mergeUninstallResult(await this.state(), removed, instructions);
      const movedRecords = [];
      const recordsBlocked = records.length && (removed.some(item => item.status === 'failed') || viewer.status === 'preserved');
      if (!recordsBlocked) {
        for (const record of records) {
          await this.verifyOwnedRecord(latest.ownedRecords.find(item => item.id === record.id));
          await mkdir(path.dirname(record.recovery), { recursive: true });
          await rename(record.path, record.recovery);
          const registry = path.join(this.dataDir, 'owned-records', `${record.id}.json`);
          if (await exists(registry) && !(await lstat(registry)).isSymbolicLink()) await rename(registry, path.join(record.recovery, '.ownership-registry.json'));
          movedRecords.push(record.id);
        }
        latest.ownedRecords = latest.ownedRecords.filter(record => !movedRecords.includes(record.id));
      }
      await this.save(latest);
      return { ...base, removed, instructions, viewer, preservedBlocks: instructions.preserved.map(item => item.path), preservesRecords: movedRecords.length === 0, ...(recordsBlocked ? { recordsPreservedReason: '다른 설치 또는 제거 확인 실패로 공유 기록 보존' } : {}) };
    });
  }
}

export async function interactiveSetup({ store, ask, output = console.log, client = 'both', currentPath = process.cwd(), providers, hostObservations = [] }) {
  const records = await store.initializeRecords({ clients: selected(client), confirmed: true, confirmationSource: `사용자가 요청한 ${PRODUCT_NAME} 초기 설정` });
  const state = await store.projectCatalog();
  output(`현재 작업 폴더: ${currentPath}\n공통 기록 위치: ${records.projectsRoot}\nCodex·Claude가 같은 기록을 사용합니다. 기존 등록 경로는 보존합니다.`);
  const root = await ask('프로젝트들이 들어 있는 상위 폴더 절대경로 (빈칸: 나중에): ');
  const connectionPlan = () => new IntegrationService({ store }).plan({ clients: selected(client), providers: integrationSelection(providers ?? []), hostObservations });
  if (!root.trim()) return { saved: true, records, projects: [], reason: '공통 기록 위치 준비 완료. 프로젝트는 나중에 등록할 수 있습니다.', connectionPlan: await connectionPlan() };
  const scanRoot = await canonicalPath(root.trim());
  const previousRoot = state.projectRoots.find(item => item.path === scanRoot);
  const rootOptions = previousRoot ?? { path: scanRoot, maxDepth: 3 };
  const patch = { confirmed: true, confirmationSource: '사용자가 지정한 프로젝트 폴더', projectRoots: [...state.projectRoots.filter(item => item.path !== scanRoot), rootOptions] };
  await store.save(patch);
  const discovery = await store.discover({ root: scanRoot, maxDepth: rootOptions.maxDepth ?? 3, excludedNames: rootOptions.excludedNames ?? [] });
  // 기존 프로젝트는 ID·기록 위치·실행 신뢰까지 그대로 재사용한다.
  const reserved = new Set(Object.keys(state.projects));
  const projects = [];
  const pending = [];
  for (const candidate of [...discovery.candidates].sort((a, b) => a.repositoryPath.localeCompare(b.repositoryPath))) {
    const context = await store.projectContext({ currentPath: candidate.repositoryPath });
    if (context.status === 'ambiguous') throw new Error('같은 프로젝트가 여러 회사에 연결되어 있습니다. 사용할 작업공간을 확인해 주세요');
    const existing = context.status === 'registered' ? [context.projectId, context] : null;
    if (existing) { projects.push({ projectId: existing[0], ...existing[1], reused: true }); continue; }
    const base = path.basename(candidate.repositoryPath).replace(/[^a-zA-Z0-9._-]/g, '-').replace(/^[^a-zA-Z0-9]+/, '').slice(0, 70) || 'project';
    let projectId = base;
    for (let suffix = 0; reserved.has(projectId); suffix++) projectId = `${base}-${candidate.candidateId.slice(0, 8)}${suffix ? `-${suffix}` : ''}`;
    reserved.add(projectId);
    pending.push({ candidate, projectId });
  }
  output(JSON.stringify({ records, existing: projects.map(project => project.projectId), newProjects: pending.map(({ candidate, projectId }) => ({ projectId, repositoryPath: candidate.repositoryPath, records: path.join(records.projectsRoot, projectId) })), truncated: discovery.truncated, warning: discovery.warning }, null, 2));
  if (pending.length && (await ask('위 새 프로젝트를 등록하고 기록 폴더를 만들까요? [y/N] ')).toLowerCase() === 'y') {
    for (const { candidate, projectId } of pending) projects.push(await store.confirmProject({ discoveryId: discovery.discoveryId, candidateId: candidate.candidateId, projectId, workspaceId: 'personal', confirmed: true, confirmationSource: '사용자가 발견 프로젝트 목록의 등록을 확인', executionTrusted: false }));
  }
  return { saved: true, records, projects, truncated: discovery.truncated, connectionPlan: await connectionPlan(), services: '선택 연동과 실행 신뢰는 별도로 설정합니다. 인증은 각 호스트에 맡깁니다.' };
}

async function main() {
  const args = process.argv.slice(2);
  const get = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
  const actions = ['--install', '--check', '--setup', '--update', '--uninstall', '--rollback', '--link-instructions'].filter(name => args.includes(name));
  if (actions.length > 1) throw new Error('관리 작업은 한 번에 하나를 선택하세요.');
  for (let index = 0; index < args.length; index++) {
    if (['--client', '--purge-record', '--integrations', '--project-root', '--plugin-selector'].includes(args[index])) { if (!args[index + 1] || args[index + 1].startsWith('--')) throw new Error(`${args[index]} 값 필요`); index++; continue; }
    if (![...actions, '--dry-run', '--apply', '--confirm-records', '--with-archify', '--with-serena', '--replace-legacy', '--preserve-legacy-skills'].includes(args[index])) throw new Error(`알 수 없는 인자: ${args[index]}`);
  }
  const client = get('--client', 'both');
  selected(client);
  const mode = actions[0]?.slice(2) ?? 'dry-run';
  if (args.includes('--plugin-selector') && (mode !== 'uninstall' || client === 'both')) throw new Error('--plugin-selector는 단일 client의 --uninstall에서만 사용하세요.');
  if (args.includes('--project-root') && mode !== 'setup') throw new Error('--project-root는 --setup에서만 사용하세요.');
  const apply = (args.includes('--apply') || mode === 'install') && !args.includes('--dry-run');
  if (mode === 'dry-run' && apply) throw new Error('--apply에는 관리 작업 선택이 필요합니다.');
  if (args.includes('--replace-legacy') && !['install', 'dry-run'].includes(mode)) throw new Error('--replace-legacy는 설치/미리보기에서만 사용하세요.');
  if (args.includes('--preserve-legacy-skills') && !['install', 'dry-run'].includes(mode)) throw new Error('--preserve-legacy-skills는 설치/미리보기에서만 사용하세요.');
  const purgeRecordIds = args.flatMap((value, index) => value === '--purge-record' ? [args[index + 1]] : []);
  if (purgeRecordIds.length && mode !== 'uninstall') throw new Error('--purge-record는 제거 작업에만 사용할 수 있습니다.');
  const manager = new InstallationManager({ dataDir: process.env.AI_WORKFLOW_DATA_ROOT, settingsPath: process.env.AI_WORKFLOW_CONFIG });
  const providers = integrationSelection(get('--integrations', ''));
  if (args.includes('--integrations') && !['install', 'dry-run', 'check', 'setup'].includes(mode)) throw new Error('--integrations는 설치/미리보기/검사/설정에서만 사용하세요.');
  const integrationStore = new SettingsStore({ configPath: manager.settingsPath, dataRoot: manager.dataDir });
  const integrationPlan = async (options = {}) => prepareIntegrations({ store: integrationStore, client, providers: providers.filter(provider => provider !== 'serena' || !args.includes('--with-serena')), manager, ...options });
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  if (args.includes('--with-serena') && !['install', 'dry-run', 'check'].includes(mode)) throw new Error('--with-serena는 설치/미리보기/검사에서만 사용하세요.');
  if (mode === 'setup') {
    if (args.includes('--dry-run')) throw new Error('--setup은 실제 초기 설정입니다. 프로젝트 등록은 목록 확인 또는 --project-root와 --apply로 요청하세요.');
    if (args.includes('--project-root')) {
      if (!apply) throw new Error('--project-root로 초기 설정하려면 --apply가 필요합니다.');
      const answers = [get('--project-root'), 'y'];
      console.log(JSON.stringify(await interactiveSetup({ store: integrationStore, ask: async () => answers.shift(), output: () => {}, client, ...(args.includes('--integrations') ? { providers } : {}) }), null, 2));
      return;
    }
    if (!process.stdin.isTTY) throw new Error('--setup은 대화형 터미널이 필요합니다. 호스트 setup 스킬도 사용할 수 있습니다.');
    const { createInterface } = await import('node:readline/promises');
    const terminal = createInterface({ input: process.stdin, output: process.stdout });
    try { console.log(JSON.stringify(await interactiveSetup({ store: integrationStore, ask: prompt => terminal.question(prompt), client, currentPath: process.cwd(), ...(args.includes('--integrations') ? { providers } : {}) }), null, 2)); } finally { terminal.close(); }
    return;
  }
  const checks = await manager.checkDependencies(client);
  if (['update', 'uninstall', 'rollback', 'link-instructions'].includes(mode)) {
    const options = { client, dryRun: !apply, confirmed: apply };
    if (mode === 'update') console.log(JSON.stringify(await manager.update(options), null, 2));
    if (mode === 'uninstall') console.log(JSON.stringify(await manager.uninstall({ ...options, purgeRecordIds, confirmRecords: args.includes('--confirm-records'), selectors: args.includes('--plugin-selector') ? { [client]: get('--plugin-selector') } : {} }), null, 2));
    if (mode === 'rollback') console.log(JSON.stringify(await manager.rollback(options), null, 2));
    if (mode === 'link-instructions') {
      const state = await manager.state();
      for (const host of selected(client)) {
        const installed = state.clients[host];
        if (!installed) throw new Error(`${host}: 소유 설치 기록 없음`);
        const contract = path.join(installed.distributionRoot, 'plugins', host, installedName(installed), host === 'codex' ? 'AGENTS.md' : 'CLAUDE.md');
        await readFile(contract, 'utf8');
        const content = `${installedName(installed) === PLUGIN ? PRODUCT_NAME : 'ai-workflow'} ${installed.version}의 [공통 작업 지침](<${contract}>)을 읽고 작업에 필요한 규칙만 따른다. 플러그인의 실제 MCP 도구와 namespaced 스킬을 사용한다. 연결·사용자 승인·프로젝트 신뢰를 추정하지 않으며 commit/push/종료 권한은 별도다. 이 블록은 모델 설정을 바꾸지 않는다.`;
        console.log(JSON.stringify(await manager.manageBlock({ client: host, content, confirmed: apply, dryRun: !apply }), null, 2));
      }
    }
    return;
  }
  if (mode === 'check') {
    console.log(JSON.stringify({ checks, sourceVersion: pkg.version, installed: (await manager.state()).clients, loadedSession: `새 세션에서 ${PRODUCT_NAME}의 세 MCP 도구·스킬 노출 확인 필요`, records: '전체 이력 검사 미실행', ...(args.includes('--with-serena') ? { serena: await provisionSerena({ client, runner: manager.runner, check: true }) } : {}), ...(args.includes('--integrations') ? { connectionPlan: await integrationPlan({ check: true }) } : {}) }, null, 2));
    return;
  }
  if (!['install', 'dry-run'].includes(mode)) throw new Error('지원하지 않는 실행 mode');
  const outputRoot = path.join(root, 'dist', `release-${pkg.version}-${Date.now()}`);
  if (!apply) {
    console.log(JSON.stringify({ mode: 'dry-run', checks, ...await manager.preview({ client, distributionRoot: outputRoot, preserveLegacySkills: args.includes('--preserve-legacy-skills') }), build: '미실행; --install에서 잠금 의존성 확인 후 생성', archify: args.includes('--with-archify') ? '설치 시 별도 다운로드 요청됨' : '다운로드 없음', ...(args.includes('--with-serena') ? { serena: await provisionSerena({ client, runner: manager.runner }) } : {}), ...(args.includes('--integrations') ? { connectionPlan: await integrationPlan() } : {}) }, null, 2));
    return;
  }
  // Validate optional Serena migrations before building or installing the plugin.
  if (args.includes('--with-serena')) await provisionSerena({ client, runner: manager.runner });
  if (args.includes('--integrations')) console.log(JSON.stringify({ connectionPlan: await integrationPlan() }, null, 2));
  const { buildDistribution } = await import('../scripts/build.mjs');
  const bundle = await buildDistribution({ outputRoot });
  if (args.includes('--with-serena')) console.log(JSON.stringify(await provisionSerena({ client, dryRun: false, confirmed: true, runner: manager.runner }), null, 2));
  console.log(JSON.stringify(await manager.install({ client, distributionRoot: bundle.root, version: bundle.version, replaceLegacy: args.includes('--replace-legacy'), preserveLegacySkills: args.includes('--preserve-legacy-skills'), dryRun: false, confirmed: true }), null, 2));
  if (args.includes('--integrations')) console.log(JSON.stringify({ connectionPlan: await integrationPlan({ dryRun: false, confirmed: true }) }, null, 2));
  if (args.includes('--with-archify')) {
    const { provisionArchify } = await import('./diagram.mjs');
    console.log(JSON.stringify(await provisionArchify({ destination: path.join(manager.dataDir, 'tools/archify'), confirmed: true }), null, 2));
  }
  console.log(`공통 기록 위치를 준비했습니다. 새 세션의 ${PRODUCT_NAME} setup에서 프로젝트 폴더만 지정하세요. 실제 세션 로딩·서비스 인증은 별도 확인이 필요합니다.`);
}

if (process.argv[1] && await realpath(process.argv[1]).catch(() => null) === fileURLToPath(import.meta.url)) main().catch(error => { console.error(error.message); process.exitCode = 1; });
