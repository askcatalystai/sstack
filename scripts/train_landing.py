#!/usr/bin/env python3
"""Durable, verifiable receipts for squash commits pushed with an explicit main lease."""
import json
import subprocess
import sys
from pathlib import Path


def git(*args, cwd=None):
    return subprocess.check_output(['git', *args], cwd=cwd, text=True).strip()


def receipt_path(repo, number, common=None):
    common = common or git('rev-parse', '--path-format=absolute', '--git-common-dir', cwd=repo)
    return Path(common) / 'sid-gate/train/landed' / f'{number}.json'


def landed(repo, number, head, default, common=None):
    path = receipt_path(repo, number, common)
    if not path.exists():
        return None
    r = json.loads(path.read_text())
    if r['head'] != head or r['default'] != default:
        return None
    oid = r['oid']
    if subprocess.run(['git', 'merge-base', '--is-ancestor', oid, 'origin/'+default], cwd=repo,
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        return None
    if git('rev-parse', oid+'^', cwd=repo) != r['parent'] or git('rev-parse', oid+'^{tree}', cwd=repo) != r['tree']:
        raise ValueError('landing receipt does not match commit')
    if f'Sid-Train-PR: #{number} {head}' not in git('show', '-s', '--format=%B', oid, cwd=repo).splitlines():
        raise ValueError('landing identity missing from commit')
    return r


def overlay(repo, pr, default, common=None):
    r = landed(repo, pr['number'], pr['headRefOid'], default, common)
    if r:
        pr.update(state='MERGED', mergeCommit={'oid': r['oid']}, mergedAt=r['date'])
    return r


def main():
    action, number, head, default, *args = sys.argv[1:]
    repo = git('rev-parse', '--show-toplevel')
    if action == 'recover':
        subprocess.run(['git', 'fetch', '-q', 'origin', default], check=True)
        r = landed(repo, number, head, default)
        if not r:
            sys.exit(1)
        print(r['oid'])
    elif action == 'prepare':
        parent, tree, snapshot, record = args
        pr = json.loads(Path(snapshot).read_text())
        trailers = git('log', f'{parent}..{head}', '--format=%(trailers:only,unfold)')
        message = f"{pr['title']} (#{number})\n\n{pr['body']}\n\n{trailers}\n{record}\nSid-Train-PR: #{number} {head}\n"
        oid = subprocess.check_output(['git', '-c', 'user.name=sid-train', '-c', 'user.email=sid-train@localhost',
            'commit-tree', tree, '-p', parent], input=message, text=True).strip()
        r = dict(head=head, default=default, parent=parent, tree=tree, oid=oid,
                 date=git('show', '-s', '--format=%cI', oid), record=record)
        path = receipt_path(repo, number)
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(r)+'\n')
        temporary.replace(path)
        print(oid)
    elif action == 'close':
        forge, = args
        r = landed(repo, number, head, default)
        if not r:
            sys.exit('cannot close PR without a verified landing')
        current = json.loads(subprocess.check_output(['gh', 'pr', 'view', number, '--repo', forge,
            '--json', 'headRefOid,baseRefName'], text=True))
        if current['headRefOid'] != head or current['baseRefName'] != default:
            sys.exit('landed gated head, but PR changed; retaining its branch and request')
        # Retrying the close is safe; a failed API call never invalidates the landed commit.
        subprocess.run(['gh', 'pr', 'close', number, '--repo', forge, '--comment',
            f"Landed gated squash commit {r['oid']} on {default}.\n\n{r['record']}"], check=True)
        after = json.loads(subprocess.check_output(['gh', 'pr', 'view', number, '--repo', forge,
            '--json', 'headRefOid,baseRefName'], text=True))
        if after['headRefOid'] != head or after['baseRefName'] != default:
            subprocess.run(['gh', 'pr', 'reopen', number, '--repo', forge], check=True)
            sys.exit('PR changed during close; reopened and retained branch')


if __name__ == '__main__':
    main()
