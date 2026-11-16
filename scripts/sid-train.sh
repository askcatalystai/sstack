#!/usr/bin/env bash
# sid-train: drain this repo's queue, gating and landing one PR at a time on current main.
# Shares sid-gate's lock: trains and health must never build side by side.
# Exit: 0 drained, 1 runner/setup failure. Per-PR codes live in train/result/<pr>;
# Main moves are rejected atomically by an explicit lease; receipts recover interrupted pushes.
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
  local branch=$1 expected_head=$2 wt current
  # A contributor may push after the final PR read or close. Never delete that head.
  if ! git push -q --force-with-lease="refs/heads/$branch:$expected_head" origin ":refs/heads/$branch"; then
    current=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
    if [ -n "$current" ] && [ "$current" != "$expected_head" ]; then
      gh pr reopen "$pr" --repo "$gh" || true
    fi
    echo "kept $branch: remote head changed or deletion refused"; return
  fi
  rm -f "$gate/${branch//\//_}.pass"
  [ "$(git rev-parse "refs/heads/$branch" 2>/dev/null)" = "$expected_head" ] || return 0
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} $0=="branch "b{print w}')
  if [ -n "$wt" ] && ! git worktree remove "$wt"; then
    echo "kept $wt: it has uncommitted or untracked files"; return
  fi
  git update-ref -d "refs/heads/$branch" "$expected_head" || echo "kept changed local branch $branch"
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
  dependencies_ready || exit 1
  main_ready || exit 4
  [ "$head" = "$queued_head" ] || { echo "#$pr head changed since queueing; run sid-merge again"; exit 1; }
  [ "$base" = "$default" ] || { echo "#$pr's base just changed to $base; run sid-merge again"; exit 1; }
  cp "$tmp/pr.json" "$train/active/$pr.json"
)
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
  rm -f "$gate/health/main-red"
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
  [ "$#" = 1 ] || { echo "serial train requires exactly one PR"; return 1; }
  # Only a single member is admitted: every landed prefix has its own verdict.
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
      if oid=$(python3 "$here/train_landing.py" recover "$pr" "$head" "$default"); then
        branch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefName"])' "$train/active/$pr.json")
        if ! python3 "$here/train_landing.py" close "$pr" "$head" "$default" "$gh"; then
          echo "landed #$pr as $oid; PR close pending, retry the train"; return 1
        fi
        result_for "$pr" 0 "merged #$pr: $oid (found already merged)"
        if retarget_children "$branch"; then cleanup_branch "$branch" "$head"
        else echo "kept $branch: could not retarget its children"; fi
        continue
      fi
      if ! python3 - "$train/active/$pr.json" "$head" "$default" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
sys.exit(not (p['state'] == 'OPEN' and not p['isDraft'] and p['headRefOid'] == sys.argv[2] and p['baseRefName'] == sys.argv[3]))
PY
      then result_for "$pr" 1 "#$pr head, state, draft or base changed since queueing; run sid-merge again"; continue; fi
      validate "$pr" "$head" > "$train/active/$pr.check" 2>&1; rc=$?
      if [ "$rc" != 0 ]; then
        result_for "$pr" "$rc" "$(cat "$train/active/$pr.check")"; continue
      fi
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
        pr=${candidates[0]}; rc=1
        if [ -n "$new_failures" ]; then
          message=$(printf 'gate FAILED: %s\nfailures not confirmed as the same cases on %s:\n%s\n' "$log" "$default" "$new_failures")
        else
          message=$(printf 'gate FAILED: %s\n' "$log"; tail -n 25 "$log")
          if grep -Eq '^(fail |main red$)' "$gate/health/$main" 2>/dev/null; then
            rc=4; message="main is red at ${main:0:8}, see $(sed -n 2p "$gate/health/$main")"
          fi
        fi
        [ "$rc" = 4 ] || note_failure "$pr"
        result_for "$pr" "$rc" "$message"; history failed
      return
    fi
    state merging "${candidates[@]}"
    expected=$main; merged=0; remaining=(); needs_rebuild=false; unsafe=false
    record="Gate-Passed: train $id, $default ${main:0:8} + $(printf '#%s ' "${candidates[@]}" | sed 's/ $//'), lane $lane, log sha256 $digest"
    noted=
    [ "$flaky" = 0 ] || noted="$flaky flaky"
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
        oid=$(python3 "$here/train_landing.py" prepare "$pr" "$head" "$default" "$expected" "$member_tree" "$train/active/$pr.json" "$record") || return 1
        if git push --no-verify --force-with-lease="refs/heads/$default:$expected" origin "$oid:refs/heads/$default"; then
          rc=0; break
        fi
        rc=1
        # A transport error may follow a successful push. Confirm the exact planned
        # commit by ancestry before retrying; otherwise a moved main needs a new gate.
        if python3 "$here/train_landing.py" recover "$pr" "$head" "$default" >/dev/null; then rc=0; break; fi
        if [ "$(git ls-remote origin "refs/heads/$default" | cut -f1)" != "$expected" ]; then needs_rebuild=true; break; fi
      done
      if [ "$needs_rebuild" = true ]; then
        [ ! -f "$train/queue/$pr.req" ] || remaining+=("$pr")
        continue
      fi
      if [ "$rc" != 0 ]; then result_for "$pr" 1 "merge refused for #$pr after retries"; needs_rebuild=true; continue; fi
      if ! python3 "$here/train_landing.py" recover "$pr" "$head" "$default" >/dev/null; then
        echo "cannot confirm pushed commit $oid; receipt retained for recovery"; return 1
      fi
      if ! python3 "$here/train_landing.py" close "$pr" "$head" "$default" "$gh"; then
        echo "landed #$pr as $oid; PR close pending, retry the train"; return 1
      fi
      result_for "$pr" 0 "merged #$pr: $oid" "$record"
      merged=$((merged+1)); expected=$oid
      if retarget_children "$branch"; then cleanup_branch "$branch" "$head"
      else echo "kept $branch: could not retarget its children"; fi
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
  batch_rc=0
  for member in "${batch[@]}"; do
    run_train "$member" || batch_rc=1
  done
  [ "$batch_rc" = 0 ] || exit 1
  flock 8; rm -f "$train/active/"*; flock -u 8
done
