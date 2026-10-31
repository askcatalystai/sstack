/* HOVER_DETAILS */

// Phase cards and merged PRs share one accessible modal.
const phaseDialog=node('dialog','phase-dialog');
phaseDialog.id='phase-dialog';
phaseDialog.setAttribute('role','dialog');
phaseDialog.setAttribute('aria-modal','true');
phaseDialog.setAttribute('aria-labelledby','phase-dialog-title');
const dialogHeader=node('div','phase-dialog-header');
const dialogTitle=node('h2','');dialogTitle.id='phase-dialog-title';
const dialogClose=node('button','phase-dialog-close','Close');dialogClose.type='button';
dialogClose.setAttribute('aria-label','Close details');
// Back returns from a PR to the phase it was opened from, at the same scroll position.
const dialogBack=node('button','phase-dialog-back','← Phase');dialogBack.type='button';dialogBack.hidden=true;
const dialogHeading=node('div','phase-dialog-heading');dialogHeading.append(dialogBack,dialogTitle);
dialogHeader.append(dialogHeading,dialogClose);
const dialogBody=node('div','phase-dialog-body');dialogBody.tabIndex=0;
dialogBody.setAttribute('aria-label','Phase PRs');
phaseDialog.append(dialogHeader,dialogBody);document.body.append(phaseDialog);
let phaseTrigger=null, dialogPhase=null, dialogTaskNumber=null, returnPhase=null, returnScroll=0;
function backToPhase(){
  if(!returnPhase)return;
  const number=dialogTaskNumber;dialogPhase=returnPhase;returnPhase=null;dialogTaskNumber=null;
  dialogBack.hidden=true;dialogBody.dataset.signature='';dialogBody.setAttribute('aria-label','Phase PRs');
  updatePhaseDialog();dialogBody.scrollTop=returnScroll;
  (dialogBody.querySelector('[data-open-pr="'+number+'"]')||dialogClose).focus({preventScroll:true});
}
dialogBack.addEventListener('click',backToPhase);
function openPrFromPhase(task){
  returnPhase=dialogPhase;returnScroll=dialogBody.scrollTop;dialogPhase=null;dialogTaskNumber=task.number;
  dialogBack.textContent='← Phase '+returnPhase.number;dialogBack.hidden=false;
  dialogBody.setAttribute('aria-label','PR details');
  updatePhaseDialog();dialogBody.scrollTop=0;dialogBack.focus();
}
// Plan markdown as safe text: bullets keep their nesting, `code` spans become <code>.
function inlineCode(text){
  const frag=document.createDocumentFragment();
  text.split('`').forEach((part,i)=>{if(part)frag.append(i%2?node('code','',part):document.createTextNode(part));});
  return frag;
}
function renderDetails(details){
  const box=node('div','pr-details');
  for(const raw of (details||'').split('\n')){
    if(!raw.trim())continue;
    const m=raw.match(/^(\s*)[-*] (.*)$/);
    const line=node('p',m?'pr-detail-bullet':'pr-detail-text');
    if(m){line.style.paddingLeft=(Math.floor(m[1].length/2)*14+12)+'px';line.append(inlineCode(m[2].replace(/\*\*/g,'')));}
    else line.append(inlineCode(raw.replace(/\*\*/g,'')));
    box.append(line);
  }
  return box;
}
function closePhaseDialog(){phaseDialog.close();}
dialogClose.addEventListener('click',closePhaseDialog);
phaseDialog.addEventListener('click',event=>{
  const rect=phaseDialog.getBoundingClientRect();
  if(event.target===phaseDialog&&(event.clientX<rect.left||event.clientX>rect.right||event.clientY<rect.top||event.clientY>rect.bottom))closePhaseDialog();
});
phaseDialog.addEventListener('cancel',event=>{event.preventDefault();closePhaseDialog();});
phaseDialog.addEventListener('close',()=>{
  document.body.classList.remove('phase-modal-open');
  if(phaseTrigger?.isConnected)phaseTrigger.focus({preventScroll:true});
  phaseTrigger=null;dialogPhase=null;dialogTaskNumber=null;returnPhase=null;dialogBack.hidden=true;
});
phaseDialog.addEventListener('keydown',event=>{
  if(event.key==='Escape'){event.preventDefault();if(returnPhase)backToPhase();else closePhaseDialog();return;}
  if(event.key!=='Tab')return;
  const targets=[...phaseDialog.querySelectorAll('button,a[href],[tabindex="0"]')];
  const first=targets[0],last=targets[targets.length-1];
  if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
  else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
});
function updatePhaseDialog(){
  if(dialogTaskNumber!==null){
    const task=taskByNumber.get(dialogTaskNumber);if(!task)return;
    dialogTitle.textContent='PR '+task.number+' · '+cleanTitle(task.title);
    const signature='task:'+JSON.stringify(task);
    if(dialogBody.dataset.signature===signature)return;
    dialogBody.dataset.signature=signature;
    const scroll=dialogBody.scrollTop;
    const content=node('div','merged-dialog-content');
    content.append(node('span','badge '+badgeClass(task),task.status));
    if(task.details){content.append(node('h3','pr-details-heading','Plan'),renderDetails(task.details));}
    addHistory(task,content);
    if(!content.querySelector('.activity-timeline'))content.append(node('p','muted','No activity recorded for this PR yet.'));
    const link=githubLink(task);if(link)content.append(link);
    const focusedHref=dialogBody.contains(document.activeElement)?document.activeElement?.href:null;
    dialogBody.replaceChildren(content);dialogBody.scrollTop=scroll;
    if(focusedHref)(content.querySelector('a[href]')||dialogBody).focus();
    return;
  }
  const phase=dialogPhase;if(!phase)return;
  dialogTitle.textContent='Phase '+phase.number+' · '+cleanTitle(phase.title);
  const signature=JSON.stringify((phase.items||[]).map(item=>taskByNumber.get(item.number)||item));
  if(dialogBody.dataset.signature===signature)return;
  dialogBody.dataset.signature=signature;
  const focusedHref=dialogBody.contains(document.activeElement)?document.activeElement?.href:null;
  const list=node('ul','phase-dialog-list');
  for(const item of phase.items||[]){
    const task=taskByNumber.get(item.number)||item;
    const row=node('li','phase-dialog-pr');
    const open=node('button','phase-dialog-open');open.type='button';open.dataset.openPr=task.number;
    open.setAttribute('aria-label','Show details for PR '+task.number+' · '+cleanTitle(task.title));
    const meta=node('div','phase-dialog-meta');
    meta.append(node('strong','','PR '+task.number),node('span','badge '+badgeClass(task),task.status));
    open.append(meta,node('h3','',cleanTitle(task.title)),node('p','phase-dialog-summary',task.summary||'No summary in the plan.'));
    open.addEventListener('click',()=>openPrFromPhase(task));
    row.append(open);
    const link=githubLink(task);if(link)row.append(link);
    list.append(row);
  }
  const scroll=dialogBody.scrollTop;
  dialogBody.replaceChildren(list.children.length?list:node('p','muted','No PRs in this phase yet.'));
  dialogBody.scrollTop=scroll;
  if(focusedHref){const replacement=[...dialogBody.querySelectorAll('a[href]')].find(link=>link.href===focusedHref);(replacement||dialogBody).focus();}
}
function openPhaseDialog(trigger,phase){
  if(!phase)return;
  phaseTrigger=trigger;dialogPhase=phase;dialogTaskNumber=null;returnPhase=null;dialogBack.hidden=true;
  dialogBody.setAttribute('aria-label','Phase PRs');
  updatePhaseDialog();dialogBody.scrollTop=0;
  if(!phaseDialog.open)phaseDialog.showModal();
  document.body.classList.add('phase-modal-open');dialogClose.focus();
}
function openTaskDialog(trigger,task){
  phaseTrigger=trigger;dialogPhase=null;dialogTaskNumber=task.number;returnPhase=null;dialogBack.hidden=true;
  dialogBody.setAttribute('aria-label','PR activity timeline');
  updatePhaseDialog();dialogBody.scrollTop=0;
  if(!phaseDialog.open)phaseDialog.showModal();
  document.body.classList.add('phase-modal-open');dialogClose.focus();
}
function renderPhases(tasks){
  const grid=el('phase-grid');
  // Preserve the trigger DOM while jobs change so focus returns to the same card.
  if(!grid.children.length)for(const phase of d.phases){
    const card=node('button','phase-card');card.type='button';card.dataset.phase=phase.number;
    card.setAttribute('aria-haspopup','dialog');card.setAttribute('aria-controls',phaseDialog.id);
    card.append(node('span','phase-number','Phase '+phase.number),node('h3','',cleanTitle(phase.title)),node('span','phase-card-status'));
    card.addEventListener('click',()=>openPhaseDialog(card,phase));grid.append(card);
  }
  for(const card of grid.children){
    const items=tasks.filter(task=>String(task.phase)===card.dataset.phase);
    const merged=items.filter(task=>task.done&&!task.reverted).length;
    const active=items.filter(task=>task.active).length;
    card.classList.toggle('is-active',active>0);
    card.querySelector('.phase-card-status').textContent=merged+' / '+items.length+' merged'+(active?' · '+active+' active':'');
  }
  if(phaseDialog.open)updatePhaseDialog();
}


