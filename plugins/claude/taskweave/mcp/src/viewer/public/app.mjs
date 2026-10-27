const $ = selector => document.querySelector(selector);
const form=$('#filters');
let listVersion=0, detailVersion=0, page=1, currentWorkplan=null, currentTab='계획', selectedId=null;
const tabs=['계획','구현','코드 흐름','테스트','변경 이력','추가 문서'];
const escape = text => String(text ?? '').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const date = value => new Intl.DateTimeFormat('ko-KR',{dateStyle:'medium',timeStyle:'short',timeZone:'UTC'}).format(new Date(value));
async function getJson(url) { const response=await fetch(url,{cache:'no-store'}); const data=await response.json(); if (!response.ok) throw new Error(data.error || '자료를 읽지 못했습니다.'); return data; }
function message(element,text) { element.textContent=text; element.hidden=!text; }
function failure(element,error,retry) { message(element,error.message); const button=document.createElement('button'); button.textContent='다시 시도'; button.addEventListener('click',retry,{once:true}); element.append(' ',button); }
function updateOptions(select,values,all,missing=false) {
  const chosen=select.value;
  select.innerHTML=`<option value="">${all}</option>${missing?'<option value="__missing__">기록 없음</option>':''}${values.map(v=>`<option value="${escape(v)}">${escape(v)}</option>`).join('')}`;
  select.value=chosen;
}
export async function loadList(append=false) {
  const version=++listVersion; if (!append) page=1;
  const params=new URLSearchParams(new FormData(form)); params.set('page',String(page));
  message($('#notice'),'기록을 읽고 있습니다…'); $('#more').disabled=true;
  try {
    const data=await getJson(`/api/workplans?${params}`); if (version !== listVersion) return;
    updateOptions(form.elements.project,data.projects,'모든 프로젝트'); updateOptions(form.elements.status,data.statuses,'모든 상태',true);
    $('#count').textContent=`${data.total}건`; $('#more').hidden=!data.hasMore; $('#more').disabled=false;
    message($('#notice'), data.warnings.length ? `일부 자료를 읽지 못했습니다 · ${data.warnings.join(' / ')}` : `${data.indexed}개 작업을 읽었습니다. 날짜 기준: UTC · 원문 날짜 또는 문서 수정 시각`);
    const html=data.items.map(item=>`<button class="workplan-card${selectedId===item.id?' selected':''}" data-workplan="${item.id}" aria-pressed="${selectedId===item.id}"><span class="card-project">${escape(item.project)}</span><strong>${escape(item.title)}</strong><span class="card-meta"><span class="status">${escape(item.status || '기록 없음')}</span>${item.jira?`<span>${escape(item.jira)}</span>`:''}</span><time datetime="${item.updatedAt}">${date(item.updatedAt)} UTC · ${item.dateSource==='metadata'?'원문 날짜':'문서 수정 시각'}</time></button>`).join('');
    if (append) $('#list').insertAdjacentHTML('beforeend',html); else $('#list').innerHTML=html || '<p class="empty">조건에 맞는 작업이 없습니다.<br>키워드나 필터를 바꿔 보세요.</p>';
  } catch (error) { if (version===listVersion) failure($('#notice'),error,()=>loadList(append)); }
}
function setDetailState(text) { $('#detail-state').hidden=false; message($('#detail-state'),text); $('#detail-content').hidden=true; }
function kindFor(doc) {
  if (doc.kind==='flow' || doc.kind==='image') return '코드 흐름';
  if (/test|verif|검증|테스트/i.test(doc.name)) return '테스트';
  if (/changelog|history|변경/i.test(doc.name)) return '변경 이력';
  if (/completion|result|implement|완료|구현/i.test(doc.name)) return '구현';
  if (doc.main || /plan|계획/i.test(doc.name)) return '계획';
  return '추가 문서';
}
function renderTabs() { $('#tabs').innerHTML=tabs.map(tab=>`<button data-tab="${tab}" aria-pressed="${tab===currentTab}" class="${tab===currentTab?'active':''}">${tab}</button>`).join(''); }
async function selectTab(tab) {
  currentTab=tab; renderTabs();
  const docs=currentWorkplan.documents.filter(doc=>kindFor(doc)===tab);
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
  const words={ '구현':/구현|결과|implementation|result/i,'변경 이력':/변경 이력|changelog|history/i };
  const template=document.createElement('div'); template.innerHTML=currentWorkplan.document.html;
  const heading=[...template.querySelectorAll('h1,h2,h3,h4')].find(h=>words[tab]?.test(h.textContent));
  if (heading) { const section=document.createElement('div'); section.append(heading.cloneNode(true)); let next=heading.nextElementSibling; while (next && !/^H[1-4]$/.test(next.tagName)) { section.append(next.cloneNode(true)); next=next.nextElementSibling; } $('#article').innerHTML=section.innerHTML; message($('#document-notice'),'본문에 적힌 관련 영역입니다. 별도 결과를 추정하지 않습니다.'); }
  else { $('#article').innerHTML='<p class="empty">기록 없음 · 이 영역으로 분류할 수 있는 연결 문서가 없습니다.</p>'; message($('#document-notice'),''); }
}
export async function selectWorkplan(id) {
  selectedId=id; const version=++detailVersion; setDetailState('작업을 읽고 있습니다…');
  document.querySelectorAll('[data-workplan]').forEach(button=>{ const selected=button.dataset.workplan===id; button.classList.toggle('selected',selected); button.setAttribute('aria-pressed',String(selected)); });
  try {
    const entry=await getJson(`/api/workplans/${id}`); if (version!==detailVersion) return;
    currentWorkplan=entry; $('#detail-state').hidden=true; $('#detail-content').hidden=false;
    $('#workplan-heading').innerHTML=`<button class="back-to-list" type="button">← 목록으로</button><p class="eyebrow">${escape(entry.project)}</p><h2>${escape(entry.title)}</h2><p class="detail-meta"><span class="status">${escape(entry.status || '기록 없음')}</span> ${escape(entry.jira || '')} · ${date(entry.updatedAt)} UTC · ${entry.dateSource==='metadata'?'원문 날짜':'문서 수정 시각'}</p>`;
    $('#workplan-heading .back-to-list').addEventListener('click',()=>$('.library').scrollIntoView({block:'start'}));
    await selectTab('계획');
    if (matchMedia('(max-width:760px)').matches) $('.detail').scrollIntoView({block:'start'});
  } catch (error) { if (version===detailVersion) { setDetailState(''); failure($('#detail-state'),error,()=>selectWorkplan(id)); } }
}
export async function selectDocument(id) {
  const version=++detailVersion; $('#flow').hidden=true; $('#flow').removeAttribute('src'); $('#article').hidden=false; $('#source').hidden=true; message($('#document-notice'),'문서를 읽고 있습니다…');
  try { const doc=await getJson(`/api/documents/${id}`); if (version!==detailVersion) return; $('#article').innerHTML=doc.html; $('#source').hidden=false; $('#source pre').textContent=doc.sourceText; $('#source').open=false; message($('#document-notice'),`${doc.name}${doc.warnings.length?' · '+doc.warnings.join(' / '):''}${currentWorkplan?.warnings.length?' · '+currentWorkplan.warnings.join(' / '):''}`); }
  catch (error) { if (version===detailVersion) { $('#article').replaceChildren(); failure($('#document-notice'),error,()=>selectDocument(id)); } }
}
export function showFlow(id) {
  ++detailVersion; $('#article').hidden=true; $('#source').hidden=true; $('#flow').hidden=false; $('#flow').src=`/assets/${id}`;
  message($('#document-notice'),'격리된 첨부 · 외부 접속과 상위 화면 이동은 차단됩니다. CDN에 의존한 그림은 표시가 제한될 수 있습니다.');
}
export async function refreshCatalog() {
  $('#refresh').disabled=true; message($('#notice'),'원본에서 다시 읽고 있습니다…');
  ++listVersion; ++detailVersion;
  try { await getJson('/api/refresh'); await loadList(); if (selectedId) await selectWorkplan(selectedId); }
  catch (error) { failure($('#notice'),error,refreshCatalog); }
  finally { $('#refresh').disabled=false; }
}
form.addEventListener('submit',event=>{event.preventDefault();loadList();});
$('#refresh').addEventListener('click',refreshCatalog);
$('#more').addEventListener('click',()=>{page++;loadList(true);});
document.addEventListener('click',event=>{
  const target=event.target.closest('[data-workplan],[data-tab],[data-document],[data-asset]'); if (!target) return;
  event.preventDefault();
  if (target.dataset.workplan) selectWorkplan(target.dataset.workplan);
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
loadList();
