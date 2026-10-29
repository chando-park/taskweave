import { PRODUCT_NAME } from '../product.mjs';
import { Marked } from 'marked';
import sanitizeHtml from 'sanitize-html';

export function escapeHtml(value) { return String(value).replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c])); }

export function renderSafeMarkdown(text, resolveLink = () => null) {
  const parser = new Marked({ gfm:true, breaks:false, renderer: { heading(token) {
    const id=token.text.toLocaleLowerCase().replace(/<[^>]*>/g,'').replace(/[^\p{L}\p{N}\s_-]/gu,'').trim().replace(/\s+/g,'-');
    return `<h${token.depth} id="${escapeHtml(id)}">${this.parser.parseInline(token.tokens)}</h${token.depth}>\n`;
  } } });
  return sanitizeHtml(parser.parse(text), {
    allowedTags: [...sanitizeHtml.defaults.allowedTags, 'img', 'details', 'summary', 'input'],
    allowedAttributes: { a: ['href','title','rel','target','data-document','data-asset'], img: ['src','alt','title','loading'], code: ['class'], input: ['type','checked','disabled'], th: ['align'], td: ['align'], '*': ['id'] },
    allowedSchemes: ['http','https'],
    transformTags: {
      a: (tag, attributes) => {
        const href = resolveLink(attributes.href);
        if (!href) return { tagName:'span', attribs:{} };
        const attribs = { href, ...(attributes.title ? { title: attributes.title } : {}) };
        if (href.startsWith('/document/')) attribs['data-document'] = href.split('/')[2].split('#')[0];
        else if (href.startsWith('/assets/')) attribs['data-asset'] = href.split('/')[2].split('#')[0];
        else if (/^https?:/.test(href)) Object.assign(attribs, { target:'_blank', rel:'noopener noreferrer' });
        return { tagName:'a', attribs };
      },
      img: (tag, attributes) => ({ tagName:'img', attribs: { ...(resolveLink(attributes.src, true) ? { src:resolveLink(attributes.src,true) } : {}), alt: attributes.alt || '허용되지 않거나 없는 이미지', loading:'lazy' } }),
      input: () => ({ tagName:'input', attribs: { type:'checkbox', disabled:'' } }),
    },
  });
}

function applyWorkplanTitle(html, title) {
  const escaped = escapeHtml(title); let hasTitle = false; let hasHeading = false;
  let svgDepth = 0;
  // 정리된 HTML의 실제 제목만 바꾸며 script/style과 코드 예제 안의 태그는 건너뛴다.
  const protectedBlock = '<(script|style|textarea|pre|code)\\b[^>]*>[\\s\\S]*?<\\/\\1\\s*>';
  let result = html.replace(new RegExp(`${protectedBlock}|<\\/?svg\\b[^>]*>|<title\\b[^>]*>[\\s\\S]*?<\\/title\\s*>|<h1\\b([^>]*)>[\\s\\S]*?<\\/h1\\s*>`, 'gi'), (match, protectedTag, attributes) => {
    if (protectedTag) return match;
    if (/^<svg\b/i.test(match)) { svgDepth++; return match; }
    if (/^<\/svg\b/i.test(match)) { svgDepth--; return match; }
    if (svgDepth) return match;
    if (/^<title\b/i.test(match)) { hasTitle = true; return `<title>${escaped}</title>`; }
    if (hasHeading) return match;
    hasHeading = true; return `<h1${attributes}>${escaped}</h1>`;
  });
  const titleTag = hasTitle ? '' : `<title>${escaped}</title>`;
  const headingTag = hasHeading ? '' : `<h1>${escaped}</h1>`;
  let insertedTitle = false; let insertedHeading = false;
  svgDepth = 0;
  result = result.replace(new RegExp(`${protectedBlock}|<\\/?svg\\b[^>]*>|<head\\b[^>]*>|<body\\b[^>]*>`, 'gi'), (match, protectedTag) => {
    if (protectedTag) return match;
    if (/^<svg\b/i.test(match)) { svgDepth++; return match; }
    if (/^<\/svg\b/i.test(match)) { svgDepth--; return match; }
    if (svgDepth) return match;
    if (/^<head\b/i.test(match) && !insertedTitle) { insertedTitle = true; return match + titleTag; }
    if (/^<body\b/i.test(match) && !insertedHeading) { insertedHeading = true; return match + headingTag; }
    return match;
  });
  return (insertedTitle ? '' : titleTag) + (insertedHeading ? '' : headingTag) + result;
}

export async function renderFlowHtml(text, resolveLink, readImage, title) {
  const images = new Map();
  if (readImage) {
    // 격리된 HTML에서 서버로 이미지를 다시 요청하면 보안 정책이 차단한다.
    // 등록된 로컬 이미지만 먼저 읽어 HTML 안에 담고, 외부 이미지·임의 경로는 계속 제외한다.
    sanitizeHtml(text, { allowedTags: ['img'], transformTags: { img: (tag, attrs) => {
      const src = resolveLink(attrs.src, true);
      if (src) images.set(src, null);
      return { tagName: 'img', attribs: {} };
    } } });
    await Promise.all([...images.keys()].map(async src => {
      try { images.set(src, await readImage(src)); } catch { images.set(src, null); }
    }));
  }
  // 원문 HTML은 저장하지 않는다. 동작은 opaque-origin iframe과 응답 CSP 안에서만 허용한다.
  let clean = sanitizeHtml(text, {
    allowedTags:false, allowedAttributes:false, allowVulnerableTags:true,
    allowedSchemes:['http','https'],
    allowedSchemesByTag: { img: readImage ? ['data'] : ['http', 'https'] },
    exclusiveFilter: frame => ['base','meta','iframe','object','embed','form','link'].includes(frame.tag) || (frame.tag === 'script' && Boolean(frame.attribs.src)),
    transformTags: {
      a: (tag, attrs) => {
        const href = resolveLink(attrs.href);
        const attribs = { ...attrs }; delete attribs.target; delete attribs.download; delete attribs.ping;
        if (href && !/^https?:/.test(href)) attribs.href = href; else delete attribs.href;
        return { tagName:'a', attribs };
      },
      img: (tag, attrs) => { const resolved = resolveLink(attrs.src,true); const src = readImage ? images.get(resolved) : resolved; const attribs={...attrs}; if (src) attribs.src=src; else delete attribs.src; delete attribs.srcset; return {tagName:'img',attribs}; },
    },
  });
  if (typeof title === 'string' && title) clean = applyWorkplanTitle(clean, title);
  // 격리 iframe의 null origin으로 API를 호출하지 않고 검증된 부모 창에 문서 ID만 전달한다.
  return `${clean}<script>document.addEventListener('click',function(event){var a=event.target.closest&&event.target.closest('a[href]');if(!a)return;var match=a.getAttribute('href').match(/^\\/(document|assets)\\/([a-f0-9]{24})(?:#.*)?$/);if(match&&parent!==window){event.preventDefault();parent.postMessage({type:'cdpower-link',kind:match[1],id:match[2]},'*');}});</script>`;
}

export function renderDocumentPage(document, html) {
  return `<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(document.name)} · ${PRODUCT_NAME}</title><link rel="stylesheet" href="/styles.css"></head><body class="document-page"><header class="document-heading"><a href="/">${PRODUCT_NAME}</a><span>${escapeHtml(document.name)}</span></header><main class="markdown">${html}<details class="source"><summary>원문 텍스트 보기</summary><pre>${escapeHtml(document.sourceText)}</pre></details></main></body></html>`;
}