const board=d.board;
if(!board)throw new Error('Kanban snapshot is missing its task inventory');
const phaseByNumber=new Map(d.phases.map(phase=>[phase.number,phase]));
const taskByNumber=new Map(board.tasks.map(task=>[task.number,task]));
const states={backlog:'Planned',progress:'Coding',review:'In review',merged:'Merged'};
const badgeClass=task=>task.reverted?'reverted':task.column==='merged'?'complete':task.column==='review'?'review':task.column==='progress'?'active':task.column==='reverted'?'reverted':'';
const localStateKey='chat-council-kanban-view';
let saved={};try{saved=JSON.parse(sessionStorage.getItem(localStateKey)||'{}');}catch{}

function activityTimeline(entries){
  const list=node('ul','activity-timeline');
  for(const update of [...entries].sort((a,b)=>Date.parse(b.time)-Date.parse(a.time))){
    const li=node('li','');const time=node('time','',fmt(update.time)+' IST');time.dateTime=update.time;
    li.append(time,node('span','',update.text));list.append(li);
  }
  return list;
}
function addHistory(task,parent){
  const entries=task.history?.length?task.history:
    task.updatedAt&&task.latestUpdate?[{time:task.updatedAt,text:task.latestUpdate}]:[];
  if(entries.length)parent.append(activityTimeline(entries));
}

