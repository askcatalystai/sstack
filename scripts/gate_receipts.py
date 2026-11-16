#!/usr/bin/env python3
"""Verify runner execution evidence, independently of the gate wrapper's exit code."""
import json
import sys
from pathlib import Path
from gate_failures import known_case


def runner_evidence(log, root, tests):
    """Read #1010 durable evidence from this invocation, never the request list."""
    import re
    from urllib.parse import unquote
    paths = re.findall(r'^Batch evidence: (.+)$', Path(log).read_text(), re.M)
    if not paths:
        raise ValueError('runner supplied no execution evidence')
    observed = {}
    clean_files, node_files, unclean_files = set(), set(), set()
    root = Path(root).resolve()
    for directory in paths:
        report = json.loads((Path(directory) / 'report.json').read_text())
        if ('wallTimeMs' not in report or not isinstance(report.get('failures'), list) or
                not isinstance(report.get('failureIdentities'), list) or report['failures'] or report['failureIdentities'] or
                not report.get('attempts')):
            raise ValueError('runner evidence incomplete or failing')
        for attempt in report['attempts']:
            if (attempt.get('ok') is not True or attempt.get('code') != 0 or attempt.get('signal') or
                    any(attempt.get(k) for k in ('timedOut', 'spawnError', 'captureError', 'missingRequestedCases', 'corruptReport', 'unfinished'))):
                raise ValueError('unclean execution evidence')
            cwd = Path(attempt['cwd']).resolve()
            if not cwd.is_relative_to(root):
                raise ValueError('execution evidence belongs to another checkout')
            rows = []
            if attempt.get('browserReport'):
                for line in Path(attempt['browserReport']).read_text().splitlines():
                    record = json.loads(line)
                    if record.get('errors') or record.get('suiteErrors'):
                        raise ValueError('runner reported suite errors')
                    if record.get('file') and (record.get('state') != 'passed' or
                            any(arg == '--test-name-pattern' or arg.startswith('--test-name-pattern=') for arg in attempt.get('args', []))):
                        unclean_files.add(str(Path(record['file']).resolve()))
                    rows.extend((str(Path(record['file']).resolve()), t['name'], t['state']) for t in record.get('tests', []))
            else:
                output = re.sub(r'\x1b\[[0-9;]*m', '', Path(attempt['logFile']).read_text())
                files = [Path(arg).resolve() if Path(arg).is_absolute() else (cwd / arg).resolve()
                         for arg in attempt.get('args', []) if not arg.startswith('-') and
                         re.search(r'\.(?:[cm]?[jt]sx?)$', arg)]
                current = str(files[0]) if len(files) == 1 else None
                if any(arg == '--test-name-pattern' or arg.startswith('--test-name-pattern=') for arg in attempt.get('args', [])):
                    unclean_files.update(str(p) for p in files)
                node = '--test' in attempt.get('args', [])
                if node:
                    node_files.update(str(p) for p in files)
                elif re.search(r'^\s*[1-9]\d* (?:skip|todo|fail)\b', output, re.M):
                    unclean_files.update(str(p) for p in files)
                for line in output.splitlines():
                    heading = re.match(r'^(.+\.(?:test|spec)\.[cm]?[jt]sx?):\s*$', line)
                    if heading:
                        current = str((cwd / heading[1]).resolve())
                    if node and line.startswith('ℹ tests '):
                        break
                    match = (re.match(r'^([✔✖]) (.+) \([\d.]+m?s\)$', line) if node else
                             re.match(r'^\((pass|fail|skip|todo)\) (.+?)(?: \[[\d.]+m?s\])?$', line))
                    if match and current:
                        rows.append((current, match[2], 'passed' if match[1] in ('✔', 'pass') else 'failed'))
                # Grouped Node results are opaque, but full-file zero-failure summaries
                # still establish clean execution of the requested whole file.
                if node and len(files) == 1 and '--test-name-pattern' not in attempt.get('args', []):
                    totals = dict(re.findall(r'^ℹ (tests|fail|cancelled|skipped|todo) (\d+)$', output, re.M))
                    if int(totals.get('tests', '0')) > 0 and all(totals.get(k) == '0' for k in ('fail', 'cancelled', 'skipped', 'todo')):
                        clean_files.add(str(files[0]))
            for file, name, state in rows:
                observed.setdefault(file, []).append((name, state))
    for identity in tests:
        file, separator, encoded = identity.partition('::') if known_case(identity) else (identity, '', '')
        absolute = next((str(p.resolve()) for p in (root / 'app' / file, root / file) if p.is_file()), None)
        if absolute is None or not Path(absolute).is_relative_to(root):
            raise ValueError('recorded file is missing or outside the verification checkout: '+identity)
        rows = observed.get(absolute, [])
        if separator:
            matches = [state for name, state in rows if name == unquote(encoded, errors='strict')]
            if matches != ['passed']:
                raise ValueError('known case did not execute and pass: '+identity)
        elif (absolute in unclean_files or
              (absolute in node_files and absolute not in clean_files) or
              not ((rows and all(state == 'passed' for _, state in rows)) or absolute in clean_files)):
            raise ValueError('opaque identity lacks clean whole-file execution: '+identity)


def verify(marker, requested, receipts, log=None, root=None):
    tests = json.loads(Path(marker).read_text())['tests']
    if not isinstance(tests, list) or not tests or any(not isinstance(t, str) or not t.strip() for t in tests):
        raise ValueError('invalid main-red test identities')
    opaque = {test for test in tests if not known_case(test)}
    rerun = sorted({test for test in tests if not known_case(test) or test.partition('::')[0] not in opaque})
    Path(requested).write_text('\n'.join(rerun)+'\n')
    if receipts is None:
        return
    if not Path(receipts).exists():
        if log is None or root is None:
            raise ValueError("runner supplied no execution receipts")
        runner_evidence(log, root, tests)
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
        verify(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None,
               sys.argv[4] if len(sys.argv) > 4 else None, sys.argv[5] if len(sys.argv) > 5 else None)
    except (OSError, ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
