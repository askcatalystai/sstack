#!/usr/bin/env bash
# sid-mode [get <key> | set <key> <value> [--note "who said what, when"]]: per-repo operating mode.
# Exit: 0 read or stored, 1 invalid arguments or storage failure.
set -u
common=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1
dir=$common/sid-gate; mkdir -p "$dir"
exec 9>"$dir/mode.lock"; flock 9
python3 - "$dir" "$@" <<'PY'
import datetime, os, sys
from pathlib import Path
p = Path(sys.argv[1]); args = sys.argv[2:]
choices = dict(lane=['auto', 'fast', 'full'], bot=['off', 'auto'], coder=['sol', 'claude'], ui=['opus', 'sol'], reviewers=['composer+astra', 'astra', 'none'])
values = {k: v[0] for k, v in choices.items()}
if (p/'mode').exists():
    for line in (p/'mode').read_text().splitlines():
        k, sep, v = line.partition('=')
        repairing = len(args) in (3, 5) and args[0] == 'set' and k == args[1] and args[2] in choices.get(k, [])
        if not sep or k not in choices or (v not in choices[k] and not repairing):
            sys.exit('invalid stored mode: ' + line)
        values[k] = v
if not args:
    print(' '.join(f'{k}={v}' for k, v in values.items()))
    lines = (p/'mode.log').read_text().splitlines() if (p/'mode.log').exists() else []
    for k, v in values.items():
        if v != choices[k][0]:
            entry = next((line.split('\t', 3) for line in reversed(lines) if line.split('\t')[1:3] == [k, v]), None)
            print(f'{k}: {entry[0]}, {entry[3] or "no note"}' if entry else f'{k}: time and note unavailable')
elif len(args) == 2 and args[0] == 'get' and args[1] in choices:
    print(values[args[1]])
elif len(args) in (3, 5) and args[0] == 'set' and args[1] in choices and args[2] in choices[args[1]] and (len(args) == 3 or args[3] == '--note'):
    k, v = args[1:3]; values[k] = v
    note = args[4].replace('\t', ' ').replace('\n', ' ') if len(args) == 5 else ''
    now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    with (p/'mode.log').open('a') as f:
        f.write(f'{now}\t{k}\t{v}\t{note}\n')
    (p/'mode.tmp').write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
    os.replace(p/'mode.tmp', p/'mode')
else:
    sys.exit('usage: sid-mode [get <key> | set <key> <value> [--note "who said what, when"]]; unknown key or value')
PY
