#!/usr/bin/env python3
"""Prepare verification selections and require execution proof before forgiveness."""
import json
import sys
from pathlib import Path
from gate_failures import identities, known_case


def scope(identity):
    if known_case(identity):
        return 'case'
    return 'package' if identity.startswith('package:') else 'file'


def recovery_hint(marker):
    return (f'If recorded identities are obsolete on current main (not merely absent from the candidate), '
            f'pause queue/runner, audit and edit or archive {marker}, then run sid-health.sh --wait '
            f'and require green main before resuming. Retain valid failures. '
            f'See sidstack docs/gate-contract.md#stale-main-red-recovery.')


def execution_receipts(path):
    evidence = {}
    for line in Path(path).read_text().splitlines():
        row = json.loads(line)
        identity = row['identity']
        if (not isinstance(identity, str) or not identity.strip() or identity.startswith('/') or
                identity == 'package:' or any(c in identity for c in '\r\n')):
            raise ValueError('invalid execution identity')
        if identity in evidence:
            raise ValueError('duplicate execution receipt: '+identity)
        if row['scope'] != scope(identity):
            raise ValueError('wrong execution scope: '+identity)
        if row['status'] not in ('passed', 'failed', 'skipped', 'missing', 'incomplete'):
            raise ValueError('invalid execution status: '+identity)
        if any(type(row[k]) is not int or row[k] < 0 for k in ('executed', 'skipped')):
            raise ValueError('invalid execution counts: '+identity)
        evidence[identity] = row
    return evidence


def require_passed(tests, evidence):
    for test in tests:
        row = evidence.get(test, {})
        minimum = row.get('executed', 0) == 1 if known_case(test) else row.get('executed', 0) > 0
        if row.get('status') != 'passed' or not minimum or row.get('skipped') != 0:
            raise ValueError('recorded identity did not execute cleanly: '+test)


def verify(marker, requested, receipts=None):
    red = json.loads(Path(marker).read_text())
    tests = red['tests']
    if not isinstance(tests, list) or (not tests and red.get('full_check_required') is not True) or any(not isinstance(t, str) or not t.strip() for t in tests):
        raise ValueError('invalid main-red test identities')
    opaque = {test for test in tests if not known_case(test)}
    rerun = sorted({test for test in tests if not known_case(test) or test.partition('::')[0] not in opaque})
    Path(requested).write_text('\n'.join(rerun)+('\n' if rerun else ''))
    if receipts is not None:
        require_passed(tests, execution_receipts(receipts))


def recovered(candidate, retry, receipts):
    recovered_ids = identities(candidate, True) - identities(retry)
    require_passed(recovered_ids, execution_receipts(receipts))
    return sum(known_case(t) for t in recovered_ids), sum(scope(t) == 'file' for t in recovered_ids)


if __name__ == '__main__':
    try:
        if sys.argv[1] == '--recovered':
            print(*recovered(*sys.argv[2:]))
        elif sys.argv[1] == '--recovery-hint':
            print(recovery_hint(sys.argv[2]))
        else:
            verify(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        hint = '\n'+recovery_hint(sys.argv[1]) if len(sys.argv) > 1 and not sys.argv[1].startswith('--') else ''
        sys.exit(str(error)+hint)
