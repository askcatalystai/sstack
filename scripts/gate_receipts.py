#!/usr/bin/env python3
"""Prepare main-red selections and validate the single execution-sidecar contract."""
import json
import sys
from pathlib import Path
from gate_failures import known_case


def scope(identity):
    if known_case(identity):
        return 'case'
    return 'package' if identity.startswith('package:') else 'file'


def verify(marker, requested, receipts=None):
    tests = json.loads(Path(marker).read_text())['tests']
    if not isinstance(tests, list) or not tests or any(not isinstance(t, str) or not t.strip() for t in tests):
        raise ValueError('invalid main-red test identities')
    opaque = {test for test in tests if not known_case(test)}
    rerun = sorted({test for test in tests if not known_case(test) or test.partition('::')[0] not in opaque})
    Path(requested).write_text('\n'.join(rerun)+'\n')
    if receipts is None:
        return
    evidence = {}
    for line in Path(receipts).read_text().splitlines():
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
    for test in tests:
        row = evidence.get(test, {})
        minimum = row.get('executed', 0) == 1 if known_case(test) else row.get('executed', 0) > 0
        if row.get('status') != 'passed' or not minimum or row.get('skipped') != 0:
            raise ValueError('recorded identity did not execute cleanly: '+test)


if __name__ == '__main__':
    try:
        verify(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        sys.exit(str(error))
