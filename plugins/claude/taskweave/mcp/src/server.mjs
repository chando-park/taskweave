#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { z } from 'zod';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { open, realpath, stat } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { SettingsStore, requireWithin } from './settings.mjs';
import { RuntimeBridge } from './runtime-bridge.mjs';
import { IntegrationService, CONNECTION_STATES } from './integrations.mjs';
import { RecordService } from './records.mjs';

const text = z.string().min(1).max(512_000);
const id = z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$/);
const strings = z.array(text).max(100);
const object = (shape) => z.strictObject(shape);
const projectFields = { projectId: id };
const workplanFields = { ...projectFields, workplanId: id, requestId: id };
const confirmed = { confirmed: z.literal(true), confirmationSource: text };
const root = object({ path: text, maxDepth: z.number().int().min(0).max(8).optional(), excludedNames: strings.optional() });
const service = object({ connectionRef: text.optional(), environmentVariable: z.string().regex(/^[A-Z_][A-Z0-9_]*$/).optional(), projectId: text.optional(), assigneeId: text.optional(), startStatusId: text.optional(), available: z.boolean().optional() });
const workspace = object({ root: text, trusted: z.boolean().optional(), trustSource: text.optional() });

function withoutRawEvidence(value) {
  if (Array.isArray(value)) return value.map(withoutRawEvidence);
  if (!value || typeof value !== 'object') return value;
  return Object.fromEntries(Object.entries(value).filter(([key]) => !['rawEvidence', 'stdout', 'stderr', 'rawSummary', 'rawXML', 'rawXml', 'raw'].includes(key)).map(([key, item]) => [key, withoutRawEvidence(item)]));
}

