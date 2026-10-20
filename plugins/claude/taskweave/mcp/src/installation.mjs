import { mkdir, readFile, writeFile, rename, lstat, realpath, readdir } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { IntegrationService, PROVIDERS } from './integrations.mjs';

const execute = promisify(execFile);
const CLIENTS = ['codex', 'claude'];
const PLUGIN = 'taskweave';
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

export class InstallationManager {
  constructor({ home = os.homedir(), dataDir, runner } = {}) {
    this.home = path.resolve(home);
    this.dataDir = path.resolve(dataDir ?? path.join(this.home, '.local/share/ai-workflow'));
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
    try { return await action(); } finally { const { rmdir } = await import('node:fs/promises'); await rmdir(lock); }
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
          const item = { client: host, path: path.join(oldSkills, name), reason: '기존 스킬 보존; namespaced Taskweave 설치는 이 경로를 수정하지 않음' };
          if (preserveLegacySkills && pluginName === PLUGIN) preservedSkills.push(item);
          else conflicts.push(item);
        }
      }
      const listed = await this.runner(host, ['plugin', 'list', '--json']);
      let plugins;
      try { plugins = JSON.parse(listed.stdout); } catch { throw new Error(`${host} plugin list JSON 확인 실패`); }
      for (const name of ['ai-workflow', PLUGIN]) {
        const present = new RegExp(`(?:^|["/@:])${name}(?:["/@:]|$)`).test(JSON.stringify(plugins));
        const otherCatalog = [...JSON.stringify(plugins).matchAll(new RegExp(`${name}@([a-zA-Z0-9._-]+)`, 'g'))].some(match => match[1] !== 'my-ai-toolbox');
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
    if (!['ai-workflow', PLUGIN].includes(pluginName)) throw new Error('지원하지 않는 플러그인 식별자');
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
      return { ...preview, installed: completed, version, loadedVersion: '새 세션에서 확인 필요' };
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

  async uninstall({ client = 'both', confirmed = false, dryRun = true, purgeRecordIds = [], confirmRecords = false } = {}) {
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
    const commands = hosts.filter(host => state.clients[host]).map(host => [host, 'plugin', host === 'codex' ? 'remove' : 'uninstall', selector(installedName(state.clients[host])), ...(host === 'claude' ? ['--scope', 'user'] : [])]);
    const preservedBlocks = [];
    if (!dryRun) {
      if (!confirmed || (records.length && !confirmRecords)) throw new Error('제거 및 선택 기록의 별도 확인 필요');
      await this.withLock(async () => {
        for (const [host, ...args] of commands) {
          await this.runner(host, args);
          delete state.clients[host];
          const file = path.join(this.home, host === 'codex' ? '.codex/AGENTS.md' : '.claude/CLAUDE.md');
          if (state.managedBlocks[file]) {
            try { await this.manageBlock({ client: host, content: null, confirmed: true, dryRun: false }); delete state.managedBlocks[file]; }
            catch { preservedBlocks.push(file); }
          }
          await this.save(state);
        }
        for (const record of records) {
          await this.verifyOwnedRecord(state.ownedRecords.find(item => item.id === record.id));
          await mkdir(path.dirname(record.recovery), { recursive: true });
          await rename(record.path, record.recovery);
          const registry = path.join(this.dataDir, 'owned-records', `${record.id}.json`);
          if (await exists(registry) && !(await lstat(registry)).isSymbolicLink()) await rename(registry, path.join(record.recovery, '.ownership-registry.json'));
        }
        state.ownedRecords = state.ownedRecords.filter(record => !purgeRecordIds.includes(record.id));
        await this.save(state);
      });
    }
    return { commands, records, availableOwnedRecords: state.ownedRecords.map(record => ({ id: record.id, path: record.path })), otherClients, preservedBlocks, preservesRecords: records.length === 0, dryRun };
  }
}

