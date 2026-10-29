import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { renderSafeMarkdown, renderFlowHtml, renderDocumentPage } from './render.mjs';

const PUBLIC = new URL('./public/', import.meta.url);
const STATIC = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/app.mjs', ['app.mjs', 'text/javascript; charset=utf-8']],
  ['/status.mjs', ['status.mjs', 'text/javascript; charset=utf-8']],
  ['/documents.mjs', ['documents.mjs', 'text/javascript; charset=utf-8']],
  ['/dates.mjs', ['dates.mjs', 'text/javascript; charset=utf-8']],
  ['/styles.css', ['styles.css', 'text/css; charset=utf-8']],
  ['/logo.svg', ['logo.svg', 'image/svg+xml']],
  ['/wordmark.svg', ['wordmark.svg', 'image/svg+xml']],
  ['/icons.svg', ['icons.svg', 'image/svg+xml']],
]);
const MIME = { '.html':'text/html; charset=utf-8', '.png':'image/png', '.jpg':'image/jpeg', '.jpeg':'image/jpeg', '.gif':'image/gif', '.webp':'image/webp', '.svg':'image/svg+xml' };
const PAGE_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; frame-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'";
export function isLocalBrowserRequest(request) {
  const host = request.headers.host; const port = request.socket.localPort;
  if (host !== `127.0.0.1:${port}` && host !== `localhost:${port}`) return false;
  if (request.headers['sec-fetch-site'] === 'cross-site') return false;
  const origin = request.headers.origin;
  if (origin && origin !== `http://${host}`) return false;
  return true;
}
export function createViewerServer({ catalog, instance }) {
  return http.createServer(async (request,response) => {
    const send = (status, body, type = 'application/json; charset=utf-8', csp = PAGE_CSP) => {
      response.writeHead(status, { 'Content-Type':type, 'Cache-Control':'no-store', 'X-Content-Type-Options':'nosniff', 'Referrer-Policy':'no-referrer', 'Content-Security-Policy':csp, 'Permissions-Policy':'camera=(), microphone=(), geolocation=()' });
      response.end(type.startsWith('application/json') ? JSON.stringify(body) : body);
    };
    try {
      if (request.method !== 'GET') { response.setHeader('Allow','GET'); return send(405,{ error:'조회만 가능합니다.' }); }
      if (!isLocalBrowserRequest(request)) return send(403,{ error:'로컬 브라우저의 조회만 허용합니다.' });
      const url = new URL(request.url, `http://${request.headers.host}`);
      if (url.pathname === '/api/viewer-health') {
        const currentHeader = request.headers['x-cdpower-instance'];
        if (!instance || (currentHeader ?? request.headers['x-taskweave-instance']) !== instance) return send(404, { error: '자료를 찾지 못했습니다.' });
        return send(200, { service: currentHeader === undefined ? 'taskweave-viewer-v1' : 'cdpower-viewer-v1', instance });
      }
      if (STATIC.has(url.pathname)) { const [file,type] = STATIC.get(url.pathname); return send(200,await readFile(new URL(file,PUBLIC)),type); }
      if (url.pathname === '/api/overview') return send(200,catalog.overview());
      if (url.pathname === '/api/workplans') return send(200,catalog.list(Object.fromEntries(url.searchParams)));
      if (url.pathname === '/api/refresh') return send(200,await catalog.refresh());
      const match = url.pathname.match(/^\/(api\/workplans|api\/documents|document|assets)\/([a-f0-9]{24})$/);
      if (!match) return send(404,{error:'자료를 찾지 못했습니다.'});
      const [,route,id] = match;
      const rendered = async document => ({ ...document, html:renderSafeMarkdown(document.body, (href,image) => catalog.resolveLink(id,href,image)) });
      if (route === 'api/workplans') { const entry=await catalog.readWorkplan(id); return send(200,{...entry,document:await rendered(entry.document)}); }
      if (route === 'api/documents' || route === 'document') { const doc=await rendered(await catalog.readDocument(id)); return route === 'document' ? send(200,renderDocumentPage(doc,doc.html),'text/html; charset=utf-8') : send(200,doc); }
      const asset=await catalog.readAsset(id);
      const flowCsp = `sandbox allow-scripts; default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src http://${request.headers.host}/assets/ data:; connect-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'`;
      if (asset.ext === '.html') {
        const html = await renderFlowHtml(asset.bytes.toString('utf8'), (href,image) => catalog.resolveLink(id,href,image), async src => {
          const imageId = src.match(/^\/assets\/([a-f0-9]{24})(?:#.*)?$/)?.[1];
          if (!imageId) return null;
          const image = await catalog.readAsset(imageId);
          const type = MIME[image.ext];
          return type?.startsWith('image/') ? `data:${type};base64,${image.bytes.toString('base64')}` : null;
        }, asset.title);
        return send(200,html,MIME[asset.ext],flowCsp);
      }
      return send(200,asset.bytes,MIME[asset.ext],"sandbox; default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'self'");
    } catch (error) { return send(error.status || 500,{error:error.status ? error.message : '자료를 읽지 못했습니다. 새로 읽기를 시도하세요.'}); }
  });
}