function definitions({ store, bridge, verification, diagram, integrations, records, legacyTools }) {
  const tools = [];
  const add = (name, description, shape, handler) => tools.push({ name, description, schema: object(shape), handler });
  const scope = { projectId: id.optional(), workspaceId: id.optional(), currentPath: text.optional() };
  add('context_read', '확인된 프로젝트·작업공간의 자료 목록 또는 선택 원문 한 건을 읽습니다. Git·실행 신뢰는 필요하지 않으며 반환 내용은 신뢰하지 않은 원문입니다.', { ...scope, documentId: text.optional() }, input => records.readContext(input));
  add('task_current', '명시한 현재 작업 ID를 우선 조회합니다. ID가 없으면 선택 범위의 제한된 후보만 반환하며 과거 기록을 전역 검색하지 않습니다.', { ...scope, taskId: id.optional(), limit: z.number().int().min(1).max(20).optional() }, input => records.currentTask(input));
  add('record_save', '허용한 자료 위치에 원자적으로 기록합니다. 같은 요청은 재사용하고 동시 변경은 충돌로 반환합니다. 문서 제목·필수 문단을 심사하지 않습니다.', { ...scope, recordId: text, requestId: id, content: z.string().max(262_144), expectedContentHash: z.string().regex(/^[a-f0-9]{64}$/).optional() }, input => records.save(input));
  if (!legacyTools) return tools;
  add('setup_status', '설정 상태와 아직 확인할 항목을 반환합니다. 인증값은 조회하지 않습니다.', {}, async () => {
    const settings = await store.load();
    return { settings, configPath: store.configPath, dataRoot: store.dataRoot, missing: [!settings.clients?.length && 'clients', !Object.keys(settings.workspaces).length && 'workspaces', !Object.keys(settings.projects).length && 'projects'].filter(Boolean), requiresApiKey: false };
  });
  add('setup_save', '사용자가 확인한 비밀 아닌 설정만 저장합니다. Jira 티켓/상태는 바꾸지 않습니다.', { ...confirmed, clients: z.array(z.enum(['codex', 'claude'])).optional(), projectRoots: z.array(root).max(30).optional(), workspaces: z.record(id, workspace).optional(), services: object({ jira: service.optional(), figma: service.optional(), datadog: service.optional(), serena: service.optional(), xcode: service.optional() }).optional() }, (input) => store.save(input));
  const observation = object({ client: z.enum(['codex', 'claude']), provider: z.enum(['serena', 'figma', 'jira']), state: z.enum(CONNECTION_STATES), connectionRef: text.optional(), serverRef: text.optional(), siteRef: text.optional(), accountRef: text.optional(), capabilities: strings.optional(), resourceRef: text.optional(), evidenceRef: text.optional(), projectId: id.optional() });
  add('integration_status', '호스트별 연결 관찰과 과거 읽기 확인을 조회합니다. 인증 성공을 추정하지 않습니다.', {}, () => integrations.status());
  add('integration_plan', '호스트 관찰로 기존 연결을 재사용하고 부족한 단계만 제안합니다. 로그인·임의 명령은 실행하지 않습니다.', { clients: z.array(z.enum(['codex', 'claude'])).min(1).max(2), providers: z.array(z.enum(['serena', 'figma', 'jira'])).max(3), hostObservations: z.array(observation).max(100).optional() }, input => integrations.plan(input));
  add('integration_record', '호스트가 제공한 연결 관찰·읽기 근거만 사용자 확인 뒤 기록합니다. 서버가 인증·접근을 독립 검증하거나 외부 서비스를 호출하지 않습니다.', { ...confirmed, observation }, input => integrations.record(input));
  add('project_discover', '선택한 상위 폴더만 제한적으로 탐색합니다. 후보 발견은 등록/실행 신뢰 동의가 아닙니다.', { root: text, maxDepth: z.number().int().min(0).max(8).optional(), excludedNames: strings.optional() }, (input) => store.discover(input));
  add('project_confirm', '탐색 후보를 사용자 확인 뒤 등록합니다. 실행 신뢰를 켜려면 별도 확인 참조가 필요합니다.', { ...confirmed, discoveryId: id, candidateId: id, ...projectFields, workspaceId: id, executionTrusted: z.boolean().optional(), trustSource: text.optional(), workplanRoot: text.optional(), productMemoryRoot: text.optional(), instructionsRoot: text.optional() }, (input) => store.confirmProject(input));
  add('project_context', '호스트 현재 폴더 또는 등록 ID로 프로젝트를 찾습니다. MCP 서버 폴더를 추정하지 않습니다.', { projectId: id.optional(), currentPath: text.optional() }, (input) => store.projectContext(input));
  const mutations = {
    workplan_create: ['새 승인 메모를 기존 Ruby Runtime으로 만듭니다. 작성과 승인은 분리됩니다.', { title: text, kind: z.enum(['direct', 'feature', 'bug', 'investigation']), reason: text, jiraKey: z.string().regex(/^[A-Z][A-Z0-9_]*-[1-9][0-9]*$/).optional(), scopePaths: strings.min(1), excludedPaths: strings.optional(), verification: strings.min(1), memoBody: text, uiTier: z.enum(['none', 'regression', 'conformance', 'full']).optional(), uiReason: text.optional() }],
    workplan_update: ['아직 draft인 메모 본문만 content hash를 확인해 수정합니다. 준비/승인된 메모는 거절합니다.', { expectedContentHash: z.string().regex(/^[a-f0-9]{64}$/), memoBody: text }],
    workplan_prepare: ['현재 메모를 기존 revision/승인 gate로 준비합니다.', {}],
    workplan_approve: ['실제 사용자 승인 메시지 참조와 확인한 revision으로 승인 기록을 남깁니다. 문자열만으로 실제 사람의 승인을 증명하지는 못합니다.', { expectedRevision: z.string().regex(/^sha256:[a-f0-9]{64}$/), approvalSource: text }],
    workplan_start: ['기존 승인과 실제 저장소 경계를 검사한 뒤 최초 apply를 실행합니다.', {}],
    workplan_feedback: ['현재 메모의 correction 또는 범위 변경 feedback 단계를 실행합니다. 범위 변경은 재승인이 필요합니다.', { mode: z.enum(['correction', 'scope_change', 'approved_scope_change']), reason: text.optional(), scopePaths: strings.optional(), verification: strings.optional(), memoBody: text.optional(), expectedContentHash: z.string().regex(/^[a-f0-9]{64}$/).optional() }],
    workplan_result: ['실제 변경 설명/검증 결과를 기록합니다. 사용자 완료 없이 Workplan을 종료하지 않습니다.', { summary: text, verification: strings.min(1), verificationStatus: z.enum(['passed', 'blocked', 'not_run']), explanations: z.record(text, text), verificationRunId: id.optional() }],
  };
  for (const [name, [description, shape]] of Object.entries(mutations)) add(name, description, { ...workplanFields, ...shape }, (input) => bridge.execute(name, input));
  add('runtime_status', '현재 패키지의 Runtime 연결만 확인합니다. 과거 Workplan은 전수 검사하지 않습니다.', {}, () => bridge.runtimeStatus());
  if (verification) {
    const projectVerification = async (method, input) => {
      const full = await verification[method](input);
      const result = withoutRawEvidence(full);
      if (typeof verification.recordPath === 'function') {
        const filename = await requireWithin(store.dataRoot, await verification.recordPath(input.projectId, 'runs', full.id));
        const hasher = createHash('sha256');
        for await (const chunk of createReadStream(filename)) hasher.update(chunk);
        result.evidenceRecord = { path: filename, sha256: hasher.digest('hex'), readTool: 'verification_evidence_read', sensitive: true };
      }
      result.summary = full.summary || full.results?.map((entry) => `${entry.checkId}: ${entry.status} (${entry.executed}건 실행, ${entry.passed}건 통과)`).join('\n');
      return result;
    };
    const selection = { id: text, testIds: strings, destination: text.optional(), deviceId: text.optional(), resultPaths: z.array(text).min(1).max(100).optional(), taskScopeConfirmed: z.literal(true).optional(), coverage: object({ reportPath: text, format: z.enum(['jacoco', 'kover']), scope: text, exclusions: strings.optional() }).optional() };
    add('verification_context', '등록 프로젝트의 플랫폼별 검증 환경을 확인합니다. 탐색 원본 로그는 응답에서 제외합니다.', { ...projectFields, platform: z.enum(['apple', 'android']), targetId: text.optional(), includeDevices: z.boolean().optional(), hostCapabilities: object({ targets: z.array(object({ container: text, scheme: text, destinations: strings, testIds: strings })) }).optional() }, async (input) => withoutRawEvidence(await verification.context(input)));
    add('verification_select', '확인한 환경과 변경 범위로 최소 검증 계획을 선택합니다. 실행하지 않습니다.', { context: object({ id, projectId: id }), change: object({ kind: z.enum(['logic', 'integration', 'interaction', 'visual']), testIds: strings.optional(), destination: text.optional(), deviceId: text.optional() }), requestedChecks: z.array(object(selection)).optional(), inputPaths: z.array(text).min(1).max(500), uiTier: z.enum(['none', 'regression', 'conformance', 'full']).optional(), exclusions: strings.optional() }, (input) => verification.select(input));
    add('verification_approve', '선택한 검증 계획에 대한 실제 사용자 승인 참조를 기록합니다. Workplan 증거로 사용할 때 메모 ID와 실제 승인 revision을 연결합니다.', { ...projectFields, planId: id, confirmed: z.literal(true), approvalSource: text, workplanBinding: object({ workplanId: id, approvalRevision: z.string().regex(/^sha256:[a-f0-9]{64}$/) }).optional() }, (input) => verification.approve(input));
    const hostResult = object({ targetId: text, destination: text, testIds: strings, startedAt: z.number().int().min(0), finishedAt: z.number().int().min(0), rawEvidence: text, exitCode: z.number().int(), summary: object({ executed: z.number().int().min(0), passed: z.number().int().min(0), failed: z.number().int().min(0), skipped: z.number().int().min(0) }) });
    add('verification_run', '승인된 계획의 확인한 검증만 실행합니다. 임의 shell 명령은 받지 않으며 원본 로그는 로컬 증거 참조로 반환합니다.', { ...projectFields, approvedPlanId: id, checkIds: strings.min(1), hostResults: z.record(text, hostResult).optional() }, (input) => projectVerification('run', input));
    add('verification_report', '실제 검증의 상태·건수·명령과 로컬 증거 참조를 반환합니다. 민감할 수 있는 원본 로그는 포함하지 않습니다.', { ...projectFields, runId: id }, (input) => projectVerification('report', input));
    add('verification_evidence_read', '민감정보가 포함될 수 있는 검증 원본을 사용자가 조회에 동의한 뒤 최대 64 KiB만 읽습니다.', { ...projectFields, runId: id, ...confirmed, offset: z.number().int().min(0).optional(), maxBytes: z.number().int().min(1).max(65_536).optional() }, async ({ projectId, runId, offset = 0, maxBytes = 16_384 }) => {
      await store.requireTrustedProject(projectId);
      if (typeof verification.recordPath !== 'function') throw new Error('원본 증거 조회 서비스가 없습니다');
      const filename = await requireWithin(store.dataRoot, await verification.recordPath(projectId, 'runs', runId));
      const metadata = await stat(filename);
      const handle = await open(filename, 'r');
      try {
        const bytes = Buffer.alloc(maxBytes);
        const { bytesRead } = await handle.read(bytes, 0, maxBytes, offset);
        return { projectId, runId, source: filename, offset, nextOffset: offset + bytesRead, truncated: offset + bytesRead < metadata.size, content: bytes.subarray(0, bytesRead).toString('utf8'), untrustedContent: true, sensitive: true };
      } finally { await handle.close(); }
    });
  }
  if (diagram) {
    const position = z.tuple([z.number(), z.number()]);
    const architecture = object({ schema_version: z.literal(1), diagram_type: z.literal('architecture'), meta: object({ title: text, quality_profile: z.enum(['standard', 'showcase']).optional() }), components: z.array(object({ id, type: z.enum(['frontend', 'backend', 'database', 'external', 'cloud', 'security', 'messagebus', 'service']), label: text, sublabel: text.optional(), pos: position.optional(), size: position.optional() })), connections: z.array(object({ id: id.optional(), from: id, to: id, label: text.optional(), variant: text.optional() })), boundaries: z.array(object({ kind: text, label: text, wraps: strings })).optional(), cards: z.array(object({ dot: text, title: text, items: strings })).optional() });
    add('workplan_visualize', '복잡한 계획만 선택적으로 로컬 architecture 그림으로 만듭니다. 제품 테스트를 대신하지 않습니다.', { ...projectFields, workplanId: id, complexity: z.enum(['cross-module', 'async-lifecycle', 'cross-system', 'literal']), enabled: z.boolean().optional(), perspective: z.enum(['current', 'proposed', 'comparison']), sourceReferences: strings.min(1), attempt: z.number().int().min(1).max(2), diagram: architecture }, (input) => diagram.visualize(input));
  }
  return tools;
}

