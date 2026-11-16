#!/usr/bin/env python3
"""Verify runner execution evidence, independently of the gate wrapper's exit code."""
import json
import sys
from pathlib import Path


def verify(marker, requested, receipts):
    tests = json.loads(Path(marker).read_text())['tests']
    if not isinstance(tests, list) or not tests or any(not isinstance(t, str) or not t.strip() for t in tests):
        raise ValueError('invalid main-red test identities')
    Path(requested).write_text('\n'.join(tests)+'\n')
    if receipts is None:
        return
    evidence = {}
    for line in Path(receipts).read_text().splitlines():
        row = json.loads(line)
        identity = row['identity']
        if identity in evidence:
            raise ValueError('duplicate execution receipt: '+identity)
        evidence[identity] = row
    for test in tests:
        row = evidence.get(test, {})
        if (row.get('status') != 'passed' or type(row.get('executed')) is not int or
                row['executed'] < 1 or row.get('skipped') != 0):
            raise ValueError('main-red test did not execute and pass: '+test)


if __name__ == '__main__':
    try:
        verify(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
