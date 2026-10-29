import path from 'node:path';
import { createHash } from 'node:crypto';
import { promises as fs, constants } from 'node:fs';
import { parseDocument } from 'yaml';
import { statusGroup } from './public/status.mjs';

const SUPPORTED = new Set(['.md', '.html', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg']);
const AUXILIARY = /^(completion|detail|details|readme|changelog|verification|test-results?)\.md$/i;
const IGNORED = new Set(['node_modules', '.git']);
export const viewerError = (status, message) => Object.assign(new Error(message), { status });
const inside = (root, file) => { const rel = path.relative(root, file); return rel === '' || (!rel.startsWith(`..${path.sep}`) && rel !== '..' && !path.isAbsolute(rel)); };
const idFor = file => createHash('sha256').update(file).digest('hex').slice(0, 24);
const normalize = value => String(value).normalize('NFKC').toLocaleLowerCase();

export function parseMetadata(source) {
  const warnings = [];
  const match = source.match(/^\uFEFF?---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
  if (!match) return { metadata: {}, body: source, warnings };
  try {
    const doc = parseDocument(match[1], { uniqueKeys: true });
    if (doc.errors.length) throw new Error(doc.errors[0].message);
    const metadata = doc.toJS({ maxAliasCount: 30 });
    if (!metadata || typeof metadata !== 'object' || Array.isArray(metadata)) throw new Error('필드 객체가 아닙니다.');
    return { metadata, body: source.slice(match[0].length), warnings: doc.warnings.map(w => `메타데이터: ${w.message}`) };
  } catch (error) { warnings.push(`메타데이터를 읽지 못했습니다: ${error.message}`); return { metadata: {}, body: source, warnings }; }
}

export async function createCatalog({ roots, projectBindings = [], projectAliases = {}, maxFiles = 5000, maxBytes = 2 * 1024 * 1024 } = {}) {
  if (!Array.isArray(roots) || !roots.length) throw viewerError(400, '--root 폴더를 하나 이상 지정하세요.');
  const allowedRoots = [];
  for (const root of roots) {
    if (!path.isAbsolute(root)) throw viewerError(400, '기록 폴더는 절대경로로 지정하세요.');
    const actual = await fs.realpath(root);
    if (!(await fs.stat(actual)).isDirectory()) throw viewerError(400, '기록 폴더가 아닙니다.');
    if (!allowedRoots.includes(actual)) allowedRoots.push(actual);
  }
  let refs = new Map(); let entries = []; let warnings = []; let refreshing;
  async function readReference(ref) {
    const actual = await fs.realpath(ref.path).catch(() => { throw viewerError(404, '자료가 없어졌습니다. 새로 읽어 주세요.'); });
    if (!allowedRoots.some(root => inside(root, actual))) throw viewerError(403, '허용한 기록 폴더 밖의 자료입니다.');
    const before = await fs.stat(actual);
    if (!before.isFile() || before.size > maxBytes) throw viewerError(413, '자료가 파일 크기 제한을 넘었습니다.');
    const handle = await fs.open(actual, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      // 경로 확인과 open 사이에 파일·상위 폴더가 바뀌면 읽기 전에 거절한다.
      const opened = await handle.stat(); const current = await fs.realpath(ref.path);
      if (current !== actual || opened.ino !== before.ino || opened.dev !== before.dev) throw viewerError(403, '자료 경로가 변경되었습니다. 새로 읽어 주세요.');
      const buffer = Buffer.alloc(Math.min(maxBytes + 1, opened.size + 1));
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
      if (bytesRead > maxBytes) throw viewerError(413, '자료가 파일 크기 제한을 넘었습니다.');
      return { bytes: buffer.subarray(0, bytesRead), mtime: opened.mtime.toISOString() };
    } finally { await handle.close(); }
  }
  function resolveLink(sourceId, href, image = false) {
    if (typeof href !== 'string' || !href || /[\u0000-\u001f]/.test(href)) return null;
    if (href.startsWith('#')) return image ? null : href;
    if (/^https?:\/\//i.test(href)) return image ? null : href;
    if (/^[a-z][a-z\d+.-]*:/i.test(href) || href.startsWith('//')) return null;
    const source = refs.get(sourceId); if (!source) return null;
    let decoded; try { decoded = decodeURIComponent(href.split(/[?#]/)[0]); } catch { return null; }
    const targetPath = path.resolve(path.dirname(source.path), decoded);
    const target = [...refs.values()].find(ref => ref.path === targetPath);
    if (!target || (image && !['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg'].includes(target.ext))) return null;
    const fragment = href.includes('#') ? `#${encodeURIComponent(href.slice(href.indexOf('#') + 1))}` : '';
    return `${target.ext === '.md' ? '/document/' : '/assets/'}${target.id}${fragment}`;
  }
  async function doRefresh() {
    const nextRefs = new Map(); const nextWarnings = []; const seen = new Set(); const auxiliaryQueue = []; let visited = 0;
    async function scan(dir, root, auxiliary = false) {
      let children; try { children = await fs.readdir(dir, { withFileTypes: true }); } catch { nextWarnings.push(`폴더를 읽지 못했습니다: ${path.relative(root, dir)}`); return; }
      children.sort((a,b) => a.name.localeCompare(b.name));
      for (const child of children) {
        if (child.name.startsWith('.') || IGNORED.has(child.name)) continue;
        if (++visited > maxFiles) { if (!nextWarnings.includes('파일 수 제한으로 일부 자료를 읽지 않았습니다.')) nextWarnings.push('파일 수 제한으로 일부 자료를 읽지 않았습니다.'); return; }
        const file = path.join(dir, child.name);
        if (child.isDirectory()) {
          if (!auxiliary && /^(details?|artifacts)$/i.test(child.name)) auxiliaryQueue.push({file,root});
          else await scan(file, root, auxiliary);
          continue;
        }
        const ext = path.extname(child.name).toLowerCase(); if (!SUPPORTED.has(ext)) continue;
        try {
          const actual = await fs.realpath(file);
          if (!inside(root, actual)) { nextWarnings.push(`폴더 밖 링크 제외: ${path.relative(root,file)}`); continue; }
          if (seen.has(actual)) continue;
          const stat = await fs.stat(actual);
          if (!stat.isFile() || stat.size > maxBytes) { nextWarnings.push(`크기 제한으로 제외: ${path.relative(root,file)}`); continue; }
          seen.add(actual);
          const ref = { id: idFor(actual), path: file, root, ext, auxiliary, name: path.relative(root, file) };
          nextRefs.set(ref.id, ref);
        } catch { nextWarnings.push(`자료를 읽지 못했습니다: ${path.relative(root,file)}`); }
      }
    }
    for (const root of allowedRoots) await scan(root, root);
    // 큰 첨부 폴더가 뒤의 프로젝트·다른 root의 본문 탐색 예산을 먼저 소진하지 않게 한다.
    for (const {file,root} of auxiliaryQueue) await scan(file,root,true);
    const nextEntries = [];
    for (const ref of nextRefs.values()) {
      if (ref.ext !== '.md' || ref.auxiliary || AUXILIARY.test(path.basename(ref.path))) continue;
      try {
        const { bytes, mtime } = await readReference(ref); const text = bytes.toString('utf8');
        const parsed = parseMetadata(text); const m = parsed.metadata;
        const bindings = projectBindings.filter(item => inside(item.root, ref.path));
        const connectedProject = bindings.length === 1 ? bindings[0].projectId : null;
        const matchedName = path.basename(ref.path, '.md') === path.basename(path.dirname(ref.path));
        const recognized = m.workplan_schema || m.plan_schema || m.project_id || m.id || (m.title && (m.status || m.type));
        if (!matchedName && !recognized) { nextWarnings.push(`분류하지 못한 문서: ${ref.name}`); continue; }
        const scalar = value => ['string','number'].includes(typeof value) ? String(value) : null;
        const jiraKeys = [...new Set([
          ...(Array.isArray(m.jira_keys) ? m.jira_keys.filter(value => typeof value === 'string').map(value => value.trim()).filter(Boolean) : []),
          ...[m.jira, m.jira_key, m.ticket].map(scalar).filter(Boolean),
        ])];
        const updated = scalar(m.updated ?? m.updated_at ?? m.created ?? m.created_at);
        const validDate = updated && Number.isFinite(Date.parse(updated));
        const entry = { id: ref.id, title: scalar(m.title) || parsed.body.match(/^#\s+(.+)$/m)?.[1] || path.basename(ref.path,'.md'), project: scalar(m.project_id ?? m.project) || path.basename(ref.root), status: scalar(m.status), jira: jiraKeys.join(', ') || null, updatedAt: validDate ? new Date(updated).toISOString() : mtime, displayDate: validDate ? updated : mtime, dateSource: validDate ? 'metadata' : 'document-mtime', documents: [], warnings: parsed.warnings, searchText: normalize(text) };
        entry.project = connectedProject ?? projectAliases[entry.project] ?? entry.project;
        nextEntries.push(entry);
      } catch (error) { nextWarnings.push(`${ref.name}: ${error.message}`); }
    }
    refs = nextRefs;
    // 본문 연결과 같은 작업 폴더의 상세·완료 문서는 작업 수에 더하지 않는다.
    for (const entry of nextEntries) {
      const main = refs.get(entry.id); const linked = new Set([entry.id]); const queue = [entry.id];
      for (const ref of refs.values()) if (ref.id !== entry.id && path.dirname(main.path) !== main.root && inside(path.dirname(main.path), ref.path) && !nextEntries.some(e => e.id === ref.id)) { linked.add(ref.id); if (ref.ext === '.md' || ref.ext === '.html') queue.push(ref.id); }
      let search = entry.searchText;
      for (let i = 0; i < queue.length; i++) {
        const ref = refs.get(queue[i]); if (!['.md','.html'].includes(ref.ext)) continue;
        try {
          const { bytes } = await readReference(ref); const source = bytes.toString('utf8');
          if (ref.ext === '.md' && ref.id !== entry.id) search += `\n${normalize(source)}`;
          const links = ref.ext === '.md' ? [...source.matchAll(/!?\[[^\]]*\]\((?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)/g)].map(m => m[1] || m[2]) : [...source.matchAll(/(?:href|src)\s*=\s*["']([^"']+)["']/gi)].map(m => m[1]);
          for (const href of links) {
            const resolved = resolveLink(ref.id, href); const target = resolved?.match(/^\/(?:document|assets)\/([a-f0-9]{24})/);
            if (target && !linked.has(target[1])) { linked.add(target[1]); queue.push(target[1]); }
            else if (!resolved && !/^(https?:|#)/i.test(href)) entry.warnings.push(`연결할 수 없는 자료: ${href}`);
          }
        } catch (error) { entry.warnings.push(`${ref.name}: ${error.message}`); }
      }
      entry.searchText = search;
      entry.documents = [...linked].map(id => { const ref = refs.get(id); return { id, name: ref.name, kind: ref.ext === '.md' ? 'markdown' : ref.ext === '.html' ? 'flow' : 'image', main: id === entry.id }; });
    }
    entries = nextEntries.sort((a,b) => b.updatedAt.localeCompare(a.updatedAt)); warnings = nextWarnings;
    return { total: entries.length, warnings: [...warnings] };
  }
  const refresh = () => refreshing ??= doRefresh().finally(() => { refreshing = null; });
  function list(query = {}) {
    const page = Math.max(1, Math.min(100000, Number.parseInt(query.page,10) || 1));
    for (const key of ['from','to']) if (query[key] && !/^\d{4}-\d{2}-\d{2}$/.test(query[key])) throw viewerError(400, '기간은 YYYY-MM-DD 형식이어야 합니다.');
    const words = normalize(query.q || '').split(/\s+/).filter(Boolean);
    const result = entries.filter(e => words.every(w => e.searchText.includes(w)) && (!query.group || statusGroup(e.status) === query.group) && (!query.project || e.project === query.project) && (!query.status || (query.status === '__missing__' ? e.status === null : e.status === query.status)) && (!query.from || e.updatedAt.slice(0,10) >= query.from) && (!query.to || e.updatedAt.slice(0,10) <= query.to));
    return { items: result.slice((page-1)*20,page*20).map(({ searchText, documents, ...e }) => e), total: result.length, page, hasMore: page*20 < result.length, projects: [...new Set(entries.map(e => e.project))].sort(), statuses: [...new Set(entries.map(e => e.status).filter(Boolean))].sort(), warnings: [...warnings], indexed: entries.length };
  }
  function overview() {
    const counts = { active: 0, review: 0, done: 0, other: 0 };
    const projects = new Map();
    for (const entry of entries) {
      counts[statusGroup(entry.status)]++;
      projects.set(entry.project, (projects.get(entry.project) || 0) + 1);
    }
    return {
      total: entries.length,
      counts,
      projects: [...projects].sort(([a], [b]) => a.localeCompare(b)).map(([name, count]) => ({ name, count })),
      recent: entries.slice(0, 3).map(({ searchText, documents, ...entry }) => entry),
      warnings: [...warnings],
    };
  }
  async function readDocument(id) { const ref = refs.get(id); if (!ref || ref.ext !== '.md') throw viewerError(404, '등록된 문서가 아닙니다.'); const { bytes } = await readReference(ref); const sourceText = bytes.toString('utf8'); return { id, name: ref.name, sourceText, ...parseMetadata(sourceText) }; }
  async function readAsset(id) {
    const ref = refs.get(id); if (!ref || ref.ext === '.md') throw viewerError(404, '등록된 첨부가 아닙니다.');
    const owners = ref.ext === '.html' ? entries.filter(entry => entry.documents.some(document => document.id === id)) : [];
    // 공유 첨부에는 어느 작업의 제목도 임의로 적용하지 않는다.
    return { ...ref, ...(await readReference(ref)), title: owners.length === 1 ? owners[0].title : null };
  }
  async function readWorkplan(id) { const entry = entries.find(e => e.id === id); if (!entry) throw viewerError(404, '작업을 찾지 못했습니다.'); const { searchText, ...safe } = entry; return { ...safe, document: await readDocument(id) }; }
  return { refresh, list, overview, readDocument, readWorkplan, readAsset, resolveLink };
}
