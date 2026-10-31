#!/usr/bin/env bash
# lint-new.sh [eslint args...]: run from the package root inside the gate's verify worktree,
# where HEAD is the default branch and the working tree is the merged PR. Fails only if a changed
# file has more ESLint errors than it had on the default branch, so old lint debt doesn't block PRs.
set -u
files=$(git diff --name-only --relative --diff-filter=AMR HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs')
[ -n "$files" ] || { echo "lint-new: no changed source files"; exit 0; }
fail=0
count() { python3 -c 'import json,sys;d=json.load(sys.stdin);print(sum(r["errorCount"] for r in d))' 2>/dev/null || echo 0; }
for f in $files; do
  now=$(npx eslint --format json "$@" "$f" 2>/dev/null | count)
  if git cat-file -e "HEAD:$(git rev-parse --show-prefix)$f" 2>/dev/null; then
    was=$(git show "HEAD:$(git rev-parse --show-prefix)$f" | npx eslint --format json --stdin --stdin-filename "$f" "$@" 2>/dev/null | count)
  else was=0; fi
  if [ "$now" -gt "$was" ]; then echo "lint-new: $f has $now errors (was $was)"; npx eslint "$@" "$f" | tail -n 30; fail=1
  else echo "lint-new: $f ok ($now errors, was $was)"; fi
done
exit $fail
