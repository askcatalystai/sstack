#!/usr/bin/env python3
"""Comparison identities are independent of the runner's retry receipts."""
import sys
from pathlib import Path
from urllib.parse import quote, unquote


def known_case(entry):
    file, separator, case = entry.partition('::')
    return bool(separator and file and case and not file.startswith(('/', 'package:')) and
                quote(unquote(case, errors='strict'), safe="-_.!~*'()") == case)


def identities(path, failed=False):
    rows = {line for line in Path(path).read_text().splitlines() if line.strip()}
    if failed and not rows:
        raise ValueError('nonzero gate with empty failure identities: '+str(path))
    return rows


def compare(candidate, main):
    known = {entry for entry in candidate & main if known_case(entry)}
    return candidate - known, known


if __name__ == '__main__':
    try:
        mode, *args = sys.argv[1:]
        if mode == 'check':
            rc = int(args[1])
            if rc not in (0, 1):
                raise ValueError('infrastructure exit cannot provide comparison proof')
            rows = identities(args[0], rc != 0)
            if rc == 0 and rows:
                raise ValueError('successful invocation reported failures')
        elif mode in ('new', 'known'):
            new, known = compare(identities(args[0], True), identities(args[1]))
            if mode == 'known':
                print(len(known))
            else:
                for entry in sorted(new):
                    print(entry)
        else:
            raise ValueError('unknown comparison operation')
    except (OSError, ValueError, IndexError) as error:
        sys.exit(str(error))
