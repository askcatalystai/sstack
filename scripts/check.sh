#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)
cache=$(mktemp -d)
trap 'rm -rf "$cache"' EXIT
while IFS= read -r -d '' file; do PYTHONPYCACHEPREFIX=$cache python3 -m py_compile "$file"; done < <(find . -type f -name '*.py' -not -path './.git/*' -print0)
python3 -I scripts/check_skills.py
kanzo=$HOME/.local/share/kanzo-src
if git -C "$kanzo" rev-parse -q --verify 'v0.2.1^{commit}' >/dev/null 2>&1; then
  GIT_INDEX_FILE=$cache/kanzo-index git -C "$kanzo" read-tree v0.2.1
  GIT_INDEX_FILE=$cache/kanzo-index git -C "$kanzo" apply --cached --check "$PWD/patches/kanzo-sstack.patch"
  echo "kanzo patch applies to v0.2.1"
else
  echo "skipped: no kanzo v0.2.1 at $kanzo"
fi
python3 -I scripts/pr_checks_test.py
bash scripts/scripts_test.sh
