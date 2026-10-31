#!/usr/bin/env python3
"""Read the plan file, the agent session and cm.sh's per-PR state, and render the progress board.

Settings come from <state dir>/config.json, written by `cm.sh init`. The state dir is
$COUNCIL_STATE, or the plan that `cm.sh init` made current."""
import argparse
import datetime as dt
import json
import html
import os
from pathlib import Path
import re
import subprocess
import time

HERE = Path(__file__).resolve().parent
STATE = Path(os.environ.get('COUNCIL_STATE') or (Path.home()/'.local/state/council/current')).resolve()
CONFIG = json.loads((STATE/'config.json').read_text())
REPO = Path(CONFIG['repo'])
PLAN = CONFIG['plan']
TITLE = CONFIG.get('title') or Path(PLAN).stem
GH_PULL = re.escape(f"https://github.com/{CONFIG['gh']}/pull/") + r'\d+'
DATA = STATE/'dashboard'
DATA.mkdir(parents=True, exist_ok=True)
PIPELINE = STATE/'state'
INTERVAL = 60

def iso(timestamp=None):
    return dt.datetime.fromtimestamp(timestamp or time.time(),dt.timezone.utc).isoformat()

def atomic(path, text):
    temp = path.with_suffix(path.suffix+'.tmp')
    temp.write_text(text)
    temp.replace(path)

def git(*args):
    return subprocess.check_output(['git', '-C', str(REPO), *args], text=True,timeout=10).strip()

def plan_numbers(text):
    """Plan numbers omit '#'; GitHub PR numbers are a different namespace."""
    return [int(m[1]) for m in re.finditer(r'\bPR\s+(\d+)\b', text)
            if not re.match(r'\s*[–—-]\s*\d', text[m.end():])]

def delivery_stage(text):
    if re.search(r'\bgh pr merge\b|\bmerging\b',text,re.I):return 4
    if re.search(r'\bgh pr create\b|\b(?:opening|creating|filing)\b.{0,30}\b(?:pr|pull request)\b',text,re.I):return 3
    if re.search(r'sol.loop|review|waiting.*astra|astra.*round',text,re.I):return 2
    if re.search(r'\btests?\b|typecheck|eslint|lint|\bchecks\b',text,re.I):return 1
    return 0

def latest_task_update(history):
    """Keep unrelated research/proposal prose out of a task's live status."""
    for entry in reversed(history):
        if entry.get('explicit') or re.search(r'review|codex|astra|\bsol\b|\btests?\b|typecheck|opening|merged|starting|working|fixing|deploy|waiting|paused|blocked',entry['text'],re.I):
            return entry
    return history[-1] if history else None

