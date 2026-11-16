#!/usr/bin/env python3
"""Count recovered test identities, never the files selected for a batch rerun.

New runners may emit test identities in SID_FAILURES_OUT. For older runners,
extract named failures from their output, deduplicating echoed batch logs.
"""
import re
import sys
from pathlib import Path


def failures(output):
    output = re.sub(r'\x1b\[[0-9;]*m', '', output)
    found, vitest, terse = set(), set(), set()
    for line in output.splitlines():
        line = line.strip()
        match = re.match(r'(?:✖|✗|×|\(fail\))\s+(.+)', line)
        if match and match[1] != 'failing tests:':
            name = re.sub(r'\s+(?:\([\d.]+m?s\)|[\d.]+m?s)$', '', match[1])
            if not re.fullmatch(r'\S+\.[cm]?[jt]sx?', name):
                (terse if line.startswith('×') else found).add(name)
        elif line.startswith('FAIL ') and ' > ' in line:
            vitest.add(' '.join(line.split()))
    detail_names = {line.split(' > ', 1)[1] for line in vitest}
    return (found - detail_names) | (vitest if vitest else terse)


log, failed, again = map(Path, sys.argv[1:])
initial, _, reruns = log.read_text().partition('== gate: running the ')
repeated, _, _ = reruns.partition('== gate: running them on ')
first = failures(initial)
if first:
    print(len(first - failures(repeated)))
else:
    # Per-test protocol (also supports old single-test-per-file runners).
    # File lists for multi-file JS batches cannot establish a test count.
    before = set(failed.read_text().splitlines())
    after = set(again.read_text().splitlines()) if again.exists() else set()
    recovered = before - after
    print(sum(not re.search(r'\.(?:[cm]?[jt]sx?)$', test) for test in recovered))