function githubLink(task){
  if(!task.url)return null;
  const link=node('a','pr-link','GitHub #'+task.url.split('/').pop()+' ↗');
  link.href=task.url;link.target='_blank';link.rel='noopener';return link;
}

function phaseLabel(task){
  const phase=phaseByNumber.get(task.phase);
  const button=node('button','phase-label','Phase '+task.phase);button.type='button';
  button.setAttribute('aria-label','Phase '+task.phase+' · '+task.phaseTitle);button.setAttribute('aria-haspopup','dialog');
  button.addEventListener('click',event=>{event.stopPropagation();openPhaseDialog(button,phase);});return button;
}

function metadata(task){
  const meta=node('div','task-meta');meta.append(node('span','pr-number','PR '+task.number),phaseLabel(task));return meta;
}

function taskCard(task,variant='board'){
  const card=node('article','task-card');card.tabIndex=0;card.dataset.taskNumber=task.number;card.dataset.column=task.column;
  card.setAttribute('aria-label','PR '+task.number+' · '+cleanTitle(task.title)+' · '+task.status);
  const merged=task.column==='merged';
  if(merged){
    card.classList.add('merged-card');card.removeAttribute('tabindex');card.tabIndex=-1;
    const title=node('button','merged-card-trigger');title.type='button';
    title.setAttribute('aria-haspopup','dialog');title.setAttribute('aria-controls',phaseDialog.id);
    title.append(node('span','pr-number','PR '+task.number),node('span','merged-card-title',cleanTitle(task.title)));
    title.setAttribute('aria-label','Show activity for PR '+task.number+' · '+cleanTitle(task.title));
    const footer=node('div','task-footer');footer.append(node('span','badge '+badgeClass(task),task.status));
    const link=githubLink(task);if(link)footer.append(link);
    card.append(title,footer);
    card.addEventListener('click',event=>{if(!link?.contains(event.target))openTaskDialog(title,task);});
    return card;
  }
  const header=node('div','task-header');header.append(metadata(task));
  if(['progress','review'].includes(task.column)&&task.jobs?.length){
    const stack=node('div','task-job-labels');
    for(const job of task.jobs)stack.append(jobLabels(job));
    header.append(stack);
  }
  card.classList.toggle('is-active',Boolean(task.active));
  card.append(header,node('h4','',cleanTitle(task.title)));
  if(task.summary)card.append(node('p','task-summary',task.summary));
  addHistory(task,card,variant);
  const footer=node('div','task-footer');footer.append(node('span','badge '+badgeClass(task),task.status));
  const link=githubLink(task);if(link)footer.append(link);else if(task.updatedAt)footer.append(node('time','',fmt(task.updatedAt)+' IST'));
  card.append(footer);return card;
}

