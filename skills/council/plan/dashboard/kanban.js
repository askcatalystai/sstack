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
    card.append(node('span','phase-number',String(phase.number)),node('h3','',cleanTitle(phase.title)),node('span','phase-card-status'));
    card.addEventListener('click',()=>openPhaseDialog(card,phase));grid.append(card);
  }
  for(const card of grid.children){
    const items=tasks.filter(task=>String(task.phase)===card.dataset.phase);
    const merged=items.filter(task=>task.done&&!task.reverted).length;
    const active=items.filter(task=>task.active).length;
    card.classList.toggle('is-active',active>0);
    card.querySelector('.phase-card-status').textContent=merged+' / '+items.length+(active?' · '+active+' live':'');
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
  card.classList.toggle('is-active',Boolean(task.active));
  card.setAttribute('aria-haspopup','dialog');
  const header=node('div','task-header');header.append(node('span','pr-number',String(task.number)),phaseLabel(task));
  if(task.jobs?.length){
    const stack=node('span','agent-stack');
    for(const job of task.jobs){const mark=providerMark(job.provider,job.model);mark.title=(job.model||'')+(job.effort?' · '+job.effort:'');stack.append(mark);}
    header.append(stack);
  }
  card.append(header,node('h4','',cleanTitle(task.title)));
  const link=githubLink(task);
  if(link){const footer=node('div','task-footer');footer.append(link);card.append(footer);}
  card.addEventListener('click',event=>{if(!link?.contains(event.target)&&!event.target.closest('.phase-label'))openTaskDialog(card,task);});
  card.addEventListener('keydown',event=>{if((event.key==='Enter'||event.key===' ')&&event.target===card){event.preventDefault();openTaskDialog(card,task);}});
  return card;
}

el('status').textContent='…';
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
    for(const task of next){
      const li=node('li','next-item');li.dataset.nextNumber=task.number;
      const open=node('button','mini-card');open.type='button';
      open.setAttribute('aria-haspopup','dialog');open.setAttribute('aria-label','PR '+task.number+' · '+cleanTitle(task.title));
      open.append(node('span','pr-number',String(task.number)),node('span','mini-title',cleanTitle(task.title)));
      open.addEventListener('click',()=>openTaskDialog(open,taskByNumber.get(task.number)||task));
      li.append(open);el('next-tasks').append(li);
    }
  }
  renderPhases(tasks);
  el('board-totals').textContent=counts.merged+' / '+tasks.length;
}
el('checked').textContent=fmt(d.checkedAt);
el('activity-time').textContent=d.lastEventAt?fmt(d.lastEventAt):'';
el('events').classList.add('activity-timeline');
for(const entry of [...activityTimeline(d.events||[]).children])el('events').append(entry);
el('checks').textContent=d.checks||'';
for(const url of d.links||[]){const link=node('a','','#'+url.split('/').pop()+' ↗');link.href=url;link.target='_blank';link.rel='noopener';el('links').append(link);}