export async function interactiveSetup({ store, ask, output = console.log, client = 'both', currentPath = process.cwd(), providers, hostObservations = [] }) {
  const state = await store.load();
  output(`현재 작업 폴더: ${currentPath}\n관리 데이터: ${store.dataRoot}\n기존 기록은 원래 위치에 보존합니다.`);
  if ((await ask('이 관리 위치를 사용할까요? [y/N] ')).toLowerCase() !== 'y') return { saved: false, reason: '관리 위치 선택 보류; 호스트 setup에서 지정 가능' };
  const root = await ask('프로젝트들이 들어 있는 상위 폴더 절대경로 (빈칸: 나중에): ');
  const connectionPlan = async () => {
    const chosen = providers ?? integrationSelection((await ask('필요한 연동 serena,figma,jira (빈칸: 나중에): ')) ?? '');
    return new IntegrationService({ store }).plan({ clients: selected(client), providers: integrationSelection(chosen), hostObservations });
  };
  if (!root.trim()) return { saved: false, reason: '프로젝트 등록 없이 선택 연동만 확인할 수 있습니다.', connectionPlan: await connectionPlan() };
  const workspaces = state.workspaces.personal ? undefined : { personal: { root: path.join(store.dataRoot, 'workspaces/personal'), trusted: false } };
  const patch = { confirmed: true, confirmationSource: 'interactive CLI: 사용자가 관리 위치·탐색 root 저장 확인', clients: selected(client), projectRoots: [...state.projectRoots.filter(item => item.path !== path.resolve(root)), { path: path.resolve(root), maxDepth: 3 }], ...(workspaces ? { workspaces } : {}) };
  output(JSON.stringify(patch, null, 2));
  if ((await ask('위 비밀 아닌 설정을 저장하고 이 범위만 탐색할까요? [y/N] ')).toLowerCase() !== 'y') return { saved: false };
  await store.save(patch);
  const discovery = await store.discover({ root: path.resolve(root), maxDepth: 3 });
  output(JSON.stringify(discovery, null, 2));
  for (const candidate of discovery.candidates) {
    const projectId = await ask(`${candidate.repositoryPath} 등록 ID (빈칸: 제외): `);
    if (!projectId.trim()) continue;
    const executionTrusted = (await ask('등록과 별개로 이 프로젝트의 확인된 실행기를 신뢰할까요? [y/N] ')).toLowerCase() === 'y';
    await store.confirmProject({ discoveryId: discovery.discoveryId, candidateId: candidate.candidateId, projectId: projectId.trim(), workspaceId: 'personal', confirmed: true, confirmationSource: 'interactive CLI: 발견 후보·ID 확인', executionTrusted, ...(executionTrusted ? { trustSource: 'interactive CLI: 별도 실행 신뢰 확인' } : {}) });
  }
  return { saved: true, connectionPlan: await connectionPlan(), services: '인증·실제 읽기 확인은 각 호스트에서 수행하세요. 토큰을 입력하지 마세요.' };
}

