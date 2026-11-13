#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)
cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT
while IFS= read -r -d '' file; do PYTHONPYCACHEPREFIX=$cache python3 -m py_compile "$file"; done < <(find . -type f -name '*.py' -not -path './.git/*' -print0)
python3 -I scripts/check_skills.py
if command -v cargo >/dev/null; then
  (cd kanzo && CARGO_TARGET_DIR=$HOME/.cache/sidstack-kanzo cargo test -q --locked)
else
  echo "skipped: no cargo for kanzo tests"
fi
python3 -I scripts/pr_checks_test.py
python3 -I scripts/board_test.py
bash scripts/scripts_test.sh