el('status').textContent='Connecting to live jobs…';
// Plan order stays stable; only live placement changes between snapshots.
function isReviewJob(job){
  return job.role==='review';
}
function assignTask(task,jobs){
  const linked=jobs.filter(job=>Number(job.plan)===Number(task.number));
  const running=linked.filter(job=>job.status==='running');
  // A live implementation takes precedence over old review stages and PR links.
  const url=linked.find(job=>job.github)?.github || (task.urlSource==='item_links'?task.url:null);
  const column=task.done||task.reverted?'merged':running.some(job=>job.role==='implement')?'progress':
    running.some(isReviewJob)||url?'review':'backlog';
  return {...task,jobs:running,active:running.length>0,column,url,
    status:task.reverted?'Reverted':column==='merged'?'Merged':column==='review'?'In review':column==='progress'?'Coding':'Planned'};
}
function backlogOrder(tasks,currentPhase){
  const activePhases=new Set(tasks.filter(task=>task.active).map(task=>task.phase));
  if(currentPhase!==undefined)activePhases.add(currentPhase);
  const queued=tasks.filter(task=>task.column==='backlog');
  return [...queued.filter(task=>activePhases.has(task.phase)),...queued.filter(task=>!activePhases.has(task.phase))];
}
function renderBoard(jobs){
  const tasks=board.tasks.map(task=>assignTask(task,jobs));
  for(const task of tasks)taskByNumber.set(task.number,task);
  const queue=backlogOrder(tasks,taskByNumber.get(d.currentNumber)?.phase);
  const counts=Object.fromEntries(Object.keys(states).map(key=>[key,tasks.filter(task=>task.column===key).length]));
  // Reuse cards while placement and labels are unchanged, preserving focus and details.
  for(const key of Object.keys(states)){
    let column=el('kanban-board').querySelector('[data-column="'+key+'"]');
    if(!column){
      column=node('section','kanban-column');column.dataset.column=key;
      const heading=node('div','column-header');const label=node('h3','column-title');
      label.append(node('span','status-dot '+key+'-dot'),node('span','',states[key]));
      heading.append(label,node('span','count'));
      const list=node('div','column-list');list.dataset.scrollKey=key;
      list.setAttribute('role','list');list.setAttribute('aria-label',states[key]+' tasks');
      column.append(heading,list);el('kanban-board').append(column);
    }
    column.querySelector('.count').textContent=counts[key];
    const list=column.querySelector('.column-list');
    const entries=key==='backlog'?queue:tasks.filter(task=>task.column===key);
    const signature=JSON.stringify(entries.map(task=>[task.number,task.status,task.url,task.history,task.updatedAt,task.latestUpdate,task.jobs.map(job=>[job.id,job.provider,job.model,job.effort])]));
    if(list.dataset.signature!==signature){
      const scroll=list.scrollTop;
      const open=new Set([...list.querySelectorAll('details[open]')].map(detail=>detail.dataset.historyKey));
      const fragment=document.createDocumentFragment();
      if(!entries.length)fragment.append(node('p','column-empty','No tasks'));
      for(const task of entries){const card=taskCard(task);card.setAttribute('role','listitem');fragment.append(card);}
      list.replaceChildren(fragment);list.scrollTop=scroll;list.dataset.signature=signature;
      for(const detail of list.querySelectorAll('details'))if(open.has(detail.dataset.historyKey))detail.open=true;
    }
  }
  const next=queue.slice(0,3);const signature=JSON.stringify(next.map(task=>task.number));
  if(el('next-tasks').dataset.signature!==signature){
    el('next-tasks').replaceChildren();el('next-tasks').dataset.signature=signature;
    if(!next.length)el('next-tasks').append(node('li','next-empty','No queued tasks remain.'));
    for(const [index,task] of next.entries()){
      const li=node('li','next-item');li.dataset.nextNumber=task.number;
      const content=node('div','next-content');content.append(metadata(task),node('h4','',cleanTitle(task.title)));
      if(task.summary)content.append(node('p','task-summary',task.summary));
      li.append(node('span','queue-number',String(index+1).padStart(2,'0')),content);
      li.tabIndex=0;li.setAttribute('aria-label','Next '+(index+1)+': PR '+task.number+' '+cleanTitle(task.title));
      el('next-tasks').append(li);
    }
  }
  renderPhases(tasks);
  el('board-totals').textContent=tasks.length+' tasks · '+counts.merged+' merged · '+tasks.filter(task=>task.reverted).length+' reverted';
}
el('checked').textContent='Checked '+fmt(d.checkedAt)+' IST';
el('activity-time').textContent=d.lastEventAt?'Last session event '+fmt(d.lastEventAt)+' IST':'';
el('events').classList.add('activity-timeline');
for(const entry of [...activityTimeline(d.events||[]).children])el('events').append(entry);
el('checks').textContent=d.checks||'';
for(const url of d.links||[]){const link=node('a','','GitHub PR #'+url.split('/').pop()+' ↗');link.href=url;link.target='_blank';link.rel='noopener';el('links').append(link);}