async function main() {
  const args = process.argv.slice(2);
  const get = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
  const actions = ['--install', '--check', '--setup', '--update', '--uninstall', '--rollback', '--link-instructions'].filter(name => args.includes(name));
  if (actions.length > 1) throw new Error('관리 작업은 한 번에 하나를 선택하세요.');
  for (let index = 0; index < args.length; index++) {
    if (['--client', '--purge-record', '--integrations'].includes(args[index])) { if (!args[index + 1] || args[index + 1].startsWith('--')) throw new Error(`${args[index]} 값 필요`); index++; continue; }
    if (![...actions, '--dry-run', '--apply', '--confirm-records', '--with-archify', '--with-serena', '--replace-legacy', '--preserve-legacy-skills'].includes(args[index])) throw new Error(`알 수 없는 인자: ${args[index]}`);
  }
  const client = get('--client', 'both');
  selected(client);
  const mode = actions[0]?.slice(2) ?? 'dry-run';
  const apply = (args.includes('--apply') || mode === 'install') && !args.includes('--dry-run');
  if (mode === 'dry-run' && apply) throw new Error('--apply에는 관리 작업 선택이 필요합니다.');
  if (args.includes('--replace-legacy') && !['install', 'dry-run'].includes(mode)) throw new Error('--replace-legacy는 설치/미리보기에서만 사용하세요.');
  if (args.includes('--preserve-legacy-skills') && !['install', 'dry-run'].includes(mode)) throw new Error('--preserve-legacy-skills는 설치/미리보기에서만 사용하세요.');
  const purgeRecordIds = args.flatMap((value, index) => value === '--purge-record' ? [args[index + 1]] : []);
  if (purgeRecordIds.length && mode !== 'uninstall') throw new Error('--purge-record는 제거 작업에만 사용할 수 있습니다.');
  const manager = new InstallationManager();
  const providers = integrationSelection(get('--integrations', ''));
  if (args.includes('--integrations') && !['install', 'dry-run', 'check', 'setup'].includes(mode)) throw new Error('--integrations는 설치/미리보기/검사/설정에서만 사용하세요.');
  const { SettingsStore } = await import('./settings.mjs');
  const integrationStore = new SettingsStore({ configPath: path.join(manager.home, '.config/ai-workflow/settings.json'), dataRoot: manager.dataDir });
  const integrationPlan = async (options = {}) => prepareIntegrations({ store: integrationStore, client, providers: providers.filter(provider => provider !== 'serena' || !args.includes('--with-serena')), manager, ...options });
  const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  if (args.includes('--with-serena') && !['install', 'dry-run', 'check'].includes(mode)) throw new Error('--with-serena는 설치/미리보기/검사에서만 사용하세요.');
  if (mode === 'setup') {
    if (!process.stdin.isTTY) throw new Error('--setup은 대화형 터미널이 필요합니다. 호스트 setup 스킬도 사용할 수 있습니다.');
    const { SettingsStore } = await import('./settings.mjs');
    const { createInterface } = await import('node:readline/promises');
    const terminal = createInterface({ input: process.stdin, output: process.stdout });
    try { console.log(JSON.stringify(await interactiveSetup({ store: integrationStore, ask: prompt => terminal.question(prompt), client, currentPath: process.cwd(), ...(args.includes('--integrations') ? { providers } : {}) }), null, 2)); } finally { terminal.close(); }
    return;
  }
  const checks = await manager.checkDependencies(client);
  if (['update', 'uninstall', 'rollback', 'link-instructions'].includes(mode)) {
    const options = { client, dryRun: !apply, confirmed: apply };
    if (mode === 'update') console.log(JSON.stringify(await manager.update(options), null, 2));
    if (mode === 'uninstall') console.log(JSON.stringify(await manager.uninstall({ ...options, purgeRecordIds, confirmRecords: args.includes('--confirm-records') }), null, 2));
    if (mode === 'rollback') console.log(JSON.stringify(await manager.rollback(options), null, 2));
    if (mode === 'link-instructions') {
      const state = await manager.state();
      for (const host of selected(client)) {
        const installed = state.clients[host];
        if (!installed) throw new Error(`${host}: 소유 설치 기록 없음`);
        const contract = path.join(installed.distributionRoot, 'plugins', host, installedName(installed), host === 'codex' ? 'AGENTS.md' : 'CLAUDE.md');
        await readFile(contract, 'utf8');
        const content = `${installedName(installed) === PLUGIN ? 'Taskweave' : 'ai-workflow'} ${installed.version}의 [공통 작업 지침](<${contract}>)을 읽고 작업에 필요한 규칙만 따른다. 플러그인의 실제 MCP 도구와 namespaced 스킬을 사용한다. 연결·사용자 승인·프로젝트 신뢰를 추정하지 않으며 commit/push/종료 권한은 별도다. 이 블록은 모델 설정을 바꾸지 않는다.`;
        console.log(JSON.stringify(await manager.manageBlock({ client: host, content, confirmed: apply, dryRun: !apply }), null, 2));
      }
    }
    return;
  }
  if (mode === 'check') {
    console.log(JSON.stringify({ checks, sourceVersion: pkg.version, installed: (await manager.state()).clients, loadedSession: '새 세션에서 Taskweave의 세 MCP 도구·스킬 노출 확인 필요', records: '전체 이력 검사 미실행', ...(args.includes('--with-serena') ? { serena: await provisionSerena({ client, runner: manager.runner, check: true }) } : {}), ...(args.includes('--integrations') ? { connectionPlan: await integrationPlan({ check: true }) } : {}) }, null, 2));
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
  console.log('설치 캐시/세션 실제 로딩은 아직 확인하지 않았습니다. 관리가 필요할 때만 --setup 또는 새 세션의 Taskweave setup으로 위치·프로젝트 보관 폴더를 확인하세요.');
}

if (process.argv[1] && await realpath(process.argv[1]).catch(() => null) === fileURLToPath(import.meta.url)) main().catch(error => { console.error(error.message); process.exitCode = 1; });
