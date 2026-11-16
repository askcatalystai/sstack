#!/usr/bin/env python3
"""Persist main's failing tests before attempting the best-effort Kanzo notification."""
import json
import sys
import subprocess
from pathlib import Path
import kanzo_client as kanzo


def record(directory, repo, sha, log, tests):
    health = Path(directory)
    marker = health / 'main-red'
    old = json.loads(marker.read_text()) if marker.exists() else {}
    try:
        name = subprocess.check_output(['gh', 'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'], text=True).strip().split('/')[-1]
    except (OSError, subprocess.CalledProcessError):
        name = Path(repo).name
    title = f'Main is red: {name}'
    card = old.get('card', f'main-red:{Path(repo).name}')
    tests = sorted(set(old.get('tests', [])) | set(tests))
    data = dict(card=card, sha=sha, log=log, tests=tests)
    def save():
        temporary = marker.with_suffix('.tmp')
        temporary.write_text(json.dumps(data)+'\n')
        temporary.replace(marker)
        (health / sha).write_text('fail full\n'+log+'\nmain red\n'+'\n'.join(tests)+'\n')
    save()
    try:
        kanzo.connect()
        existing = next((t for t in kanzo.tasks().values() if t['title'] == title), None)
        body = f'Main red at {sha}. Log: {log}\n'+'\n'.join(tests)
        if existing:
            card = existing['key']
            kanzo.update(card, description=body, status='todo')
        else:
            kanzo.call('create_task', project='process', title=title, description=body, status='todo')
            card = next(t['key'] for t in kanzo.tasks().values() if t['title'] == title)
        data['card'] = card
        save()
    except Exception as error:
        print(f'main red: {card}: {error}\n'+'\n'.join(tests), file=sys.stderr)


if __name__ == '__main__':
    record(*sys.argv[1:5], Path(sys.argv[5]).read_text().splitlines())