const age=()=>{const stale=Date.now()-new Date(d.checkedAt)>150000;el('observer').textContent=stale?'Updates delayed':'';el('observer').className=stale?'warning':'';};age();setInterval(age,15000);
requestAnimationFrame(()=>{
  for(const list of document.querySelectorAll('[data-scroll-key]'))list.scrollTop=saved.columns?.[list.dataset.scrollKey]||0;
  document.querySelector('.board-scroll').scrollLeft=saved.boardX||0;
  if(saved.pageY)window.scrollTo({top:saved.pageY,behavior:'instant'});
});
function saveView(){try{sessionStorage.setItem(localStateKey,JSON.stringify({pageY:scrollY,boardX:document.querySelector('.board-scroll').scrollLeft,
  columns:Object.fromEntries([...document.querySelectorAll('[data-scroll-key]')].map(list=>[list.dataset.scrollKey,list.scrollTop])),
  open:[...document.querySelectorAll('details[data-history-key][open]')].map(details=>details.dataset.historyKey)}));}catch{}}
const refresh=()=>{if(phaseDialog.open){setTimeout(refresh,4000);return;}saveView();const url=new URL(location.href);url.searchParams.set('progressRefresh',Date.now().toString());location.replace(url.href);};
setTimeout(refresh,Math.max(5000,new Date(d.nextCheckAt).getTime()-Date.now()+2000));
// Job state is independent of the slower plan/session snapshot above.
const modelNames={
  'gpt-6.1-sol':'GPT-6.1 Sol', 'gpt-6-astra':'GPT-6 Astra',
  'gpt-6.1-astra':'GPT-6.1 Astra', 'codex-review-bot':'Codex review',
  'claude-opus-5-5':'Claude Opus 5.5',
  'opencode-go/deepseek-v4.1-flash':'DeepSeek V4.1 Flash',
  'opencode-go/muse-spark-1.3-contributor':'Muse Spark 1.3'
};
function providerMark(provider){
  const wrapper=node('span','provider-mark');
  const name=provider==='anthropic'?'Anthropic':provider==='openai'?'OpenAI':provider==='deepseek'?'DeepSeek':provider==='muse'?'Muse':provider||'Unknown provider';
  wrapper.setAttribute('role','img');wrapper.setAttribute('aria-label',name);
  // Static monochrome marks; job data is always inserted as text.
  if(provider==='anthropic')wrapper.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="currentColor" d="M5.1 4h3.6l7 16h-3.9l-1.4-3.5H4.9L3.5 20H0L7 4H5.1Zm.9 9.5h3.2L7.6 9.4 6 13.5ZM15.2 4H19l5 16h-3.8L15.2 4Z"/></svg>';
  else if(provider==='openai')wrapper.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round" aria-hidden="true"><g><path d="M12 3c-4-3-9 1-7 5l7 4 5-3V4c0-4-6-5-8-1" transform="translate(0 2) scale(.86)"/><path d="M12 3c-4-3-9 1-7 5l7 4 5-3V4c0-4-6-5-8-1" transform="rotate(60 12 12) translate(0 2) scale(.86)"/><path d="M12 3c-4-3-9 1-7 5l7 4 5-3V4c0-4-6-5-8-1" transform="rotate(120 12 12) translate(0 2) scale(.86)"/><path d="M12 3c-4-3-9 1-7 5l7 4 5-3V4c0-4-6-5-8-1" transform="rotate(180 12 12) translate(0 2) scale(.86)"/><path d="M12 3c-4-3-9 1-7 5l7 4 5-3V4c0-4-6-5-8-1" transform="rotate(240 12 12) translate(0 2) scale(.86)"/><path d="M12 3c-4-3-9 1-7 5l7 4 5-3V4c0-4-6-5-8-1" transform="rotate(300 12 12) translate(0 2) scale(.86)"/></g></svg>';
  else wrapper.textContent=name;
  return wrapper;
}
const duration=seconds=>{
  const value=Math.max(0,Math.floor(seconds));
  if(!Number.isFinite(value))return '—';
  return value<60?value+'s':value<3600?Math.floor(value/60)+'m '+value%60+'s':Math.floor(value/3600)+'h '+Math.floor(value%3600/60)+'m';
};
function jobLabels(job){
  const labels=node('div','job-labels');
  labels.append(providerMark(job.provider||(/^(gpt-|codex-)/.test(job.model||'')?'openai':/deepseek/.test(job.model||'')?'deepseek':/muse/.test(job.model||'')?'muse':/^claude/.test(job.model||'')?'anthropic':'')),node('span','job-pill',modelNames[job.model]||job.model||'Unknown model'));
  if(job.effort)labels.append(node('span','job-pill',job.effort));
  return labels;
}
function renderJobs(data){
  const now=Date.now();
  const running=data.jobs.filter(job=>job.status==='running');
  renderBoard(data.jobs);
  console.log('kanban-check',JSON.stringify({columns:Object.fromEntries(Object.keys(states).map(key=>[key,[...taskByNumber.values()].filter(t=>t.column===key).length])),running:running.map(job=>job.plan),phaseCards:document.querySelectorAll('.phase-card').length}));
  const fragment=document.createDocumentFragment();
  for(const job of [...running].sort((a,b)=>Number(a.plan)-Number(b.plan))){
    const number=Number(job.plan);const task=taskByNumber.get(number);
    const card=node('article','job-card'+(job.stalled?' job-stalled':''));card.dataset.jobId=job.id;
    card.append(node('span','pr-number',number?'PR '+number:'Dashboard helper'),
      node('h3','job-plan',task?cleanTitle(task.title):number?'Plan title unavailable':'Dashboard helper'),
      node('strong','job-role',isReviewJob(job)?'Reviewing':job.role==='implement'?'Coding':job.role||'Working'),
      node('span','job-elapsed',duration((now-Date.parse(job.startedAt))/1000)+' elapsed'),
      jobLabels(job),node('span','badge '+(job.stalled?'review':'active'),job.stalled?'Stalled':'Running'));
    fragment.append(card);
  }
  if(!running.length)fragment.append(node('p','muted','No running jobs.'));
  const scroll=el('running-tasks').scrollLeft;
  el('running-tasks').replaceChildren(fragment);el('running-tasks').scrollLeft=scroll;
  el('running-count').textContent=running.length+' running';
  el('status').textContent='Live · '+fmt(data.checkedAt)+' IST';
  el('status').classList.remove('warning');
}
let jobsTimer, jobsFetching=false;
async function pollJobs(){
  clearTimeout(jobsTimer);
  if(jobsFetching)return;
  jobsFetching=true;
  try{
    const response=await fetch('/jobs',{cache:'no-store',signal:AbortSignal.timeout(8000)});
    if(!response.ok)throw new Error('Job endpoint '+response.status);
    renderJobs(await response.json());
  }catch(error){
    console.error('Live jobs render failed',error);
    el('status').textContent='Live jobs unavailable · retrying';el('status').classList.add('warning');
  }finally{
    jobsFetching=false;
    if(!document.hidden)jobsTimer=setTimeout(pollJobs,4000);
  }
}
document.addEventListener('visibilitychange',()=>{clearTimeout(jobsTimer);if(!document.hidden)pollJobs();});
pollJobs();

// Render the snapshot after polling has been started, even in a hidden browser tab.
renderBoard([]);
