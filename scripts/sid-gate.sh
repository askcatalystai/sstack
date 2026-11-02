#!/usr/bin/env bash
# sid-gate <branch>: run the repo's gate on origin/<default> merged with <branch>, then stamp the head as passed.
# The stamp's second line is the Gate-Passed record for the merge commit; its log stays in sid-gate/logs (newest 50).
# The commands live in the repo, in .sidstack/gate.sh, and run from the merged tree in <repo>-wt/verify.
# One gate at a time per repo, because builds run out of memory side by side.
# Exit: 0 passed, 1 failed, 3 conflicts with the default branch.
set -u
branch=${1:?usage: sid-gate <branch>}
repo=$(git rev-parse --show-toplevel) || exit 1
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
repo=$(dirname "$common")
base=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); base=${base#origin/}; base=${base:-main}
verify=$repo-wt/verify
mkdir -p "$common/sid-gate"
exec 9>"$common/sid-gate/lock"; flock 9
# Clear the branch's pass first, so a rerun that fails or dies at any point leaves nothing standing.
stamp=$common/sid-gate/${branch//\//_}.pass
rm -f "$stamp"
git -C "$repo" fetch -q origin "$base" "$branch" || { echo "cannot fetch $branch; push it first"; exit 1; }
main=$(git -C "$repo" rev-parse "origin/$base")
head=$(git -C "$repo" rev-parse "origin/$branch")
[ -d "$verify" ] || git -C "$repo" worktree add -q --detach "$verify" "$main" || exit 1
out=$(git -C "$verify" merge-tree --write-tree "$main" "$head") || { echo "conflicts with $base: merge origin/$base into $branch, then gate again"; exit 3; }
# A gate killed midway leaves files behind, so start clean.
git -C "$verify" checkout -q --detach -f "$main" || exit 1
git -C "$verify" clean -qfd
git -C "$verify" read-tree -u --reset "${out%%$'\n'*}" || exit 1
[ -f "$verify/.sidstack/gate.sh" ] || { echo "no .sidstack/gate.sh in this repo"; exit 1; }
log=$common/sid-gate/${branch//\//_}.log
( cd "$verify" && echo "== gate: $base ${main:0:8} + $branch ${head:0:8}" && bash .sidstack/gate.sh ) > "$log" 2>&1; rc=$?
git -C "$verify" checkout -q --detach -f "$main"
git -C "$verify" clean -qfd
if [ "$rc" != 0 ]; then echo "gate FAILED: $log"; tail -n 25 "$log"; exit 1; fi
digest=$(sha256sum "$log" | cut -d' ' -f1)
logs=$common/sid-gate/logs
mkdir -p "$logs"; cp "$log" "$logs/$head.$main.log"
ls -1t "$logs" | tail -n +51 | while IFS= read -r old; do rm -f "$logs/$old"; done
printf '%s %s\nGate-Passed: %s %s + %s %s, log sha256 %s\n' "$head" "$main" "$base" "${main:0:8}" "$branch" "${head:0:8}" "$digest" > "$stamp"
echo "gate passed: $base ${main:0:8} + $branch ${head:0:8}"
