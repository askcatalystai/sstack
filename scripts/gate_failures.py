#!/usr/bin/env python3
"""Compare failure identities without allowing a red case to cover an entire file."""
import sys
from pathlib import Path


def compare(pr, main):
    def cases(entries):
        result = {}
        for entry in entries:
            file, separator, case = entry.partition('::')
            if separator and file and case:
                result.setdefault(file, set()).add(case)
        return result
    pr_cases, main_cases = cases(pr), cases(main)
    known = {entry for entry in pr & main if '::' in entry and all(entry.split('::', 1))}
    new = pr - known
    for entry in list(new):
        if '::' in entry:
            continue
        # A coarse marker may be redundant beside explicit case evidence, but
        # an unknown (empty) PR case set never proves that its failures are covered.
        if (entry not in main and pr_cases.get(entry) and
                pr_cases[entry] <= main_cases.get(entry, set())):
            new.remove(entry)
    return new, known


if __name__ == '__main__':
    mode, pr_path, main_path = sys.argv[1:]
    pr = {line for line in Path(pr_path).read_text().splitlines() if line.strip()}
    main = {line for line in Path(main_path).read_text().splitlines() if line.strip()}
    new, known = compare(pr, main)
    if mode == 'new':
        for entry in sorted(new):
            print(entry)
    elif mode == 'known':
        print(len(known))
    else:
        sys.exit('expected new or known')
