// 호스트가 제공한 관찰만 관리한다. 서버가 실제 인증·접근을 보증하거나 호스트 간 인증값을 공유하지 않는다.
export const INTEGRATION_CLIENTS = ['codex', 'claude'];
export const PROVIDERS = ['serena', 'figma', 'jira'];
export const CONNECTION_STATES = ['unknown', 'registered', 'login_required', 'tool_available', 'read_verified', 'access_denied', 'policy_blocked', 'unavailable'];

const keys = (value, allowed) => {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !allowed.includes(key))) throw new Error('연동 입력에 허용하지 않은 필드가 있습니다');
};

export function safeReference(value) {
  if (typeof value !== 'string' || !value.trim() || value.length > 300 || /[\r\n\0]|Bearer\s|\b(?:token|password|secret|api[_-]?key)\s*[:=]|gh[pousr]_|sk-[A-Za-z0-9]|-----BEGIN/i.test(value)) throw new Error('비밀 아닌 연결 참조만 사용할 수 있습니다');
  if (/^https?:\/\//i.test(value)) {
    const url = new URL(value);
    if (url.username || url.password || url.search || url.hash) throw new Error('인증값·query 없는 연결 참조가 필요합니다');
  }
  return value;
}

export function validateObservation(value) {
  keys(value, ['client', 'provider', 'state', 'connectionRef', 'serverRef', 'siteRef', 'accountRef', 'capabilities', 'resourceRef', 'evidenceRef', 'projectId']);
  if (!INTEGRATION_CLIENTS.includes(value.client) || !PROVIDERS.includes(value.provider) || !CONNECTION_STATES.includes(value.state)) throw new Error('호스트·연동·상태가 잘못되었습니다');
  for (const name of ['connectionRef', 'serverRef', 'siteRef', 'accountRef', 'resourceRef', 'evidenceRef', 'projectId']) if (value[name] !== undefined) safeReference(value[name]);
  if (value.capabilities !== undefined && (!Array.isArray(value.capabilities) || value.capabilities.length > 30 || value.capabilities.some(item => !/^[a-zA-Z0-9._:/-]{1,100}$/.test(item)))) throw new Error('확인한 읽기 기능 이름만 저장하세요');
  if (value.capabilities?.some(item => /(?:^|[._:/-])(?:write|create|update|delete|edit|transition|assign|remove|install)(?:$|[._:/-])/i.test(item))) throw new Error('외부 쓰기 기능은 읽기 확인으로 기록할 수 없습니다');
  if (value.state === 'read_verified' && (!value.connectionRef || !value.resourceRef || !value.evidenceRef || !value.capabilities?.length)) throw new Error('실제 선택 자료 읽기 근거·연결·기능이 필요합니다');
  return { ...value, ...(value.capabilities ? { capabilities: [...value.capabilities] } : {}) };
}

const guides = {
  codex: 'https://developers.openai.com/plugins/build/auth',
  claude: 'https://code.claude.com/docs/en/mcp',
};

export class IntegrationService {
  constructor({ store }) { this.store = store; }

  async status() {
    const settings = await this.store.load();
    return { connections: settings.integrations ?? {}, legacyServicesAreNotHostVerification: true, historicalReadIsNotCurrentAuthentication: true };
  }

  async plan({ clients, providers, hostObservations = [] }) {
    if (!Array.isArray(clients) || !clients.length || clients.some(client => !INTEGRATION_CLIENTS.includes(client))) throw new Error('대상 호스트를 선택하세요');
    if (!Array.isArray(providers) || providers.some(provider => !PROVIDERS.includes(provider))) throw new Error('지원하는 연동을 선택하세요');
    if (!Array.isArray(hostObservations) || hostObservations.length > 100) throw new Error('호스트 관찰 정보가 잘못되었습니다');
    const observations = hostObservations.map(validateObservation);
    const { connections } = await this.status();
    const items = [];
    for (const client of new Set(clients)) for (const provider of new Set(providers)) {
      const candidates = observations.filter(item => item.client === client && item.provider === provider);
      const previous = connections[client]?.[provider];
      const groups = new Map();
      for (const item of candidates) {
        const identity = JSON.stringify([(item.serverRef ?? item.connectionRef)?.replace(/\/$/, ''), item.siteRef, item.accountRef]);
        const group = groups.get(identity) ?? [];
        group.push(item);
        groups.set(identity, group);
      }
      const unique = [...groups.values()].map(group => group.at(-1));
      // 같은 연결의 상충 관찰은 입력 순서와 무관하게 재확인하며 성공으로 덮지 않는다.
      const conflicting = [...groups.values()].some(group => new Set(group.map(item => item.state)).size > 1);
      const observed = unique.length === 1 && !conflicting ? unique[0] : null;
      const state = observed?.state ?? 'unknown';
      let action = 'inspect_host';
      if (conflicting) action = 'recheck_connection';
      else if (!unique.length && previous?.state === 'read_verified') action = 'reuse_previous_read';
      else if (unique.length > 1) action = 'choose_connection';
      else if (state === 'read_verified') action = 'reuse';
      else if (state === 'policy_blocked') action = 'resolve_policy';
      else if (state === 'access_denied') action = 'choose_authorized_resource';
      else if (state === 'login_required') action = 'host_login';
      else if (state === 'registered' || state === 'tool_available') action = 'verify_read';
      else if (state === 'unavailable') action = provider === 'serena' ? 'configure_serena' : 'host_connect';
      items.push({ client, provider, state, action, ...(observed ? { observation: observed } : {}), ...(previous ? { previousVerification: previous, historicalOnly: true, currentAuthenticationUnverified: !observed } : {}), ...(unique.length > 1 ? { choices: unique } : {}), ...(conflicting ? { conflictingObservations: candidates } : {}), changesSettings: action === 'configure_serena', ...(action === 'host_login' || action === 'host_connect' ? { handoff: { host: client, guide: guides[client], provider, loginInHostOnly: true, requiresFreshSession: true } } : {}) });
    }
    // 재설정할 항목이 없어도 과거 읽기 기록만으로 현재 인증 완료를 표시하지 않는다.
    const unverified = items.filter(item => item.action !== 'reuse' || item.state !== 'read_verified');
    return { items, pending: items.filter(item => !['reuse', 'reuse_previous_read'].includes(item.action)), unverified, currentReady: unverified.length === 0, changes: items.filter(item => item.changesSettings), executesAuthentication: false, storesCredentials: false, requiresConfirmation: true };
  }

  async record(input) { return this.store.recordIntegration(input); }
}
