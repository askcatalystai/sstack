#!/usr/bin/env python3
"""Fail-closed dependency admission and child retargeting for serial landings."""
import json
import re
import subprocess
import sys
from pathlib import Path

from pr_checks import section


def gh(repo, *args):
    return json.loads(subprocess.check_output(['gh', 'pr', *args, '--repo', repo], text=True))


def on_main(repo, pr, default):
    if pr['state'] != 'MERGED' or pr['baseRefName'] != default:
        return False
    oid = (pr.get('mergeCommit') or {}).get('oid')
    if not oid:
        return False
    subprocess.run(['git', 'fetch', '-q', 'origin', oid], check=True)
    return subprocess.run(['git', 'merge-base', '--is-ancestor', oid, 'origin/'+default]).returncode == 0


def main():
    action, path, *args = sys.argv[1:]
    if action == 'admission':
        red = json.loads(Path(args[0]).read_text())
        review = section(json.loads(Path(path).read_text())['body'], 'Review')
        if not re.search(r'(?<![\w#])'+re.escape(red['card'])+r'(?!\d)', review):
            sys.exit(f"main red: fix {red['card']} first; only its fix naming that card in ## Review may queue\n"+'\n'.join(red['tests']))
        return
    repo, default = args
    if action == 'retarget':
        # gh list is paginated; retarget each page until no child uses this base.
        while children := gh(repo, 'list', '--state', 'open', '--base', path, '--json', 'number'):
            for child in children:
                subprocess.run(['gh', 'pr', 'edit', str(child['number']), '--repo', repo, '--base', default], check=True)
        return
    pr = json.loads(Path(path).read_text())
    dependencies = set()
    for line in pr['body'].splitlines():
        if re.match(r'^\s*Depends-on\b', line, re.I):
            match = re.fullmatch(r'Depends-on:[ \t]*#(\d+)[ \t]*', line, re.I)
            if not match:
                sys.exit('blocked dependency: use one Depends-on: #N line per dependency')
            dependencies.add(match[1])
    if pr['baseRefName'] != default:
        parents = gh(repo, 'list', '--state', 'all', '--head', pr['baseRefName'], '--json', 'number,state,baseRefName,mergeCommit')
        if len(parents) != 1 or not on_main(repo, parents[0], default):
            sys.exit(f"blocked dependency: base {pr['baseRefName']} must land on {default} first")
        sys.exit(f"blocked dependency: parent landed; retarget this PR to {default} for a fresh gate")
    for number in sorted(dependencies, key=int):
        parent = gh(repo, 'view', number, '--json', 'state,baseRefName,mergeCommit')
        if not on_main(repo, parent, default):
            sys.exit(f'blocked dependency: #{number} must land on {default} first')


if __name__ == '__main__':
    main()
