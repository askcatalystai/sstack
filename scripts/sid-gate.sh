#!/usr/bin/env bash
# sid-gate <branch>: gate origin/<default> merged with <branch> in <repo>-wt/verify, then stamp the head.
# The second stamp line is the Gate-Passed record; logs keep the newest 50 runs.
# Exit: 0 passed, 1 failed, 3 conflicts with the default branch.
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$here/sid-gate-lib.sh"
branch=${1:?usage: sid-gate <branch>}
gate_repo || exit 1
exec 9>"$gate/lock"; flock 9
# Clear first so a failed or killed rerun cannot leave a usable pass.
stamp=$gate/${branch//\//_}.pass; rm -f "$stamp"
git -C "$repo" fetch -q origin "$default" "$branch" || { echo "cannot fetch $branch; push it first"; exit 1; }
main=$(git -C "$repo" rev-parse "origin/$default"); head=$(git -C "$repo" rev-parse "origin/$branch")
out=$(git -C "$repo" merge-tree --write-tree "$main" "$head") || { echo "conflicts with $default: merge origin/$default into $branch, then gate again"; exit 3; }
log=$gate/logs/$head.$main.log
ln -sfn "logs/$head.$main.log" "$gate/${branch//\//_}.log"
export SID_LANE=${SID_LANE:-$("$here/sid-mode.sh" get lane)}
gate_tree "$main" "${out%%$'\n'*}" "$log" "$default ${main:0:8} + $branch ${head:0:8}" || { echo "gate FAILED: $log"; tail -n 25 "$log"; exit 1; }
printf '%s %s\nGate-Passed: %s %s + %s %s, log sha256 %s\n' "$head" "$main" "$default" "${main:0:8}" "$branch" "${head:0:8}" "$digest" > "$stamp"
echo "gate passed: $default ${main:0:8} + $branch ${head:0:8}"
