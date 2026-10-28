import { statusGroup, statusLabel } from './status.mjs';
import { tabs, documentTab, documentsForTab } from './documents.mjs';
import { formatDocumentDate } from './dates.mjs';

const $ = selector => document.querySelector(selector);
const form=$('#filters');
let listVersion=0, detailVersion=0, overviewVersion=0, page=1, currentWorkplan=null, currentTab='계획', selectedId=null;
let currentView='home', returnView='home', listData=null, searchTimer;
const escape = text => String(text ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date = item => formatDocumentDate(item.displayDate ?? item.updatedAt);
async function getJson(url) { const response=await fetch(url,{cache:'no-store'}); const data=await response.json(); if (!response.ok) throw new Error(data.error || '자료를 읽지 못했습니다.'); return data; }
function message(element,text) { element.textContent=text; element.hidden=!text; }
function failure(element,error,retry) { message(element,error.message); const button=document.createElement('button'); button.textContent='다시 시도'; button.addEventListener('click',retry,{once:true}); element.append(' ',button); }
function readingWarnings(warnings) {
  const element=$('#overview-notice'); element.replaceChildren(); element.hidden=!warnings.length;
  if (!warnings.length) return;
  const details=document.createElement('details'), summary=document.createElement('summary'), list=document.createElement('ul');
  summary.textContent=`일부 자료를 제외했습니다 · 읽기 안내 ${warnings.length}건`;
  for(const warning of warnings){const item=document.createElement('li');item.textContent=warning;list.append(item);}
  details.append(summary,list);element.append(details);
}
function updateOptions(select,values,all,missing=false) {
  const chosen=select.value;
  select.innerHTML=`<option value="">${all}</option>${missing?'<option value="__missing__">기록 없음</option>':''}${values.map(v=>`<option value="${escape(v)}">${escape(v)}</option>`).join('')}`;
  select.value=chosen;
}
function statusBadge(status) {
  return `<span class="tw-status status" data-status="${statusGroup(status)}" title="${escape(status || '기록 없음')}"><span class="tw-check-dot" aria-hidden="true"></span>${escape(statusLabel(status))}</span>`;
}
function updateFilters() {
  document.querySelectorAll('.tw-filter[data-group]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.group===form.elements.group.value)));
  $('#filter-summary').textContent=[form.elements.project.value,form.elements.status.value,form.elements.from.value,form.elements.to.value].filter(Boolean).join(' · ');
  document.querySelectorAll('[data-project]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.project===form.elements.project.value)));
}
function renderList() {
  if (!listData) return;
  const items=currentView==='home' ? listData.items.slice(0,5) : listData.items;
  $('#count').textContent=currentView==='home' ? `${items.length} / ${listData.total}건` : `${listData.total}건`;
  $('#more').hidden=currentView==='home' || !listData.hasMore;
  $('#list').innerHTML=items.map(item=>`<button type="button" class="workplan-card tw-row${selectedId===item.id?' selected':''}" data-workplan="${item.id}" aria-pressed="${selectedId===item.id}"><span class="tw-row-top"><span class="tw-row-id">${escape(item.project)}</span>${statusBadge(item.status)}</span><strong class="tw-row-title">${escape(item.title)}</strong><span class="tw-row-bottom">${item.jira?`<span>${escape(item.jira)}</span> · `:''}<time datetime="${item.updatedAt}">${date(item)}</time><span>· ${item.dateSource==='metadata'?'원문 날짜':'문서 수정 시각'}</span></span></button>`).join('') || '<p class="empty">조건에 맞는 작업이 없습니다.<br>키워드나 필터를 바꿔 보세요.</p>';
}
function showPage(view) {
  ++detailVersion;
  currentView=view;
  $('#work-page').hidden=view==='brand'; $('#brand-page').hidden=view!=='brand';
  $('.workspace').classList.toggle('is-detail',view==='detail');
  $('.workspace').classList.toggle('is-library',view==='library');
  $('.detail').hidden=view!=='detail';
  $('#current-page').textContent={home:'홈',library:'워크플랜',brand:'브랜드',detail:'작업 상세'}[view];
  $('#list-heading').textContent=view==='home'?'최근 작업':'워크플랜';
  $('#page-title').innerHTML=view==='library'?'워크플랜 라이브러리':'필요한 맥락을 모으고,<br><span>다음 일을 가볍게.</span>';
  $('#page-subtitle').innerHTML=view==='library'?'계획부터 코드와 검증까지, 필요한 맥락을 찾아보세요.':'계획과 코드, 그 사이의 결정까지.<br>쌓아 둔 맥락이 다음 작업의 힘이 됩니다.';
  document.querySelectorAll('[data-view]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.view===(view==='detail'?'library':view))));
  $('#flow').hidden=true; $('#flow').removeAttribute('src');
  renderList();
}
export async function loadOverview() {
  const version=++overviewVersion;
  try {
    const data=await getJson('/api/overview'); if (version!==overviewVersion) return;
    for (const group of ['active','review','done']) $(`#${group}-count`).textContent=String(data.counts[group]).padStart(2,'0');
    $('#nav-count').textContent=data.total;
    $('#catalog-summary').textContent=`전체 ${data.total}건 · 그 외 상태 ${data.counts.other}건 · 원문 기준`;
    $('#project-links').innerHTML=data.projects.map(project=>`<button type="button" class="tw-project" data-project="${escape(project.name)}" aria-pressed="${form.elements.project.value===project.name}"><span class="tw-project-dot" aria-hidden="true"></span><span class="project-name">${escape(project.name)}</span><span class="project-count">${project.count}</span></button>`).join('') || '<p class="empty">등록된 작업 없음</p>';
    const latest=data.recent[0];
    $('#recent-title').textContent=latest?.title || '아직 읽은 작업이 없습니다.';
    $('#resume').disabled=!latest;
    if (latest) $('#resume').dataset.workplan=latest.id; else delete $('#resume').dataset.workplan;
    $('#recent-updates').innerHTML=data.recent.map(item=>`<div class="tw-event"><button type="button" data-workplan="${item.id}">${escape(item.title)}</button><small>${date(item)}<br>${item.dateSource==='metadata'?'원문 날짜':'문서 수정 시각'} · ${escape(statusLabel(item.status))}</small></div>`).join('') || '<p class="empty">갱신 기록 없음</p>';
    readingWarnings(data.warnings);
  } catch(error) { if(version===overviewVersion) failure($('#overview-notice'),error,loadOverview); }
}
export async function loadList(append=false) {
  const version=++listVersion; if (!append) page=1;
  const params=new URLSearchParams(new FormData(form)); params.set('page',String(page));
  message($('#notice'),'기록을 읽고 있습니다…'); $('#more').disabled=true;
  try {
    const data=await getJson(`/api/workplans?${params}`); if (version !== listVersion) return;
    updateOptions(form.elements.project,data.projects,'모든 프로젝트'); updateOptions(form.elements.status,data.statuses,'모든 상태',true);
    listData={...data,items:append&&listData?[...listData.items,...data.items]:data.items};
    renderList(); updateFilters();
    readingWarnings(data.warnings); message($('#notice'),'');
  } catch (error) { if (version===listVersion) failure($('#notice'),error,()=>loadList(append)); }
  finally { if(version===listVersion) $('#more').disabled=false; }
}
function setDetailState(text) { $('#detail-state').hidden=false; message($('#detail-state'),text); $('#detail-content').hidden=true; }
function renderTabs() { $('#tabs').innerHTML=tabs.map(tab=>`<button data-tab="${tab}" aria-pressed="${tab===currentTab}" class="${tab===currentTab?'active':''}">${tab}</button>`).join(''); }
async function selectTab(tab) {
  currentTab=tab; renderTabs();
  const docs=documentsForTab(currentWorkplan.documents,tab);
  $('#documents').innerHTML=docs.map(doc=>`<button data-${doc.kind==='markdown'?'document':'asset'}="${doc.id}">${escape(doc.name.split('/').slice(-2).join('/'))}</button>`).join('');
  if (docs.length) return docs[0].kind==='markdown' ? selectDocument(docs[0].id) : showFlow(docs[0].id);
  const version=++detailVersion; $('#flow').hidden=true; $('#flow').removeAttribute('src'); $('#source').hidden=true; $('#article').hidden=false;
  if (tab==='테스트') {
    const workplan=currentWorkplan;
    const candidates=workplan.documents.filter(doc=>doc.kind==='markdown' && !doc.main && /completion|result|완료|결과/i.test(doc.name));
    candidates.push(workplan.document);
    message($('#document-notice'),'테스트·검증 결과 기록을 읽고 있습니다…');
    const errors=[];
    for (const candidate of candidates) {
      let doc;
      try { doc=candidate.html ? candidate : await getJson(`/api/documents/${candidate.id}`); }
      catch (error) { if (version!==detailVersion) return; errors.push(error.message); continue; }
      if (version!==detailVersion) return;
      const template=document.createElement('div'); template.innerHTML=doc.html;
      // 검증 계획을 실행 결과로 오인하지 않고 명시된 결과 절만 보여 준다.
      const heading=[...template.querySelectorAll('h1,h2,h3,h4,h5,h6')].find(h=>/(?:테스트|검증)\s*(?:결과|기록)|(?:test|verification)\s*(?:results?|evidence)/i.test(h.textContent) && !/계획|예정|plan/i.test(h.textContent));
      if (!heading) continue;
      const section=document.createElement('div'); section.append(heading.cloneNode(true));
      let next=heading.nextElementSibling;
      while (next && !(/^H[1-6]$/.test(next.tagName) && Number(next.tagName[1])<=Number(heading.tagName[1]))) { section.append(next.cloneNode(true)); next=next.nextElementSibling; }
      $('#article').innerHTML=section.innerHTML; $('#source').hidden=false; $('#source pre').textContent=doc.sourceText; $('#source').open=false;
      message($('#document-notice'),`${doc.name} · 원문에 명시된 테스트·검증 결과입니다.${doc.warnings.length?' · '+doc.warnings.join(' / '):''}`);
      return;
    }
    if (version!==detailVersion) return;
    $('#article').innerHTML='<p class="empty">결과 기록 없음 · 테스트·검증 결과가 명시된 연결 문서를 찾지 못했습니다.</p>';
    if (errors.length) failure($('#document-notice'),new Error(errors.join(' / ')),()=>selectTab('테스트')); else message($('#document-notice'),'검증 계획을 실행 결과로 표시하지 않습니다.');
    return;
  }
  if (tab==='화면 비교') {
    $('#article').innerHTML='<p class="empty">화면 비교 자료 없음 · 연결된 비교 HTML·이미지가 아직 없습니다.</p>';
    message($('#document-notice'),'자료 유무는 UI 검증 통과 여부를 뜻하지 않습니다.');
    return;
  }
  const words={ '구현':/구현|결과|implementation|result/i,'변경 이력':/변경 이력|changelog|history/i };
  const template=document.createElement('div'); template.innerHTML=currentWorkplan.document.html;
  const heading=[...template.querySelectorAll('h1,h2,h3,h4')].find(h=>words[tab]?.test(h.textContent));
  if (heading) { const section=document.createElement('div'); section.append(heading.cloneNode(true)); let next=heading.nextElementSibling; while (next && !/^H[1-4]$/.test(next.tagName)) { section.append(next.cloneNode(true)); next=next.nextElementSibling; } $('#article').innerHTML=section.innerHTML; message($('#document-notice'),'본문에 적힌 관련 영역입니다. 별도 결과를 추정하지 않습니다.'); }
  else { $('#article').innerHTML='<p class="empty">기록 없음 · 이 영역으로 분류할 수 있는 연결 문서가 없습니다.</p>'; message($('#document-notice'),''); }
}
export async function selectWorkplan(id) {
  if(currentView!=='detail') returnView=currentView==='home'?'home':'library';
  selectedId=id; showPage('detail'); const version=++detailVersion; setDetailState('작업을 읽고 있습니다…');
  document.querySelectorAll('[data-workplan]').forEach(button=>{ const selected=button.dataset.workplan===id; button.classList.toggle('selected',selected); button.setAttribute('aria-pressed',String(selected)); });
  try {
    const entry=await getJson(`/api/workplans/${id}`); if (version!==detailVersion) return;
    currentWorkplan=entry; $('#detail-state').hidden=true; $('#detail-content').hidden=false;
    $('#workplan-heading').innerHTML=`<button class="back-to-list" type="button">← 목록으로</button><p class="eyebrow">${escape(entry.project)}</p><h2>${escape(entry.title)}</h2><p class="detail-meta">${statusBadge(entry.status)} ${escape(entry.jira || '')} · ${date(entry)} · ${entry.dateSource==='metadata'?'원문 날짜':'문서 수정 시각'}</p>`;
    $('#workplan-heading .back-to-list').addEventListener('click',()=>{showPage(returnView);$('.library').scrollIntoView({block:'start'});});
    await selectTab('계획');
    $('.detail').scrollIntoView({block:'start'});
  } catch (error) { if (version===detailVersion) { setDetailState(''); failure($('#detail-state'),error,()=>selectWorkplan(id)); } }
}
export async function selectDocument(id) {
  const version=++detailVersion; $('#flow').hidden=true; $('#flow').removeAttribute('src'); $('#article').hidden=false; $('#source').hidden=true; message($('#document-notice'),'문서를 읽고 있습니다…');
  try { const doc=await getJson(`/api/documents/${id}`); if (version!==detailVersion) return; $('#article').innerHTML=doc.html; $('#source').hidden=false; $('#source pre').textContent=doc.sourceText; $('#source').open=false; message($('#document-notice'),`${doc.name}${doc.warnings.length?' · '+doc.warnings.join(' / '):''}${currentWorkplan?.warnings.length?' · '+currentWorkplan.warnings.join(' / '):''}`); }
  catch (error) { if (version===detailVersion) { $('#article').replaceChildren(); failure($('#document-notice'),error,()=>selectDocument(id)); } }
}
export function showFlow(id) {
  const doc=currentWorkplan?.documents.find(doc=>doc.id===id);
  if (doc) { currentTab=documentTab(doc,currentWorkplan.documents.find(doc=>doc.main)?.name); renderTabs(); }
  $('#flow').title=doc ? `${currentTab} · ${doc.name.split('/').at(-1)}` : '첨부 자료';
  ++detailVersion; $('#article').hidden=true; $('#source').hidden=true; $('#flow').hidden=false; $('#flow').src=`/assets/${id}`;
  message($('#document-notice'),currentTab==='화면 비교' ? '원본과 수정 화면을 비교한 자료입니다. 통과·불일치·미확인 여부는 자료에 적힌 결과를 확인하세요.' : '첨부 자료를 뷰어 안에서 표시합니다. 외부 연결이 필요한 내용은 표시가 제한될 수 있습니다.');
}
export async function refreshCatalog() {
  $('#refresh').disabled=true; message($('#notice'),'원본에서 다시 읽고 있습니다…');
  ++listVersion; ++detailVersion; ++overviewVersion;
  try { await getJson('/api/refresh'); await Promise.all([loadList(),loadOverview()]); if (selectedId && currentView==='detail') await selectWorkplan(selectedId); }
  catch (error) { failure($('#notice'),error,refreshCatalog); }
  finally { $('#refresh').disabled=false; }
}
function searchList() { clearTimeout(searchTimer); if(currentView!=='detail') showPage('library'); loadList(); }
form.addEventListener('submit',event=>{event.preventDefault();searchList();});
form.elements.q.addEventListener('input',()=>{clearTimeout(searchTimer);searchTimer=setTimeout(searchList,220);});
form.addEventListener('change',event=>{if(event.target!==form.elements.q)searchList();});
$('#reset-filters').addEventListener('click',()=>{form.reset();form.elements.group.value='';searchList();});
$('#open-library').addEventListener('click',()=>{showPage('library');loadList();});
$('#refresh').addEventListener('click',refreshCatalog);
$('#more').addEventListener('click',()=>{page++;loadList(true);});
document.addEventListener('click',event=>{
  const target=event.target.closest('[data-view],[data-group],[data-project],[data-workplan],[data-tab],[data-document],[data-asset]'); if (!target) return;
  event.preventDefault();
  if (target.dataset.view) { clearTimeout(searchTimer);if(target.dataset.view==='home'){form.reset();form.elements.group.value='';}showPage(target.dataset.view);if(target.dataset.view!=='brand')loadList(); }
  else if ('group' in target.dataset) {form.elements.group.value=target.dataset.group;form.elements.status.value='';searchList();}
  else if (target.dataset.project) {form.elements.project.value=target.dataset.project;searchList();}
  else if (target.dataset.workplan) selectWorkplan(target.dataset.workplan);
  else if (target.dataset.tab) selectTab(target.dataset.tab);
  else if (target.dataset.document) selectDocument(target.dataset.document);
  else showFlow(target.dataset.asset);
});
window.addEventListener('message',event=>{
  // Origin이 null인 다른 창의 메시지는 받지 않고 현재 iframe과 등록된 ID만 허용한다.
  const data=event.data;
  if ($('#flow').hidden || event.source!==$('#flow').contentWindow || data?.type!=='taskweave-link' || !/^[a-f0-9]{24}$/.test(data.id) || !currentWorkplan?.documents.some(doc=>doc.id===data.id)) return;
  if (data.kind==='document') selectDocument(data.id); else if (data.kind==='assets') showFlow(data.id);
});
loadOverview();
loadList();
