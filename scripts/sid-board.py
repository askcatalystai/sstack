#!/usr/bin/env python3
"""Derive Kanzo progress from local workers, PRs, train and deployment facts.

board.json is a list of {workspace, repo} and/or {project, repo} mappings.
--config selects another file. Dry runs never write board or watchdog state.
Missing sources are represented by None, distinct from a successful empty result.
"""
import argparse
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import kanzo_client as kanzo

ACTIVE = ('doing', 'review', 'deployment')
DERIVED = {'queued', 'gating', 'merging', 'deploying', 'scrapped', 'needs-you', 'stale'}


def seconds(value):
    return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp() if value else 0


def stamp(now):
    return dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat()


def age(start, now):
    m = max(0, int((now - seconds(start)) // 60))
    if m < 1:
        return '<1m'
    if m < 60:
        return f'{m}m'
    if m < 1440:
        return f'{m // 60}h' + (f' {m % 60}m' if m % 60 else '')
    return f'{m // 1440}d' + (f' {m % 1440 // 60}h' if m % 1440 // 60 else '')


def token(key, text):
    return bool(re.search(r'(?<![\w#-])' + re.escape(key) + r'(?![\w#])', text, re.I))


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def root(thread):
    return thread.get('root') or thread['id']


def body_declares(key, body):
    item = r'[\w-]+#\d+(?![\w#])'
    for declaration in re.finditer(r'\bKanzo\s+' + item + r'(?:(?:\s*,\s*(?:and\s+)?|\s+and\s+)' + item + r')*', body, re.I):
        if token(key, declaration.group()):
            return True
    return False


def choose_pr(card, prs):
    matches = [p for p in prs if f"pr-{p['number']}" in card.get('tags', []) or
               token(card['key'], ' '.join(p.get(k, '') or '' for k in ('title', 'headRefName'))) or
               body_declares(card['key'], p.get('body') or '')]
    opens = [p for p in matches if p['state'] == 'OPEN']
    # An unqueued open PR still needs review; a train member is further along.
    return (min(opens, key=lambda p: (p.get('phase') in ('queued', 'gating', 'merging'), p['number']))
            if opens else max(matches, key=lambda p: p.get('updatedAt', ''), default=None))


def reconcile(facts, previous, now):
    """Pure reconciliation: return board actions, next state, status rows, stalled roots.

    Per-repo PR/train/deploy failures retain the affected tags and columns. Unknown
    T3 data cannot remove needs-you/worker tags or declare a card/thread idle.
    """
    state = copy.deepcopy(previous)
    actions, rows, idle_by_root = [], [], {}
    threads = facts.get('threads')
    by_id = {t['id']: t for t in threads or []}
    pending = {root(t) for t in threads or [] if t.get('pending')}
    running_roots = {root(t) for t in threads or [] if t.get('run') == 'running'}
    for card in facts.get('cards', []):
        key = card['key']
        if card['status'] in ('done', 'backlog') or card.get('human'):
            continue
        rec = state.setdefault(key, {})
        old_tags = card.get('tags', [])
        tags = [x for x in old_tags if x != 'stale']
        status = card['status']
        repo = facts.get('repos', {}).get(card.get('repo'), {})
        prs = repo.get('prs')
        pr = choose_pr(card, prs) if prs is not None else None
        workers = sorted([t for t in threads or [] if t.get('parent') and token(key, t['title'])],
                         key=lambda t: t.get('activity', 0))
        if workers:
            rec['owner'] = root(workers[-1])
        if pr:
            linked = [t for t in threads or [] if [repo.get('name'), pr['number']] in t.get('prs', [])]
            if linked:
                rec['owner'] = root(max(linked, key=lambda t: t.get('activity', 0)))
        owner = rec.get('owner', '')
        running = [t for t in threads or [] if t.get('run') == 'running' and token(key, t['title'])]
        working = [t for t in running if t.get('parent')]
        what = ''
        if threads is not None:
            tags = [x for x in tags if x not in rec.get('worker', []) and x != 'needs-you']
            rec['worker'] = sorted({str(v).lower() for t in working for v in
                                    (t.get('provider'), t.get('model'), t.get('effort')) if v and v != '-'})
            tags += rec['worker']
            if owner in pending:
                tags.append('needs-you')
            for worker in working:
                model = worker.get('model', '').lower()
                what = 'worker ' + model
                if 'terra' in model:
                    continue
                review = any(w in model for w in ('astra', 'composer')) or any(
                    w in worker['title'].lower() for w in ('review', 'bug pass', 'verify'))
                if review and status in ('todo', 'doing'):
                    status = 'review'
                elif status == 'todo':
                    status = 'doing'
        comments = []
        if pr:
            tags = tags + [f"pr-{pr['number']}"]
            if repo.get('train_ok'):
                tags = [x for x in tags if x not in ('queued', 'gating', 'merging')]
                if pr.get('phase'):
                    status, what = 'deployment', pr['phase']
                    tags.append(pr['phase'])
            if pr['state'] == 'MERGED':
                status, what = 'deployment', 'deploying'
                tags = [x for x in tags if x not in DERIVED] + ['deploying']
                sha = (pr.get('mergeCommit') or {}).get('oid', '')
                comments.append((f"merged:{pr['number']}:{sha}", f"Merged #{pr['number']} as {sha[:8]}." +
                                 ('\n' + pr['trailer'] if pr.get('trailer') else '')))
                if pr.get('live'):
                    status, what = 'done', 'live'
                    tags = [f"pr-{pr['number']}"]
                    text = (f"Merged #{pr['number']}; this repo has no deploy step." if repo.get('no_deploy') else
                            f"Live on prod: #{pr['number']} is in deploy {pr['live'][:8]}.")
                    comments.append((f"live:{pr['number']}:{sha}", text))
            elif pr['state'] == 'CLOSED':
                status = card['status']
                tags = [x for x in tags if x not in ('deploying', 'scrapped')] + ['scrapped']
                comments.append((f"closed:{pr['number']}", f"Closed #{pr['number']} without merging."))
            else:
                tags = [x for x in tags if x not in ('deploying', 'scrapped')]
        # Changes in real facts reset idle; elapsed/derived tags do not.
        fingerprint = digest([card['status'], [x for x in old_tags if x not in DERIVED and
                             not kanzo.ELAPSED.match(x) and not x.startswith('idle ')],
                             card.get('comments', []), pr, [(t['id'], t.get('run'), t.get('activity'))
                                                          for t in threads or [] if token(key, t['title'])]])
        complete = threads is not None and prs is not None and repo.get('train_ok')
        if complete:
            if rec.get('fingerprint') != fingerprint:
                rec.update(fingerprint=fingerprint, changed=now)
            tags = [x for x in tags if not x.startswith('idle ')]
            if ((status in ('doing', 'review') or
                    status == 'deployment' and pr and pr['state'] != 'MERGED') and not running and
                    not (pr or {}).get('phase') and now - rec['changed'] >= 1200):
                what = 'idle ' + age(stamp(rec['changed']), now)
                tags.append(what)
                if owner:
                    idle_by_root.setdefault(owner, []).append((key, f"{key} is in {status} with " +
                        (f"PR #{pr['number']} {pr['state'].lower()}" if pr else 'no PR') + ' and no worker running',
                        digest([status, (pr or {}).get('number'), (pr or {}).get('state'), (pr or {}).get('headRefOid')])))
        if rec.get('status') != status:
            rec.update(status=status, since=stamp(now))
        tags = [x for x in tags if not kanzo.ELAPSED.match(x)]
        if status in ACTIVE:
            tags.append(age(rec.get('since', stamp(now)), now))
        seen = state.get('_comments_seen', {}).get(key, [])
        if status != 'done' and any(c['id'] not in seen for c in kanzo.user_comments(card)):
            tags.append('new-comment')
        tags = sorted(set(tags))
        fields = {}
        if status != card['status']:
            fields['status'] = status
        if tags != old_tags:
            fields['tags'] = ', '.join(tags)
        if fields:
            actions.append({'kind': 'update', 'key': key, 'fields': fields})
        posted = rec.setdefault('posted', [])
        for event, text in comments:
            if event not in posted:
                actions.append({'kind': 'comment', 'key': key, 'body': text, 'event': event})
                posted.append(event)
        rows.append({'key': key, 'column': status, 'now': what or '-', 'pr': pr['number'] if pr else '-', 'owner': owner or '-'})

    for path, repo in facts.get('repos', {}).items():
        health = repo.get('health')
        if not health or 'process' not in facts.get('projects', []):
            continue
        title = 'Main is red: ' + repo['name'].split('/')[-1]
        existing = next((c for c in facts['cards'] if c.get('title') == title and c['key'].startswith('process#')), None)
        if existing and existing.get('human'):
            continue
        marker = '_health:' + path
        if health['result'] == 'fail':
            if not existing:
                actions.append({'kind': 'create', 'title': title, 'body': f"Main {health['sha']} failed {health['lane']}.", 'health_marker': marker, 'health_sha': health['sha']})
            else:
                if existing['status'] != 'todo':
                    actions.append({'kind': 'update', 'key': existing['key'], 'fields': {'status': 'todo'}})
                if state.get(marker) != health['sha']:
                    actions.append({'kind': 'comment', 'key': existing['key'], 'body': f"Main {health['sha']} failed {health['lane']}.", 'health_marker': marker, 'health_sha': health['sha']})
            state[marker] = health['sha']
        elif existing and existing['status'] != 'done':
            actions.append({'kind': 'update', 'key': existing['key'], 'fields': {'status': 'done'}})

    stalled = []
    for thread in threads or []:
        tid = thread['id']
        if (thread.get('parent') or thread.get('run') not in ('completed', 'failed', 'interrupted') or
                tid in running_roots or tid in pending or now - thread.get('activity', now) <= 900):
            continue
        reasons = list(idle_by_root.get(tid, []))
        for repo in facts.get('repos', {}).values():
            for pr in repo.get('prs') or []:
                if ([repo.get('name'), pr['number']] in thread.get('prs', []) and
                        ((pr['state'] == 'MERGED' and seconds(pr.get('mergedAt')) > thread.get('activity', 0)) or
                         (pr.get('failed_at', 0) > thread.get('activity', 0)))):
                    reasons.append(('', f"PR #{pr['number']} train result is {'merged' if pr['state'] == 'MERGED' else 'failed'}", digest(pr)))
        if reasons:
            stalled.append({'thread': tid, 'reason': '; '.join(r[1] for r in reasons),
                            'cards': [r[0] for r in reasons if r[0]], 'signature': digest(reasons),
                            'activity': thread.get('activity', 0)})
    return actions, state, rows, stalled


def nudges(stalled, previous, now, disabled=False):
    state = copy.deepcopy(previous)
    actions = []
    if disabled:
        return actions, state
    for item in stalled:
        record = state.setdefault('_nudges', {}).setdefault(item['thread'], {})
        if record.get('signature') != item['signature']:
            record.clear()
            record.update(signature=item['signature'], count=0, last=item['activity'])
        count = record['count']
        if count >= 3 or now - record['last'] < (900, 1800, 3600)[count]:
            continue
        actions.append({'kind': 'nudge', 'thread': item['thread'], 'body':
            'Board watchdog: this thread stopped with unfinished work. ' + item['reason'] +
            '. Run ~/.local/share/sidstack/scripts/sid-board.py status, then continue from where the work stands. '
            'If you are waiting on something that cannot wake you, say what on the card and carry on with anything unblocked.'})
        record.update(count=count + 1, last=now)
        if count == 2:
            actions += [{'kind': 'stuck', 'key': key, 'thread': item['thread']} for key in item['cards']]
    return actions, state


def command(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=True, timeout=25).stdout.strip()


def attempt(label, fn):
    try:
        return fn()
    except (Exception, SystemExit) as error:
        print(f'{label}: skipped ({str(error)[:180]})', file=sys.stderr)
        return None


def gather_threads():
    start = time.monotonic()
    db = Path('~/.t3/userdata/statev2.sqlite').expanduser()
    with sqlite3.connect(f'file:{db}?mode=ro', uri=True, timeout=1) as conn:
        conn.row_factory = sqlite3.Row
        conn.set_progress_handler(lambda: int(time.monotonic() - start > 5), 1000)
        result = []
        # Metadata only; never read messages/events from the multi-GB store.
        for row in conn.execute('SELECT thread_id,title,updated_at,payload_json FROM orchestration_v2_projection_threads WHERE archived_at IS NULL AND deleted_at IS NULL'):
            tid = row['thread_id']
            payload = json.loads(row['payload_json'])
            lineage = payload.get('lineage') or {}
            run = conn.execute('SELECT status,requested_at,completed_at,payload_json,provider_instance_id FROM orchestration_v2_projection_runs WHERE thread_id=? ORDER BY ordinal DESC LIMIT 1', (tid,)).fetchone()
            selection = (json.loads(run['payload_json']).get('modelSelection') if run else None) or payload.get('modelSelection') or {}
            options = selection.get('options') or []
            effort = (next((o['value'] for o in options if o['id'] == 'reasoningEffort'), '') if isinstance(options, list)
                      else options.get('reasoningEffort', ''))
            pending = conn.execute("SELECT 1 FROM orchestration_v2_projection_runtime_requests WHERE thread_id=? AND resolved_at IS NULL AND status NOT IN ('resolved','expired','cancelled','completed','failed') LIMIT 1", (tid,)).fetchone()
            links = conn.execute('SELECT repository,number FROM projection_thread_pull_requests WHERE thread_id=?', (tid,)).fetchall()
            result.append(dict(id=tid, title=row['title'], parent=lineage.get('parentThreadId'), root=lineage.get('rootThreadId'),
                model=selection.get('model', ''), provider=run['provider_instance_id'] if run else selection.get('instanceId'), effort=effort,
                run=run['status'] if run else None, pending=bool(pending), prs=[[p[0], p[1]] for p in links],
                activity=max(seconds(row['updated_at']), seconds(run['completed_at'] or run['requested_at']) if run else 0)))
    print(f'T3 queries: {time.monotonic() - start:.3f}s ({len(result)} active threads)', file=sys.stderr)
    return result


PR_FIELDS = 'number,state,title,body,headRefName,headRefOid,mergedAt,mergeCommit,closedAt,updatedAt'


def gather_github(path, info, cards):
    name = info['nameWithOwner']
    repo = {'name': name}
    prs = json.loads(command('gh', 'pr', 'list', '--repo', name, '--state', 'all', '--limit', '100',
                             '--json', PR_FIELDS, cwd=path))
    repo['prs'] = prs
    known = {p['number'] for p in prs}
    missing = sorted({int(tag[3:]) for card in cards if card['status'] in ACTIVE and not card.get('human')
                      for tag in card.get('tags', []) if re.fullmatch(r'pr-\d+', tag)} - known)
    # Bound historical tagged-PR lookups to 20 per repository per refresh.
    for number in missing[:20]:
        prs.append(json.loads(command('gh', 'pr', 'view', str(number), '--repo', name,
                                      '--json', PR_FIELDS, cwd=path)))
    def deployments():
        deploys = json.loads(command('gh', 'api', f'repos/{name}/deployments?per_page=20', cwd=path))
        repo['no_deploy'] = not deploys
        if not deploys:
            for pr in prs or []:
                if pr['state'] == 'MERGED':
                    pr['live'] = (pr.get('mergeCommit') or {}).get('oid')
            return
        live = None
        for deploy in deploys:
            statuses = json.loads(command('gh', 'api', f"repos/{name}/deployments/{deploy['id']}/statuses", cwd=path))
            if any(s['state'] == 'success' for s in statuses):
                live = deploy['sha']
                break
        if live:
            command('git', 'fetch', '--quiet', 'origin', cwd=path)
            for pr in prs or []:
                sha = (pr.get('mergeCommit') or {}).get('oid')
                if pr['state'] == 'MERGED' and sha:
                    check = subprocess.run(['git', 'merge-base', '--is-ancestor', sha, live], cwd=path, capture_output=True, timeout=10)
                    if check.returncode == 0:
                        pr['live'] = live
    deployments()
    for pr in prs or []:
        sha = (pr.get('mergeCommit') or {}).get('oid')
        if sha:
            message = attempt(name + ' merge trailer', lambda: command('git', 'show', '-s', '--format=%B', sha, cwd=path))
            pr['trailer'] = next((l for l in (message or '').splitlines() if l.startswith('Gate-Passed:')), '')
    branch = info['defaultBranchRef']['name']
    repo['main_sha'] = command('git', 'ls-remote', 'origin', 'refs/heads/' + branch, cwd=path).split()[0]
    return repo


def gather_repo(path, cards=()):
    cache_file = kanzo.STATE.parent / ('github-' + digest(path)[:20] + '.json')
    cache = json.loads(cache_file.read_text()) if cache_file.exists() else {}
    now = time.time()
    if now - cache.get('attempted', 0) >= 60:
        cache['attempted'] = now
        if not cache.get('info'):
            cache['info'] = attempt(path + ' repo', lambda: json.loads(command(
                'gh', 'repo', 'view', '--json', 'nameWithOwner,defaultBranchRef', cwd=path)))
        if cache.get('info'):
            fresh = attempt(path + ' GitHub', lambda: gather_github(path, cache['info'], cards))
            if fresh is not None:
                cache.update(facts=fresh, fetched=now)
        # This is a source cache, separate from cards.json and safe for dry runs.
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = cache_file.with_suffix('.tmp')
        temporary.write_text(json.dumps(cache))
        temporary.replace(cache_file)
    repo = copy.deepcopy(cache.get('facts', {})) if now - cache.get('fetched', 0) <= 600 else {}
    repo.setdefault('name', (cache.get('info') or {}).get('nameWithOwner', path))
    repo.setdefault('prs', None)
    prs = repo['prs']
    common = Path(command('git', 'rev-parse', '--git-common-dir', cwd=path))
    if not common.is_absolute():
        common = Path(path) / common
    gate = common / 'sid-gate'
    def train():
        value = json.loads((gate / 'train/state.json').read_text()) if (gate / 'train/state.json').exists() else {}
        for pr in prs or []:
            n = pr['number']
            if n in value.get('members', []) and value.get('phase') in ('gating', 'merging'):
                pr['phase'] = value['phase']
            elif (gate / f'train/queue/{n}.req').exists():
                pr['phase'] = 'queued'
            h = gate / 'health' / pr['headRefOid']
            if h.exists() and h.read_text().startswith('fail '):
                pr['failed_at'] = h.stat().st_mtime
        return True
    repo['train_ok'] = bool(attempt(repo['name'] + ' train', train))
    def health():
        sha = repo.get('main_sha')
        file = gate / 'health' / sha if sha else None
        if file and file.exists():
            result, lane = file.read_text().splitlines()[0].split(maxsplit=1)
            return dict(sha=sha, result=result, lane=lane)
    repo['health'] = attempt(repo['name'] + ' health', health)
    return repo


def gather(config):
    data = attempt('Kanzo', kanzo.export)
    facts = {'cards': [], 'projects': [], 'repos': {}, 'threads': attempt('T3', gather_threads)}
    paths = {str(Path(c['repo']).expanduser()) for c in config if c.get('repo')}
    for project in (data or {}).get('projects', []):
        slug = project['slug']
        facts['projects'].append(slug)
        mapping = next((c for c in config if c.get('project') == slug), None)
        if mapping is None:
            mapping = next((c for c in config if c.get('workspace') == project['workspace'] and not c.get('project')), {})
        path = str(Path(mapping['repo']).expanduser()) if mapping.get('repo') else None
        if path:
            paths.add(path)
        facts['cards'] += [dict(c, repo=path) for c in project['tasks']]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for path, repo in zip(sorted(paths), pool.map(lambda p: attempt(p, lambda: gather_repo(p, [c for c in facts['cards'] if c.get('repo') == p])), sorted(paths))):
            facts['repos'][path] = repo or {}
    return facts


def apply(actions, facts):
    if any(a['kind'] != 'nudge' for a in actions):
        kanzo.connect()
    for action in actions:
        kind = action['kind']
        if kind == 'update':
            kanzo.update(action['key'], **action['fields'])
        elif kind == 'comment':
            kanzo.call('add_comment', id=action['key'], body=action['body'], author='sid-board')
        elif kind == 'create':
            kanzo.call('create_task', project='process', title=action['title'], description=action['body'], status='todo')
        elif kind == 'nudge':
            command(str(Path('~/.t3/bin/t3').expanduser()), 'thread', 'send', action['thread'], action['body'])
        elif kind == 'stuck':
            card = next(c for c in facts['cards'] if c['key'] == action['key'])
            kanzo.update(action['key'], tags=', '.join(dict.fromkeys(card.get('tags', []) + ['stuck'])))
            kanzo.human(action['key'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['sync', 'status', 'stalled', 'nudge', 'cycle'])
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--config', type=Path, default=Path('~/.config/sidstack/board.json').expanduser())
    args = parser.parse_args()
    if not args.config.exists():
        print(f'Create {args.config} with e.g. [{{"workspace":"openecommerce","repo":"~/openec"}}, {{"project":"process","repo":"~/.local/share/sidstack"}}]')
        return
    guard = kanzo.lock()
    if guard is None:
        print('sid-board: another card run is active; skipped')
        return
    previous = kanzo.load()
    facts = gather(json.loads(args.config.read_text()))
    now = time.time()
    actions, state, rows, stalled = reconcile(facts, previous, now)
    if args.command == 'status':
        print('CARD\tCOLUMN\tNOW\tPR\tOWNER THREAD')
        for row in rows:
            print('\t'.join(str(row[k]) for k in ('key', 'column', 'now', 'pr', 'owner')))
        return
    if args.command == 'stalled':
        for item in stalled:
            print(item['thread'] + '\t' + item['reason'])
        return
    if args.command in ('nudge', 'cycle'):
        due = args.command == 'nudge' or now - previous.get('_last_nudge', 0) >= 300
        if due:
            sends, nudged = nudges(stalled, state, now, Path('~/.config/sidstack/watchdog.off').expanduser().exists())
            if args.command == 'nudge':
                actions = sends
            else:
                actions += sends
            state = nudged
            state['_last_nudge'] = now
        elif args.command == 'nudge':
            actions = []
    if args.dry_run:
        outbox = previous.get('_outbox', [])
        actions = outbox + [a for a in actions if a not in outbox]
        for action in actions:
            print(json.dumps(action, ensure_ascii=False))
        print(f'{len(actions)} changes (dry run; board and state unchanged)')
        return
    # Receipts are durable after each successful side effect. Never acknowledge
    # planned comments or nudges that were filtered out or failed to send.
    for key, record in state.items():
        if isinstance(record, dict) and 'posted' in record:
            record['posted'] = list(previous.get(key, {}).get('posted', []))
    planned_nudges = state.pop('_nudges', {})
    state['_nudges'] = copy.deepcopy(previous.get('_nudges', {}))
    for marker in [k for k in state if k.startswith('_health:')]:
        if marker in previous:
            state[marker] = previous[marker]
        else:
            del state[marker]
    outbox = list(previous.get('_outbox', []))
    actions = outbox + [a for a in actions if a not in outbox]
    state['_outbox'] = []
    failures = False
    for action in actions:
        if action['kind'] == 'stuck' and state['_nudges'].get(action['thread'], {}).get('count', 0) < 3:
            continue
        try:
            apply([action], facts)
        except Exception as error:
            print(f"{action['kind']} {action.get('key', action.get('thread', ''))}: skipped ({str(error)[:180]})", file=sys.stderr)
            failures = True
            if action['kind'] in ('comment', 'stuck') and action not in state['_outbox']:
                state['_outbox'].append(action)
            continue
        if action.get('health_marker'):
            state[action['health_marker']] = action['health_sha']
        if action.get('event'):
            state[action['key']].setdefault('posted', []).append(action['event'])
        if action['kind'] == 'nudge':
            state['_nudges'][action['thread']] = planned_nudges[action['thread']]
            if planned_nudges[action['thread']]['count'] == 3:
                for follow in actions:
                    if follow['kind'] == 'stuck' and follow['thread'] == action['thread'] and follow not in state['_outbox']:
                        state['_outbox'].append(follow)
        if action in state['_outbox']:
            state['_outbox'].remove(action)
        kanzo.save(state)
    kanzo.save(state)
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
