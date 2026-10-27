import { mkdir, readFile, stat, unlink, open, realpath, lstat } from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { SettingsStore, atomicJSON, requireWithin, withLock } from '../settings.mjs';
import { startViewer } from './main.mjs';
import { PRODUCT_NAME } from '../product.mjs';

const execute = promisify(execFile);
const pause = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const SERVICE = 'taskweave-viewer-v1';

async function readJSON(file) {
  try { return JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}

async function runtimeFiles(store) {
  const directory = await requireWithin(store.dataRoot, path.join(store.dataRoot, 'viewer'), { allowMissing: true });
  await mkdir(directory, { recursive: true, mode: 0o700 });
  return { directory, state: path.join(directory, 'service.json'), lock: path.join(directory, 'startup.lock'), roots: path.join(directory, 'roots.json'), log: path.join(directory, 'service.log') };
}

// 기존 등록과 별도로 연결한 기록을 합친다. 제품 코드·사용자 설정은 이동하거나 수정하지 않는다.
export async function resolveViewerRoots(store) {
  const settings = await store.load();
  const files = await runtimeFiles(store);
  const linked = await readJSON(files.roots);
  if (linked && (!Array.isArray(linked.roots) || linked.roots.some(root => typeof root !== 'string' || !path.isAbsolute(root)))) throw new Error('뷰어 기록 폴더 설정을 확인해 주세요.');
  const managed = await requireWithin(store.dataRoot, path.join(store.dataRoot, 'workspaces'), { allowMissing: true });
  await mkdir(managed, { recursive: true, mode: 0o700 });
  const candidates = [managed, ...(linked?.roots ?? []), ...Object.values(settings.projects).map(project => project.workplanRoot), ...Object.values(settings.workspaces).map(workspace => path.join(workspace.root, 'Workplans'))];
  const roots = new Set();
  for (const candidate of candidates.filter(Boolean)) {
    try {
      const root = await realpath(candidate);
      if (root === path.parse(root).root || root === os.homedir()) throw new Error('홈 전체를 뷰어 기록 폴더로 사용하지 않습니다.');
      if ((await stat(root)).isDirectory()) roots.add(root);
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  return [...roots];
}

function validState(state) {
  return state?.service === SERVICE && Number.isInteger(state.pid) && state.pid > 0 && typeof state.instance === 'string' && /^[a-f0-9-]{36}$/.test(state.instance) && (state.url === null || /^http:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(state.url));
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code !== 'ESRCH'; }
}

async function probe(state) {
  if (!validState(state) || !state.url || !processAlive(state.pid)) return false;
  try {
    const response = await fetch(`${state.url}/api/viewer-health`, { headers: { 'x-taskweave-instance': state.instance }, signal: AbortSignal.timeout(500), redirect: 'error' });
    const result = await response.json();
    return response.ok && result.service === SERVICE && result.instance === state.instance;
  } catch { return false; }
}

async function serviceProcessIdentity(pid) {
  if (process.platform === 'win32') return null;
  try {
    const options = { timeout: 2000, maxBuffer: 64 * 1024 };
    const command = (await execute('ps', ['-p', String(pid), '-o', 'command='], options)).stdout.trim();
    const started = (await execute('ps', ['-p', String(pid), '-o', 'lstart='], options)).stdout.trim();
    return command && started ? { command, started } : null;
  } catch { return null; }
}

export async function stopOwnedViewer({ store, expectedState, timeoutMs = 3000, inspectProcess = serviceProcessIdentity, signal = (pid, name) => process.kill(pid, name), alive = processAlive, health = probe }) {
  const directory = path.join(store.dataRoot, 'viewer');
  const stateFile = path.join(directory, 'service.json');
  try {
    await requireWithin(store.dataRoot, stateFile, { allowMissing: true });
    for (const file of [store.dataRoot, directory, stateFile]) {
      try { if ((await lstat(file)).isSymbolicLink()) return { status: 'preserved', reason: 'service-state-symlink' }; }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    if (!await readJSON(stateFile)) return { status: 'absent' };
    return await withLock(path.join(directory, 'startup.lock'), async () => {
      const state = await readJSON(stateFile);
      if (!state) return { status: 'absent' };
      if (expectedState !== undefined && JSON.stringify(expectedState) !== JSON.stringify(state)) return { status: 'preserved', reason: 'service-changed-after-inspection' };
      if (!validState(state)) return { status: 'preserved', reason: 'invalid-service-state' };
      if (!alive(state.pid)) return { status: 'absent', reason: 'process-not-running' };
      const recorded = state.processIdentity;
      if (!recorded || typeof recorded.command !== 'string' || !recorded.command.includes(' --service') || typeof recorded.script !== 'string' || !path.isAbsolute(recorded.script) || !recorded.script.endsWith(`${path.sep}src${path.sep}viewer${path.sep}lifecycle.mjs`) || !recorded.command.includes(recorded.script) || !recorded.started) return { status: 'preserved', reason: 'process-identity-unknown' };
      const matches = identity => identity && identity.command === recorded.command && identity.started === recorded.started;
      if (!matches(await inspectProcess(state.pid)) || !await health(state)) return { status: 'preserved', reason: 'process-or-health-mismatch' };
      const current = await readJSON(stateFile);
      if (JSON.stringify(current) !== JSON.stringify(state) || !matches(await inspectProcess(state.pid))) return { status: 'preserved', reason: 'process-or-state-changed' };
      signal(state.pid, 'SIGTERM');
      const deadline = Date.now() + timeoutMs;
      while (alive(state.pid) && Date.now() < deadline) await pause(Math.min(50, timeoutMs));
      if (alive(state.pid)) return { status: 'preserved', reason: 'stop-timeout' };
      if ((await readJSON(stateFile))?.instance === state.instance) await unlink(stateFile);
      return { status: 'stopped', pid: state.pid };
    });
  } catch (error) { return { status: 'preserved', reason: 'service-state-or-stop-unverifiable', code: error.code ?? error.name }; }
}

export async function openViewerBrowser(url) {
  if (!/^http:\/\/127\.0\.0\.1:[1-9][0-9]{0,4}$/.test(url)) throw new Error('로컬 뷰어 주소만 열 수 있습니다.');
  const command = process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'rundll32.exe' : 'xdg-open';
  const args = process.platform === 'win32' ? ['url.dll,FileProtocolHandler', url] : [url];
  await execute(command, args, { timeout: 5000, windowsHide: true });
}

// 공용 잠금 안에서 서버를 만든 쪽만 브라우저를 연다. 다른 호스트는 같은 서버를 재사용한다.
export async function runManagedViewer({ store, port = 4317, openBrowser = openViewerBrowser, onWarning = message => process.stderr.write(`${message}\n`) }) {
  const files = await runtimeFiles(store);
  return withLock(files.lock, async () => {
    const previous = await readJSON(files.state);
    if (previous && !validState(previous)) throw new Error('뷰어 실행 기록 형식을 확인해 주세요.');
    if (await probe(previous)) return null;
    if (previous && processAlive(previous.pid)) throw new Error('기존 뷰어가 응답하지 않습니다. 중복 실행하지 않았습니다.');
    const identity = process.argv.includes('--service') && process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url) ? await serviceProcessIdentity(process.pid) : null;
    const state = { service: SERVICE, pid: process.pid, instance: randomUUID(), url: null, ...(identity ? { processIdentity: { ...identity, script: fileURLToPath(import.meta.url) } } : {}) };
    await atomicJSON(files.state, state);
    let viewer;
    const clear = async () => { if ((await readJSON(files.state))?.instance === state.instance) await unlink(files.state); };
    try {
      const roots = await resolveViewerRoots(store);
      try { viewer = await startViewer({ roots, port, instance: state.instance }); }
      catch (error) {
        // 다른 프로그램의 포트를 빼앗지 않는다. 새 주소는 공용 실행 기록에 저장한다.
        if (error.code !== 'EADDRINUSE') throw error;
        viewer = await startViewer({ roots, port: 0, instance: state.instance });
      }
      state.url = viewer.url;
      state.roots = roots;
      state.browserOpened = false;
      await atomicJSON(files.state, state);
      try { await openBrowser(viewer.url); state.browserOpened = true; }
      catch { onWarning(`${PRODUCT_NAME} 뷰어는 실행 중이지만 브라우저를 열지 못했습니다: ${viewer.url}`); }
      await atomicJSON(files.state, state);
      return { ...viewer, state, close: async () => { await new Promise(resolve => viewer.server.close(resolve)); await clear(); } };
    } catch (error) { if (viewer) await new Promise(resolve => viewer.server.close(resolve)); await clear(); throw error; }
  });
}

async function spawnService({ store, files }) {
  const log = await open(files.log, 'a', 0o600);
  try {
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--service'], { detached: true, stdio: ['ignore', 'ignore', log.fd], windowsHide: true, env: { ...process.env, AI_WORKFLOW_CONFIG: store.configPath, AI_WORKFLOW_DATA_ROOT: store.dataRoot } });
    await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
    child.unref();
  } finally { await log.close(); }
}

export async function ensureViewer({ store, launch = spawnService, timeoutMs = 15000 }) {
  const files = await runtimeFiles(store);
  const previous = await readJSON(files.state);
  if (previous && !validState(previous)) throw new Error('뷰어 실행 기록 형식을 확인해 주세요.');
  if (await probe(previous)) return { url: previous.url, reused: true };
  if (!previous || !processAlive(previous.pid)) await launch({ store, files });
  const deadline = Date.now() + timeoutMs;
  do {
    const current = await readJSON(files.state);
    if (await probe(current)) return { url: current.url, reused: false };
    await pause(100);
  } while (Date.now() < deadline);
  throw new Error(`뷰어 자동 실행을 확인하지 못했습니다. 기록은 보존되며 ${files.log}에서 원인을 확인할 수 있습니다.`);
}

const entry = process.argv[1] ? await realpath(process.argv[1]).catch(() => null) : null;
if (entry && import.meta.url === pathToFileURL(entry).href && process.argv.includes('--service')) {
  const store = new SettingsStore({ configPath: process.env.AI_WORKFLOW_CONFIG, dataRoot: process.env.AI_WORKFLOW_DATA_ROOT });
  runManagedViewer({ store }).then(viewer => {
    if (!viewer) return;
    const stop = () => viewer.close().finally(() => process.exit(0));
    process.once('SIGTERM', stop); process.once('SIGINT', stop);
  }).catch(error => { process.stderr.write(`${PRODUCT_NAME} 뷰어 자동 실행: ${error.message}\n`); process.exitCode = 1; });
}
