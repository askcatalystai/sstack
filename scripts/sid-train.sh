#!/usr/bin/env bash
# sid-train: drain this repo's queue, gating combined trees and splitting failures oldest half first.
# Shares sid-gate's lock: trains and health must never build side by side.
# Exit: 0 drained, 1 runner/setup failure. Per-PR codes live in train/result/<pr>;
# 5 means merged onto an ungated tree (main moved or GitHub landed an unexpected tree).
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$here/sid-gate-lib.sh"
source "$here/sid-merge-lib.sh"
gate_repo || exit 1
cd "$repo" || exit 1
max=${SID_TRAIN_MAX:-6}
[[ $max =~ ^[1-9][0-9]*$ ]] || { echo 'SID_TRAIN_MAX must be positive'; exit 1; }
exec 7>"$train/runner.lock"; flock 7
exec 8>"$train/queue.lock"
# Check the process birth time too, so an old pid file cannot kill an unrelated process.
if [ -f "$gate/health.pid" ] && read -r pid birth < "$gate/health.pid"; then
  if [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = "$birth" ]; then kill -TERM "$pid" 2>/dev/null; fi
fi
exec 9>"$gate/lock"; gate_lock
# Claims only protect cancellation; a dead runner's queue is safe to rebuild from scratch.
rm -f "$train/active/"*
gh=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1
state() {
  local phase=$1; shift
  python3 - "$train/state.json" "$id" "$phase" "$lane" "$started" "$main" "$@" <<'PY'
import json, os, sys
p, i, phase, lane, started, main, *members = sys.argv[1:]
with open(p+'.tmp', 'w') as f:
    json.dump(dict(id=int(i), phase=phase, lane=lane, members=list(map(int, members)), started=started, main=main), f)
    f.write('\n')
os.replace(p+'.tmp', p)
PY
}
id=0; lane=; main=; started=$(date -u +%FT%TZ)
finish() {
  id=$(cat "$train/sequence" 2>/dev/null || echo 0)
  main=$(git rev-parse --verify "origin/$default" 2>/dev/null) || main=
  state idle; rm -f "$train/active/"*
}
trap finish EXIT
trap 'exit 1' TERM INT
result_for() {
  local pr=$1 rc=$2; shift 2
  flock 8
  printf '%s\n' "$rc" "$@" > "$train/result/$pr.tmp"
  mv "$train/result/$pr.tmp" "$train/result/$pr"
  rm -f "$train/queue/$pr.req" "$train/queue/$pr.merge" "$train/active/$pr"
  [ "$rc" != 0 ] || rm -f "$train/failed/$pr"
  flock -u 8
}
cleanup_branch() {
  local branch=$1 wt
  rm -f "$gate/${branch//\//_}.pass"
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} $0=="branch "b{print w}')
  if [ -n "$wt" ]; then git worktree remove "$wt" || echo "kept $wt: it has uncommitted or untracked files"; fi
  git branch -qD "$branch" 2>/dev/null
  git push -q origin --delete "$branch" 2>/dev/null
}
new_id() {
  id=$(cat "$train/sequence" 2>/dev/null || echo 0); id=$((id+1))
  echo "$id" > "$train/sequence"
  started=$(date -u +%FT%TZ); lane=
}
history() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$started" "$(date -u +%FT%TZ)" "$members" "$lane" "$1" >> "$train/history.tsv"; }
# Save a fresh readiness snapshot; any failed check stays fail-closed.
validate() (
  local pr=$1 queued_head=$2
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  ready
  [ "$head" = "$queued_head" ] || { echo "#$pr head changed since queueing; run sid-merge again"; exit 1; }
  [ "$base" = "$default" ] || { echo "#$pr's base just changed to $base; run sid-merge again"; exit 1; }
  cp "$tmp/pr.json" "$train/active/$pr.json"
)
# A zero CLI exit can mean queued. Only GitHub's completed, matching head counts.
merged_oid() {
  python3 - "$train/active/$1.json" "$2" <<'PYTHON'
import json, sys
p = json.load(open(sys.argv[1]))
if p['state'] != 'MERGED' or p['headRefOid'] != sys.argv[2]:
    sys.exit(1)
oid = (p.get('mergeCommit') or {}).get('oid')
if not oid:
    sys.exit(1)
print(oid)
PYTHON
}
landed_tree() {
  git fetch -q origin "$oid" || return 1
  parent=$(git rev-parse "$oid^1") || return 1
  [ "$parent" = "$expected" ] && [ "$(git rev-parse "$oid^{tree}")" = "$member_tree" ] || return 5
}
start_health() {
  local health_pid
  # Run detached, but yield the shared gate until actual main is checked before rebuilding.
  ( exec 7>&- 8>&- 9>&-
    exec setsid -f -w "$here/sid-health.sh" --wait </dev/null >>"$train/health.log" 2>&1
  ) &
  health_pid=$!
  flock -u 9
  wait "$health_pid"
  gate_lock
}
# The train's gate covers main when the landed tree is the gated one; record that so health doesn't run it again.
stamp_main() {
  local gated_tree=$1 newmain
  git fetch -q origin "$default" || return
  newmain=$(git rev-parse "origin/$default")
  [ "$(git rev-parse "$newmain^{tree}")" = "$gated_tree" ] || return 0
  printf 'pass %s\n%s\n' "$lane" "$log" > "$gate/health/$newmain.tmp"
  mv "$gate/health/$newmain.tmp" "$gate/health/$newmain"
}
# One more failure of this commit on the record; sid-merge reads it before queueing the commit again.
note_failure() {
  local pr=$1 head failed_head failures=0
  head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$train/queue/$pr.req") || return
  if [ -f "$train/failed/$pr" ]; then
    read -r failed_head failures _ < "$train/failed/$pr"
    [ "$failed_head" = "$head" ] || failures=0
  fi
  printf '%s %s %s\n' "$head" "$((failures+1))" "$log" > "$train/failed/$pr"
}
run_train() {
  # Recursive halves get their own ids, logs, and main snapshots.
  local -a candidates=("$@") accepted=() remaining=()
  local -A trees=()
  local pr head branch out tree combined synthetic rc record oid expected parent member_tree trailers message title body mode_error noted
  local id started lane main log members digest flaky known new_failures attempt merged retry needs_rebuild unsafe
  for attempt in 1 2 3; do
    [ "${#candidates[@]}" -gt 0 ] || return 0
    if ! mode_error=$("$here/sid-mode.sh" get lane 2>&1); then
      for pr in "${candidates[@]}"; do result_for "$pr" 1 "$mode_error" 'fix it with sid-mode.sh set'; done
      return 1
    fi
    new_id
    members="${candidates[*]}"
    main=$(git rev-parse "origin/$default")
    state gating "${candidates[@]}"
    git fetch -q origin "$default" || { for pr in "${candidates[@]}"; do result_for "$pr" 1 'cannot fetch default branch'; done; history failed; return; }
    main=$(git rev-parse "origin/$default"); combined=$main; accepted=(); trees=()
    for pr in "${candidates[@]}"; do
      head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$train/queue/$pr.req")
      # Check identity before readiness; only the queued head can be recovered or gated.
      if ! gh pr view "$pr" --repo "$gh" --json state,isDraft,baseRefName,headRefOid,headRefName,mergeCommit > "$train/active/$pr.json"; then result_for "$pr" 1 "could not read #$pr"; continue; fi
      # Recover a successful merge whose runner died before publishing its result.
      if oid=$(merged_oid "$pr" "$head"); then
        branch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefName"])' "$train/active/$pr.json")
        rc=1
        if [ -f "$train/queue/$pr.merge" ]; then
          { read -r expected; read -r member_tree; } < "$train/queue/$pr.merge"
          landed_tree; rc=$?
        fi
        if [ "$rc" = 0 ]; then
          result_for "$pr" 0 "merged #$pr: $oid (found already merged)"
          cleanup_branch "$branch"
        elif [ "$rc" = 5 ]; then
          result_for "$pr" 5 "merged #$pr as $oid, but main now holds a tree no gate tested (landed on ${parent:0:8}, gated ${expected:0:8})"
          start_health
        else
          result_for "$pr" 5 "merged #$pr as $oid, but the landed tree could not be verified"
          start_health
        fi
        continue
      fi
      if ! python3 - "$train/active/$pr.json" "$head" "$default" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
sys.exit(not (p['state'] == 'OPEN' and not p['isDraft'] and p['headRefOid'] == sys.argv[2] and p['baseRefName'] == sys.argv[3]))
PY
      then result_for "$pr" 1 "#$pr head, state, draft or base changed since queueing; run sid-merge again"; continue; fi
      branch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefName"])' "$train/active/$pr.json")
      git fetch -q origin "$branch" || { result_for "$pr" 1 "cannot fetch $branch"; continue; }
      [ "$(git rev-parse "origin/$branch")" = "$head" ] || { result_for "$pr" 1 "#$pr head changed since queueing; run sid-merge again"; continue; }
      out=$(merge_tree --write-tree "$main" "$head") || { result_for "$pr" 3 "conflicts with $default: merge origin/$default into $branch, then run sid-merge again"; continue; }
      if ! out=$(merge_tree --write-tree "$combined" "$head"); then
        flock 8; rm -f "$train/active/$pr"; flock -u 8
        continue
      fi
      tree=${out%%$'\n'*}
      # Model GitHub squash ancestry: earlier PR heads are not parents of main.
      synthetic=$(git -c user.name=sid-train -c user.email=sid-train@localhost commit-tree "$tree" -p "$combined" -m 'sid-train combined tree') || return 1
      combined=$synthetic; accepted+=("$pr"); trees[$pr]=$tree
    done
    [ "${#accepted[@]}" -gt 0 ] || { history failed; return; }
    candidates=("${accepted[@]}"); members="${candidates[*]}"
    tree=$(git rev-parse "$combined^{tree}")
    if ! SID_LANE=$("$here/sid-mode.sh" get lane 2>&1); then
      for pr in "${candidates[@]}"; do result_for "$pr" 1 "$SID_LANE" 'fix it with sid-mode.sh set'; done
      return 1
    fi
    export SID_LANE
    lane=$SID_LANE; state gating "${candidates[@]}"
    log=$gate/logs/train-$id.$main.log
    if ! gate_tree "$main" "$tree" "$log" "train $id: $default ${main:0:8} + $members"; then
      if [ "${#candidates[@]}" -gt 1 ]; then
        history split
        run_train "${candidates[@]:0:$((${#candidates[@]}/2))}"
        run_train "${candidates[@]:$((${#candidates[@]}/2))}"
      else
        pr=${candidates[0]}; rc=1
        if [ -n "$new_failures" ]; then
          message=$(printf 'gate FAILED: %s\nthese tests fail with #%s and pass on %s (run twice here, once on %s):\n%s\n' "$log" "$pr" "$default" "$default" "$new_failures")
        else
          message=$(printf 'gate FAILED: %s\n' "$log"; tail -n 25 "$log")
          if grep -q '^fail ' "$gate/health/$main" 2>/dev/null; then
            rc=4; message="main is red at ${main:0:8}, see $(sed -n 2p "$gate/health/$main")"
          fi
        fi
        [ "$rc" = 4 ] || note_failure "$pr"
        result_for "$pr" "$rc" "$message"; history failed
      fi
      return
    fi
    state merging "${candidates[@]}"
    expected=$main; merged=0; remaining=(); needs_rebuild=false; unsafe=false
    record="Gate-Passed: train $id, $default ${main:0:8} + $(printf '#%s ' "${candidates[@]}" | sed 's/ $//'), lane $lane, log sha256 $digest"
    noted=
    [ "$flaky" = 0 ] || noted="$flaky flaky"
    [ "$known" = 0 ] || noted="${noted:+$noted, }$known already failing on $default"
    [ -z "$noted" ] || record="$record, tests passed over: $noted"
    for pr in "${candidates[@]}"; do
      if [ "$needs_rebuild" = true ]; then remaining+=("$pr"); continue; fi
      head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$train/queue/$pr.req")
      member_tree=${trees[$pr]}
      rc=1
      for retry in 0 2 5 10; do
        sleep "$retry"
        if [ "$(git ls-remote origin "refs/heads/$default" | cut -f1)" != "$expected" ]; then needs_rebuild=true; break; fi
        validate "$pr" "$head" > "$train/active/$pr.check" 2>&1; rc=$?
        if [ "$rc" != 0 ]; then
          result_for "$pr" "$rc" "$(cat "$train/active/$pr.check")"
          needs_rebuild=true; break
        fi
        if [ "$(git ls-remote origin "refs/heads/$default" | cut -f1)" != "$expected" ]; then
          needs_rebuild=true; break
        fi
        if ! out=$(merge_tree --write-tree "$expected" "$head") || [ "${out%%$'\n'*}" != "$member_tree" ]; then
          needs_rebuild=true; break
        fi
        branch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefName"])' "$train/active/$pr.json")
        title=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$train/active/$pr.json")
        body=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["body"])' "$train/active/$pr.json")
        trailers=$(git log "$main..$head" --format='%(trailers:only,unfold)' | sed '/^$/d' | sort -u)
        message=$(printf '%s\n\n%s\n%s\n' "$body" "$trailers" "$record")
        # Persist the exact gated prefix before merging, including for crash recovery.
        printf '%s\n%s\n' "$expected" "$member_tree" > "$train/queue/$pr.merge"
        rc=1
        gh pr merge "$pr" --repo "$gh" --squash --match-head-commit "$head" --subject "$title (#$pr)" --body "$message" >/dev/null && { rc=0; break; }
        if ! message=$(disarm_auto "$pr"); then
          result_for "$pr" 1 "$message"; needs_rebuild=true; break
        fi
      done
      if [ "$needs_rebuild" = true ]; then
        [ ! -f "$train/queue/$pr.req" ] || remaining+=("$pr")
        continue
      fi
      if [ "$rc" != 0 ]; then result_for "$pr" 1 "merge refused for #$pr after retries"; needs_rebuild=true; continue; fi
      gh pr view "$pr" --repo "$gh" --json state,headRefOid,mergeCommit,autoMergeRequest > "$train/active/$pr.json"; rc=$?
      if [ "$rc" != 0 ] || ! oid=$(merged_oid "$pr" "$head"); then
        if ! message=$(disarm_auto "$pr"); then
          result_for "$pr" 1 "$message"; needs_rebuild=true; continue
        fi
        # A separate commit read can still confirm a landing after a failed status read.
        oid=
        if [ "$rc" != 0 ]; then
          oid=$(gh pr view "$pr" --repo "$gh" --json mergeCommit -q '.mergeCommit.oid // empty') || oid=
        fi
        if [ -n "$oid" ]; then
          result_for "$pr" 5 "merged #$pr as $oid, but the landed tree could not be verified"
          start_health; unsafe=true
        else
          result_for "$pr" 1 'the merge did not complete; nothing was cleaned up'
        fi
        needs_rebuild=true; continue
      fi
      landed_tree; rc=$?
      if [ "$rc" = 5 ]; then
        result_for "$pr" 5 "merged #$pr as $oid, but main now holds a tree no gate tested (landed on ${parent:0:8}, gated ${expected:0:8})"
        start_health; unsafe=true; needs_rebuild=true; continue
      elif [ "$rc" != 0 ]; then
        result_for "$pr" 5 "merged #$pr as $oid, but the landed tree could not be verified"
        start_health; unsafe=true; needs_rebuild=true; continue
      fi
      result_for "$pr" 0 "merged #$pr: $oid" "$record"
      merged=$((merged+1)); expected=$oid
      cleanup_branch "$branch"
    done
    # A main with failing tests of its own isn't healthy, so leave that one for the health check.
    if [ "$merged" != 0 ] && [ "$unsafe" = false ] && [ "$known" = 0 ]; then stamp_main "$tree"; fi
    if [ "$needs_rebuild" = false ]; then history merged; return; fi
    history failed
    candidates=("${remaining[@]}")
  done
  for pr in "${candidates[@]}"; do result_for "$pr" 1 'could not merge: default branch kept moving or readiness changed after three gates'; done
}
while true; do
  flock 8
  mapfile -t batch < <(python3 - "$train/queue" "$max" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
requests = [(json.loads(f.read_text())['queued'], int(f.stem)) for f in p.glob('*.req')]
for _, pr in sorted(requests)[:int(sys.argv[2])]:
    print(pr)
PY
  )
  if [ "${#batch[@]}" = 0 ]; then flock -u 8; break; fi
  for pr in "${batch[@]}"; do touch "$train/active/$pr"; done
  flock -u 8
  run_train "${batch[@]}" || exit 1
  flock 8; rm -f "$train/active/"*; flock -u 8
done