def plain_summary(text):
    """Compact plain text from the first Markdown bullet in a planned PR."""
    text = re.sub(r'!?\[([^\]]*)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'<[^>]+>', '', text)
    text = re.sub(r'[`*_~]', '', text)
    text = re.sub(r'\\([\[\]{}()#+.!>\-])', r'\1', text)
    text = ' '.join(html.unescape(text).split())
    return text if len(text) <= 110 else text[:109].rstrip() + '…'

def parse_plan(text):
    phases, items, current_phase, current_item = [], [], None, None
    for line_number, line in enumerate(text.splitlines(), 1):
        if re.match(r'^#{1,6} ', line):
            current_item = None
        p = re.match(r'^## Phase (\d+(?:\.\d+)?) — (.+)', line)
        if p:
            current_phase = {'number':float(p[1]) if '.' in p[1] else int(p[1]),
                'title':p[2], 'total':0, 'completed':0, 'active':False}
            phases.append(current_phase)
        m = re.match(r'^#{3,6} \[([ xX~])\] PR (\d+) — (.+)', line)
        if m and current_phase:
            current_item = {'number':int(m[2]), 'title':m[3],
                'done':m[1].lower() in ('x','~'), 'reverted':m[1]=='~',
                'summary':'', 'details':'', 'lineNumber':line_number, 'phase':current_phase['number']}
            items.append(current_item)
            current_phase['total'] += 1
            current_phase['completed'] += current_item['done']
        elif current_item:
            current_item['details'] = (current_item['details'] + line + '\n')[:6000]
            if not current_item['summary']:
                bullet = re.match(r'^\s*[-*+]\s+(.+)', line)
                if bullet:
                    current_item['summary'] = plain_summary(bullet[1])
    return phases, items

def board_data(phases, active_numbers, stage):
    """Read-only columns: Markdown owns closed outcomes; session owns live activity."""
    tasks=[]
    for phase in phases:
        for item in phase['items']:
            active=item['number'] in active_numbers and not item['done']
            task_stage=item.get('stage',stage)
            column='reverted' if item.get('reverted') else 'merged' if item['done'] else 'review' if active and task_stage in [2,3,4] else 'progress' if active else 'backlog'
            tasks.append({**item,'active':active,'column':column,'phaseTitle':phase['title'],
                          'status':'Reverted' if item.get('reverted') else 'Merged' if item['done'] else item['status'] if active or item['status'] in ('Stopped','Needs attention') else 'Queued'})
    running=[task for task in tasks if task['active']]
    active_phases={task['phase'] for task in running}
    # Finish the current phase before resuming earlier unfinished tasks, such as PR 11.
    queued=[task for task in tasks if task['column']=='backlog']
    queue=[task for task in queued if task['phase'] in active_phases]+[task for task in queued if task['phase'] not in active_phases]
    return {'tasks':tasks,'runningNumbers':[task['number'] for task in running],
            'queueNumbers':[task['number'] for task in queue],'nextNumbers':[task['number'] for task in queue[:3]],
            'counts':{key:sum(task['column']==key for task in tasks) for key in ['backlog','progress','review','merged','reverted']}}

def linked_plan_number(description, command, context_number):
    """Never treat a gh command's GitHub PR number as a plan identifier."""
    explicit = re.search(r'\bplan PR\s+(\d+)\b', description, re.I)
    if explicit:
        return int(explicit[1])
    numbers = plan_numbers(description)
    number = numbers[-1] if numbers else context_number
    github_number = re.search(r'\bgh pr (?:view|merge)\s+(?:https://github\.com/[^/]+/[^/]+/pull/)?(\d+)\b', command)
    if github_number and number == int(github_number[1]):
        return None
    return number


def pipeline_state():
    """Per-PR status written by the phase worktree pipeline: {plan number: (kind, text, github number)}."""
    out = {}
    for f in PIPELINE.glob('pr*') if PIPELINE.exists() else []:
        try: text = f.read_text().splitlines()[0].strip()
        except (OSError, IndexError): continue
        number = re.search(r'#?(\d{2,})', text.split(' ', 1)[1]) if ' ' in text else None
        kind = ('merged' if text.startswith('merged') else 'done' if text.startswith('nochange') else
                'stopped' if text.startswith(('stopped', 'paused', 'queued')) else
                'blocked' if text.startswith(('blocked', 'needs-attention')) else 'open' if text.startswith('opened') else
                'review' if text.startswith('review') else 'coding')
        gh = int(number[1]) if number and kind in ('merged', 'open') else None
        out[int(f.name[2:])] = (kind, text, gh)
    return out

def transcript_path():
    """The configured transcript, else the newest agent session for the repo."""
    if CONFIG.get('transcript'):
        return Path(CONFIG['transcript'])
    root = Path.home()/'.claude/projects'
    candidates = list((root/('-'+re.sub(r'[^a-zA-Z0-9-]', '-', str(REPO).lstrip('/')))).glob('*.jsonl'))
    if not candidates:
        candidates = list(root.glob('*/*.jsonl'))
    if not candidates:
        raise RuntimeError('No agent session transcript found; set one with `cm.sh dashboard --transcript <path>`')
    return max(candidates, key=lambda path: path.stat().st_mtime)

def collect():
    transcript = transcript_path()
    session_id = transcript.stem
    phases, items = parse_plan((REPO/PLAN).read_text())
    # Phase worktrees tick the plan only when a phase finishes; their own status is fresher.
    pipe = pipeline_state()
    for item in items:
        if item['number'] in pipe and pipe[item['number']][0] in ('merged', 'done') and not item['done']:
            item['done'] = True
    for phase in phases:
        phase['completed'] = sum(i['done'] for i in items if i['phase'] == phase['number'])
    for phase in phases:
        phase_items=[item for item in items if item['phase']==phase['number']]
        phase['firstNumber']=min((item['number'] for item in phase_items),default=None)
        phase['lastNumber']=max((item['number'] for item in phase_items),default=None)
        phase['nextNumber']=next((item['number'] for item in phase_items if not item['done']),None)
    texts,events,pending,plan = [],[],{},[]
    item_by_number={item['number']:item for item in items}
    updates={item['number']:[] for item in items}
    item_links={}
    context_number=next((item['number'] for item in items),None)
    last_event = None
    for line in transcript.open():
        try:r=json.loads(line)
        except json.JSONDecodeError:continue
        if r.get('type') not in ['assistant','user']:continue
        msg=r.get('message',{});content=msg.get('content',[]) if isinstance(msg,dict) else []
        timestamp=r.get('timestamp')
        if timestamp:last_event=timestamp
        if isinstance(content,str):content=[{'type':'text','text':content}]
        for block in content:
            if not isinstance(block,dict):continue
            kind=block.get('type')
            if kind=='tool_use':
                inp=block.get('input',{})
                numbers=plan_numbers(inp.get('description',''))
                tool_number=next((n for n in numbers if n in item_by_number),None)
                pending[block['id']]={'name':block.get('name',''),'description':inp.get('description',''),'command':inp.get('command',''),'timestamp':timestamp,'planNumber':tool_number}
                if block.get('name','').endswith('update_plan'):plan=inp.get('items',[])
            elif kind=='tool_result':
                tool=pending.pop(block.get('tool_use_id'),{})
                result=block.get('content','')
                result_text=result if isinstance(result,str) else json.dumps(result)
                urls=re.findall(GH_PULL,result_text)
                # A create/view/merge command establishes an exact link to the current fix.
                if urls and re.search(r'\bgh pr (create|view|merge)\b',tool.get('command','')) and tool.get('planNumber'):
                    linked = linked_plan_number(tool.get('description',''), tool.get('command',''), tool['planNumber'])
                    if linked in item_by_number:
                        item_links[linked]=urls[-1]
            elif kind=='text' and r.get('type')=='assistant':
                text=block.get('text','').strip()
                if text:
                    texts.append(text)
                    events.append({'time':timestamp or iso(transcript.stat().st_mtime),'text':text[:320]})
                    has_proposal_table=any(line.lstrip().startswith('|') for line in text.splitlines())
                    for sentence in re.split(r'(?<=[.!?])\s+(?=[A-Z`])|\n+',text):
                        if sentence.lstrip().startswith('|'):continue
                        numbers=[n for n in plan_numbers(sentence) if n in item_by_number]
                        targets=numbers
                        for n in dict.fromkeys(targets):
                            updates[n].append({'time':timestamp or iso(transcript.stat().st_mtime),'text':sentence[:500],'explicit':bool(numbers)})
                        if numbers:context_number=numbers[-1]
    active=next((p.get('content','') for p in plan if p.get('status')=='in_progress'),'')
    match=re.search(r'\bPR\s*(\d+)\b',active)
    candidate=int(match[1]) if match else None
    active_numbers=[]
    for entry in plan:
        if entry.get('status')=='in_progress':
            active_numbers.extend(n for n in plan_numbers(entry.get('content','')) if n in item_by_number and not item_by_number[n]['done'])
    # The desktop's initial task list may still say PR 1 after PR 1 is merged.
    # Never present a checked-off item as the current unfinished fix.
    live_pipe=[n for n,(kind,_,_) in pipe.items() if kind in ('coding','review','open') and n in item_by_number and not item_by_number[n]['done']]
    number=candidate if candidate in item_by_number and not item_by_number[candidate]['done'] else (active_numbers or live_pipe or [None])[0]
    item=next((i for i in items if i['number']==number),None)
    phase=next((p for p in phases if item and p['number']==item['phase']),None)
    if phase:phase['active']=True
    latest=next(reversed(pending.values()),{}) if pending else {}
    current_updates=updates.get(number,[])
    tool_is_current=bool(latest.get('planNumber')==number and number in plan_numbers(latest.get('description','')) and latest.get('timestamp')
                         and (not current_updates or latest['timestamp']>=current_updates[-1]['time']))
    if tool_is_current:
        current_updates.append({'time':latest['timestamp'],'text':latest['description'][:500]})
    current_update=latest_task_update(current_updates)
    current_note=current_update['text'] if current_update else ''
    description=latest['description'] if tool_is_current else current_note or (texts[-1][:240] if texts else 'Waiting for session activity')
    stage=delivery_stage(latest.get('command','')+' '+description) if tool_is_current else delivery_stage(current_note)
    if stage==0 and not re.search(r'implement|fixing|editing|writing|coding|committing',description,re.I):
        for update in reversed(current_updates[-6:]):
            evidence=delivery_stage(update['text'])
            if evidence or re.search(r'implement|fixing|editing|writing|coding|committing',update['text'],re.I):
                stage=evidence;break
    seconds=time.time()-transcript.stat().st_mtime
    if seconds>1200:status='No recent session activity'
    elif pending:status='Running checks' if stage==1 else 'Reviewing' if stage==2 else 'Working'
    elif seconds>90:status='Waiting / idle'
    else:status='Working'
    combined='\n'.join(texts)
    links=list(dict.fromkeys(re.findall(GH_PULL,combined)))[-3:]
    checks='Baseline lint failures reported by Claude; they are separate from this fix’s checks.' if re.search(r'lint already|pre.existing.*lint',combined,re.I) else ''
    stage_labels=['Implementing','Testing','In review','Opening PR','Merging']
    pipe_stage={'coding':0,'review':2,'open':2}
    active_numbers=list(dict.fromkeys(active_numbers+[n for n,(kind,_,_) in pipe.items() if kind in pipe_stage and n in item_by_number and not item_by_number[n]['done']]))
    for p in phases:
        p['items']=[]
        for planned in (i for i in items if i['phase']==p['number']):
            history=updates[planned['number']]
            active_item=planned['number'] in active_numbers
            last=latest_task_update(history)
            planned_stage=stage if planned['number']==number else delivery_stage(last['text']) if last else 0
            note=last['text'] if last else 'Marked merged in the plan.' if planned['done'] else 'No session update yet.'
            if planned['number'] in pipe:
                kind,text,gh=pipe[planned['number']]
                note=f'Pipeline: {text}'
                if kind in pipe_stage: planned_stage=pipe_stage[kind]
                if gh: item_links[planned['number']]=f"https://github.com/{CONFIG['gh']}/pull/{gh}"
            p['items'].append({**planned,'active':active_item,'stage':planned_stage,'status':'Merged' if planned['done'] else stage_labels[planned_stage] if active_item else {'stopped':'Stopped','blocked':'Needs attention'}.get(pipe.get(planned['number'],('',))[0],'Queued'),
                'latestUpdate':note,'updatedAt':last['time'] if last else None,'history':history[-6:],'url':item_links.get(planned['number']),'urlSource':'item_links' if planned['number'] in item_links else None})
    return {'checkedAt':iso(),'nextCheckAt':iso(time.time()+INTERVAL),'status':status,'currentNumber':number,'currentTitle':item['title'] if item else active,'currentPhase':f"Phase {phase['number']} · {phase['title']}" if phase else '', 'activity':description[:300], 'stage':stage,'branch':git('branch','--show-current'),'completed':sum(i['done'] for i in items),'total':len(items),'phases':phases,'board':board_data(phases,active_numbers,stage),'lastEventAt':last_event,'events':events[-3:],'checks':checks,'links':links,'sessionId':session_id,'transcript':str(transcript)}

def page_html(snapshot):
    data=json.dumps(snapshot,ensure_ascii=False).replace('<','\\u003c')
    page=(HERE/'kanban.html').read_text().replace('{{TITLE}}',html.escape(TITLE)).replace('{{PLAN}}',html.escape(PLAN))
    page=page.replace('<script id="progress-data" type="application/json">{}</script>','<script id="progress-data" type="application/json">'+data+'</script>')
    script=(HERE/'kanban.js').read_text().replace('/* HOVER_DETAILS */',(HERE/'hover-details.js').read_text())
    return page.replace('/* KANBAN */',script)

def render(snapshot):
    atomic(DATA/'snapshot.json',json.dumps(snapshot,indent=2))
    atomic(DATA/'progress.html',page_html(snapshot))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--once',action='store_true');args=parser.parse_args()
    if not args.once:atomic(DATA/'observer.pid',str(os.getpid()))
    snapshot={}
    while True:
        try:
            snapshot=collect();render(snapshot)
            print(iso(),snapshot['status'],snapshot['currentNumber'],flush=True)
        except Exception as error:
            print(iso(),type(error).__name__,str(error),flush=True)
            if (DATA/'snapshot.json').exists():
                snapshot=json.loads((DATA/'snapshot.json').read_text());snapshot['error']='Observer could not read current session data';render(snapshot)
            if args.once:raise
        if args.once:return
        if snapshot.get('total') and snapshot.get('completed')==snapshot['total']:return
        time.sleep(INTERVAL)

if __name__=='__main__':main()
