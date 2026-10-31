#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)
while IFS= read -r -d '' file; do node --check "$file"; done < <(find skills/council/plan/dashboard -type f -name '*.js' -print0)
cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT
while IFS= read -r -d '' file; do PYTHONPYCACHEPREFIX=$cache python3 -m py_compile "$file"; done < <(find . -type f -name '*.py' -not -path './.git/*' -print0)
bash skills/council/plan/tests/run.sh