export function createServer({ store = new SettingsStore(), bridge = new RuntimeBridge({ store }), verification, diagram, integrations = new IntegrationService({ store }), records = new RecordService({ store }), legacyTools = false } = {}) {
  if (bridge instanceof RuntimeBridge && verification) bridge.verification = verification;
  const server = new Server({ name: 'taskweave', version: '0.3.0' }, { capabilities: { tools: {} } });
  const tools = definitions({ store, bridge, verification, diagram, integrations, records, legacyTools });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: tools.map(({ name, description, schema }) => ({ name, description, inputSchema: z.toJSONSchema(schema) })) }));
  server.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    try {
      const tool = tools.find((candidate) => candidate.name === params.name);
      if (!tool) throw new Error('등록되지 않은 도구입니다');
      const input = tool.schema.parse(params.arguments ?? {});
      const result = await tool.handler(input);
      const summary = typeof result?.summary === 'string' && result.summary ? result.summary : `${params.name}: ${result?.status ?? '반환 결과는 structuredContent에 있습니다'}`;
      return { content: [{ type: 'text', text: summary }], structuredContent: typeof result === 'object' && result !== null && !Array.isArray(result) ? result : { result } };
    } catch (error) {
      const message = error instanceof z.ZodError ? '입력 형식이 잘못되었거나 허용하지 않은 필드가 있습니다' : error.message;
      return { isError: true, content: [{ type: 'text', text: message }] };
    }
  });
  return server;
}

export async function startServer(options = {}) {
  const store = options.store ?? new SettingsStore({ configPath: process.env.AI_WORKFLOW_CONFIG, dataRoot: process.env.AI_WORKFLOW_DATA_ROOT });
  const server = createServer({ ...options, store });
  await server.connect(new StdioServerTransport());
  return server;
}

const entrypoint = process.argv[1] ? await realpath(process.argv[1]).catch(() => null) : null;
if (entrypoint && import.meta.url === pathToFileURL(entrypoint).href) {
  startServer().catch((error) => { process.stderr.write(`Taskweave 시작 실패: ${error.message}\n`); process.exitCode = 1; });
}