const age=()=>{const stale=Date.now()-new Date(d.checkedAt)>150000;el('observer').textContent=stale?'Updates delayed':'';el('observer').className=stale?'warning':'';};age();setInterval(age,15000);
// Phases and activity live in a right sheet, collapsed by default; its state survives the auto-refresh.
const sheet=el('side-sheet'),sheetToggle=el('sheet-toggle');
function setSheet(open){
  sheet.hidden=!open;sheetToggle.setAttribute('aria-expanded',String(open));
  document.body.classList.toggle('sheet-open',open);
  if(open)el('sheet-close').focus({preventScroll:true});
}
sheetToggle.addEventListener('click',()=>setSheet(sheet.hidden));
el('sheet-close').addEventListener('click',()=>{setSheet(false);sheetToggle.focus({preventScroll:true});});
document.addEventListener('keydown',event=>{if(event.key==='Escape'&&!sheet.hidden&&!phaseDialog.open){setSheet(false);sheetToggle.focus({preventScroll:true});}});
setSheet(Boolean(saved.sheet));
requestAnimationFrame(()=>{
  for(const list of document.querySelectorAll('[data-scroll-key]'))list.scrollTop=saved.columns?.[list.dataset.scrollKey]||0;
  if(saved.sheetY)document.querySelector('.sheet-body').scrollTop=saved.sheetY;
  document.querySelector('.board-scroll').scrollLeft=saved.boardX||0;
  if(saved.pageY)window.scrollTo({top:saved.pageY,behavior:'instant'});
});
function saveView(){try{sessionStorage.setItem(localStateKey,JSON.stringify({pageY:scrollY,boardX:document.querySelector('.board-scroll').scrollLeft,
  sheet:!sheet.hidden,sheetY:document.querySelector('.sheet-body').scrollTop,
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
// Official brand marks (simple-icons; OpenAI's own mark), picked from the model id; job data is inserted as text.
const BRAND_MARKS={"claude": {"d": "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z", "viewBox": "0 0 24 24", "color": "#D97757"}, "openai": {"d": "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z", "viewBox": "0 0 24 24", "color": "#ffffff"}, "deepseek": {"d": "M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.828-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.003-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.231 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3.101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113.074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.25 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-.156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45", "viewBox": "0 0 24 24", "color": "#4D6BFE"}, "meta": {"d": "M6.915 4.03c-1.968 0-3.683 1.28-4.871 3.113C.704 9.208 0 11.883 0 14.449c0 .706.07 1.369.21 1.973a6.624 6.624 0 0 0 .265.86 5.297 5.297 0 0 0 .371.761c.696 1.159 1.818 1.927 3.593 1.927 1.497 0 2.633-.671 3.965-2.444.76-1.012 1.144-1.626 2.663-4.32l.756-1.339.186-.325c.061.1.121.196.183.3l2.152 3.595c.724 1.21 1.665 2.556 2.47 3.314 1.046.987 1.992 1.22 3.06 1.22 1.075 0 1.876-.355 2.455-.843a3.743 3.743 0 0 0 .81-.973c.542-.939.861-2.127.861-3.745 0-2.72-.681-5.357-2.084-7.45-1.282-1.912-2.957-2.93-4.716-2.93-1.047 0-2.088.467-3.053 1.308-.652.57-1.257 1.29-1.82 2.05-.69-.875-1.335-1.547-1.958-2.056-1.182-.966-2.315-1.303-3.454-1.303zm10.16 2.053c1.147 0 2.188.758 2.992 1.999 1.132 1.748 1.647 4.195 1.647 6.4 0 1.548-.368 2.9-1.839 2.9-.58 0-1.027-.23-1.664-1.004-.496-.601-1.343-1.878-2.832-4.358l-.617-1.028a44.908 44.908 0 0 0-1.255-1.98c.07-.109.141-.224.211-.327 1.12-1.667 2.118-2.602 3.358-2.602zm-10.201.553c1.265 0 2.058.791 2.675 1.446.307.327.737.871 1.234 1.579l-1.02 1.566c-.757 1.163-1.882 3.017-2.837 4.338-1.191 1.649-1.81 1.817-2.486 1.817-.524 0-1.038-.237-1.383-.794-.263-.426-.464-1.13-.464-2.046 0-2.221.63-4.535 1.66-6.088.454-.687.964-1.226 1.533-1.533a2.264 2.264 0 0 1 1.088-.285z", "viewBox": "0 0 24 24", "color": "#0467DF"}};
function brandFor(model,provider){
  const m=String(model||'').toLowerCase(),p=String(provider||'').toLowerCase();
  if(/claude|opus|sonnet|haiku|fable/.test(m)||p==='anthropic'||p.startsWith('claude'))return ['claude','Anthropic'];
  if(/deepseek/.test(m)||p==='deepseek')return ['deepseek','DeepSeek'];
  if(/muse/.test(m)||p==='muse'||p==='meta')return ['meta','Meta'];
  if(/^gpt|codex|sol|astra|terra|luna/.test(m)||p==='openai'||p==='codex')return ['openai','OpenAI'];
  return [null,provider||'Model'];
}
const MODEL_SHORT=[[/sol/,'Sol'],[/astra/,'Astra'],[/terra/,'Terra'],[/luna/,'Luna'],[/deepseek/,'DeepSeek'],[/muse/,'Muse'],[/opus/,'Opus'],[/sonnet/,'Sonnet'],[/haiku/,'Haiku'],[/fable/,'Fable']];
function modelShort(model){const m=String(model||'').toLowerCase();return (MODEL_SHORT.find(([re])=>re.test(m))||[,model||''])[1];}
function providerMark(provider,model){
  const [key,name]=brandFor(model,provider);
  const wrapper=node('span','provider-mark');
  wrapper.setAttribute('role','img');wrapper.setAttribute('aria-label',name);wrapper.title=name;
  const icon=key&&BRAND_MARKS[key];
  if(icon){
    const svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.setAttribute('viewBox',icon.viewBox);svg.setAttribute('aria-hidden','true');
    const path=document.createElementNS('http://www.w3.org/2000/svg','path');path.setAttribute('d',icon.d);path.setAttribute('fill',icon.color);
    svg.append(path);wrapper.append(svg);
  }else wrapper.textContent=name;
  return wrapper;
}
// Logo, short model name and reasoning level, as one compact chip.
function modelChip(job){
  const chip=node('span','model-chip');
  chip.append(providerMark(job.provider,job.model),node('span','model-name',modelShort(job.model)));
  if(job.effort)chip.append(node('span','model-effort',job.effort));
  chip.title=(job.model||'')+(job.effort?' · '+job.effort:'');
  return chip;
}
const duration=seconds=>{
  const value=Math.max(0,Math.floor(seconds));
  if(!Number.isFinite(value))return '—';
  return value<60?value+'s':value<3600?Math.floor(value/60)+'m '+value%60+'s':Math.floor(value/3600)+'h '+Math.floor(value%3600/60)+'m';
};
function jobLabels(job){
  const labels=node('div','job-labels');labels.append(modelChip(job));return labels;
}
function renderJobs(data){
  const now=Date.now();
  const running=data.jobs.filter(job=>job.status==='running');
  renderBoard(data.jobs);
  console.log('kanban-check',JSON.stringify({columns:Object.fromEntries(Object.keys(states).map(key=>[key,[...taskByNumber.values()].filter(t=>t.column===key).length])),running:running.map(job=>job.plan),phaseCards:document.querySelectorAll('.phase-card').length}));
  const fragment=document.createDocumentFragment();
  for(const job of [...running].sort((a,b)=>Number(a.plan)-Number(b.plan))){
    const number=Number(job.plan);const task=taskByNumber.get(number);
    const card=node('button','agent-card'+(job.stalled?' job-stalled':''));card.type='button';card.dataset.jobId=job.id;
    const title=task?cleanTitle(task.title):'Helper';
    const role=isReviewJob(job)?'Review':job.role==='implement'?'Code':'Work';
    card.setAttribute('aria-label','PR '+number+' · '+title+' · '+role+' · '+(job.model||''));
    const top=node('div','agent-top');top.append(node('span','agent-title',title),node('span','agent-time',duration((now-Date.parse(job.startedAt))/1000)));
    const meta=node('div','agent-meta');meta.append(node('span','pr-number',number?'#'+number:'·'),node('span','agent-role agent-role-'+role.toLowerCase(),role),modelChip(job));
    card.append(top,meta);
    if(task)card.addEventListener('click',()=>openTaskDialog(card,taskByNumber.get(number)||task));
    fragment.append(card);
  }
  if(!running.length)fragment.append(node('p','muted','Idle'));
  const scroll=el('running-tasks').scrollLeft;
  el('running-tasks').replaceChildren(fragment);el('running-tasks').scrollLeft=scroll;
  el('running-count').textContent=running.length||'';
  el('status').textContent=fmt(data.checkedAt);
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
