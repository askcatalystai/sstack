#!/usr/bin/env python3
"""Shared review severity matching and orchestrator resolution ledger checks."""
import json
import re
import sys
from pathlib import Path

SEVERITY = re.compile(r'\[(blocker|should)\]|^S[0-9]+[ :]+(blocker|should)\b', re.I | re.M)


def clean(text):
    return ('VERDICT: APPROVE' in text.splitlines()
            and not SEVERITY.search(text)
            and 'VERDICT: CHANGES' not in text.splitlines())


def record(state, kind, round_number, paths):
    history = json.loads(state.read_text()) if state.exists() else []
    # Keep the output in the history: later rounds can reuse an output filename.
    history.append({'kind': kind, 'round': round_number,
                    'outputs': {p.stem: p.read_text() for p in paths}})
    state.write_text(json.dumps(history, indent=1))


def validate(state, gate_round, ledger):
    history = json.loads(state.read_text()) if state.exists() else []
    gate = next((i for i in range(len(history)-1, -1, -1)
                 if history[i]['kind'] in ('gate', 'all') and history[i]['round'] == gate_round), None)
    if gate is None or any(r['kind'] == 'panel' for r in history[gate+1:]):
        raise ValueError('a gate round must run after the latest panel round')
    resolutions = set(re.findall(
        r'^[ \t]*(?:[-*][ \t]+)?(pr\d+-rev[^\s:]*:S\d+)[ \t]+(?:fixed|declined):[ \t]*\S[^\n]*',
        ledger.read_text(), re.I | re.M))
    resolutions = {r.lower() for r in resolutions}
    missing = set()
    for review in history:
        # Every panel round, every earlier parallel round, and the selected gate round.
        if review['kind'] not in ('panel', 'all') and review is not history[gate]:
            continue
        if review['kind'] == 'all' and history.index(review) > gate:
            continue
        for job, text in review['outputs'].items():
            # In an all round Astra consolidates the panel: only its list needs resolutions.
            if review['kind'] == 'all' and not job.endswith('-gate'):
                continue
            # A severity may appear on a continuation line of an S<n> finding.
            finding = None
            for line in text.splitlines():
                ident = re.match(r'^[ \t]*(?:[-*][ \t]+)?S(\d+)\b', line, re.I)
                if ident:
                    finding = f'{job}:S{ident[1]}'
                if SEVERITY.search(line):
                    if finding is None:
                        raise ValueError(f'{job}: finding without an S<n> id: {line}')
                    if finding.lower() not in resolutions:
                        missing.add(finding)
    if missing:
        raise ValueError('missing resolutions: ' + ', '.join(sorted(missing)))


if __name__ == '__main__':
    command, *args = sys.argv[1:]
    if command == 'clean':
        sys.exit(0 if clean(Path(args[0]).read_text()) else 1)
    elif command == 'record':
        state, kind, round_number, *outputs = args
        record(Path(state), kind, round_number, list(map(Path, outputs)))
    elif command == 'validate':
        try:
            validate(Path(args[0]), args[1], Path(args[2]))
        except (ValueError, OSError) as error:
            print(f'cm: {error}', file=sys.stderr)
            sys.exit(12)
