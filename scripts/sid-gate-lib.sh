#!/usr/bin/env bash
# Shared gate mechanics; source this, then gate_repo and gate_tree <main> <tree> <log> <description>.
# gate_tree returns 0 passed or 1 failed, leaving gate_outcome (passed/failed/infrastructure), lane, digest, flaky, opaque_flaky, known and new_failures for its caller.
#
# Gate protocol: retry receipts, comparison identities and execution receipts for retry recovery/main-red.
#   SID_FAILURES_OUT=<file> retry receipts only; never use these for comparison.
#   SID_FAILURE_IDENTITIES_OUT=<file> exact encoded cases or opaque identities, one per line.
#   SID_RERUN=<file>         run only the tests listed, on the tree checked out, and report the same way.
#                            Absent identities may pass only for baseline diagnosis.
#   SID_EXECUTION_RECEIPTS_OUT=<file> runner JSONL evidence, required for retry recovery and main-red fixes; see docs/gate-contract.md.
set -u
gate_worker=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate_worker.py
# merge_tree <args>: git merge-tree with the same settings GitHub uses, whatever the operator's config says.
# The pinned rename settings are assumed to match GitHub squash merges; a mismatch fails closed before landing.
# Only here: fetch and push still need the global config, which holds the credential helper for private repos.
merge_tree() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -c merge.renames=true -c merge.directoryRenames=conflict \
    -c merge.renameLimit=0 -c diff.renameLimit=0 merge-tree "$@"
}
gate_repo() {
  repo=$(git rev-parse --show-toplevel) || return 1
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 1
  repo=$(dirname "$common")
  default=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  default=${default#origin/}; default=${default:-main}
  verify=$repo-wt/verify; gate=$common/sid-gate; train=$gate/train
  mkdir -p "$gate/logs" "$gate/health" "$train/queue" "$train/result" "$train/active" "$train/failed"
}
# Every flock acquisition must reconcile a lease left by a killed holder.
gate_lock() {
  flock "$@" 9 || return $?
  [ ! -e "$gate/admission-paused" ] || { echo 'gate admission paused'; exit 1; }
  python3 "${gate_worker%/*}/gate_lease.py" recover "$gate/lease.json" "$repo" || exit 1
}
# run_gate <log> [VAR=value ...]: one run of the repo's gate in the verify worktree, appended to the log.
run_gate() {
  local log=$1; shift
  ( exec 7>&- 8>&-; cd "$verify" && { [ -f .sidstack/gate.sh ] || { echo 'no .sidstack/gate.sh in this repo'; exit 1; }; } &&
    exec env SID_GATE_LOCK_FD=9 python3 "$gate_worker" "$$" --lease-v2 env "$@" bash .sidstack/gate.sh ) >> "$log" 2>&1 &
  local worker=$! rc=0
  wait "$worker" || rc=$?
  # A killed supervisor cannot vouch for body shutdown. Stop before tree cleanup;
  # the lease holder retains the gate lock until cleanup and expiry.
  if [ "$rc" -ge 128 ]; then exit "$rc"; fi
  return "$rc"
}
# Each invocation gets its own log and fresh comparison sidecar. Never initialize
# the sidecar here: its existence proves the consumer supports the contract.
gate_attempt() {
  local log=$1 tag=$2 rc; shift 2
  local part=$log.$tag.log
  rm -f "$log.$tag.identities" "$log.$tag.executions.jsonl" "$log.executed-$tag"
  : > "$part"
  run_gate "$part" SID_FAILURE_IDENTITIES_OUT="$log.$tag.identities" SID_EXECUTION_RECEIPTS_OUT= "$@"; rc=$?
  cat "$part" >> "$log"
  return "$rc"
}
gate_tree() {
  local main=$1 tree=$2 log=$3 description=$4 rc failed=$3.failed again=$3.again base=$3.main
  gate_outcome=failed; lane=full; digest=; flaky=0; opaque_flaky=0; known=0; new_failures=
  echo "== gate: $description" > "$log" || return 1
  rm -f "$failed" "$again" "$base" "$log.red-tests" "$log.red-again" "$log.red-fix.executions.jsonl" "$log.main.identities"
  local SID_LANE=${SID_LANE:-full} full_required=false
  export SID_LANE
  if [ -f "$gate/health/main-red" ]; then
    full_required=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("full_check_required",False)).lower())' "$gate/health/main-red") || return 1
    [ "$full_required" != true ] || SID_LANE=full
  fi
  # Never reuse an abandoned attempt's checkout, even if its workload escaped
  # supervision. Git's common object store is shared; mutable indexes are not.
  verify=$(python3 "${gate_worker%/*}/gate_lease.py" prepare "$gate" "$repo" "$$" "$main") || return 1
  local manifest=$gate/attempts/${verify##*/verify-}.json
  # HEAD stays at main so the repo gate sees every member in its diff.
  git -C "$verify" checkout -q --detach -f "$main" && git -C "$verify" clean -qfd &&
    git -C "$verify" read-tree -u --reset "$tree" || {
      python3 "${gate_worker%/*}/gate_lease.py" remove "$manifest" "$repo"
      return 1
    }
  gate_attempt "$log" candidate SID_FAILURES_OUT="$failed"; rc=$?
  local candidate_proof=false
  if [ "$rc" = 124 ]; then
    gate_outcome=infrastructure; rc=1
    new_failures='infrastructure: candidate timed out (exit 124); no forgiveness'
  elif python3 "${gate_worker%/*}/gate_failures.py" check "$log.candidate.identities" "$rc" >> "$log" 2>&1 &&
      { [ "$rc" != 0 ] || [ ! -s "$failed" ]; }; then
    candidate_proof=true
  else
    rc=1; new_failures="candidate identity evidence missing, empty on failure, or invalid; no forgiveness"
  fi
  if [ "$candidate_proof" = true ] && [ "$rc" != 0 ] && [ -s "$failed" ] &&
      python3 "${gate_worker%/*}/gate_failures.py" check "$log.candidate.identities" "$rc" >> "$log" 2>&1; then
    echo "== gate: running the failed retry receipts again" >> "$log"
    gate_attempt "$log" retry SID_RERUN="$failed" SID_FAILURES_OUT="$again" SID_EXECUTION_RECEIPTS_OUT="$log.executed-retry"; rc=$?
    local recovered_counts=
    if [ "$rc" = 124 ]; then
      gate_outcome=infrastructure; rc=1
      new_failures='infrastructure: retry timed out (exit 124); no forgiveness'
    elif ! python3 "${gate_worker%/*}/gate_failures.py" check "$log.retry.identities" "$rc" >> "$log" 2>&1; then
      rc=1
      new_failures='retry has no valid failure-identity evidence; no forgiveness'
    elif ! recovered_counts=$(python3 "${gate_worker%/*}/gate_receipts.py" --recovered "$log.candidate.identities" "$log.retry.identities" "$log.executed-retry" 2>> "$log"); then
      rc=1
      new_failures='retry lacks passing execution receipts for recovered identities; no forgiveness'
    elif [ "$rc" = 0 ] && [ ! -s "$log.retry.identities" ] && [ ! -s "$again" ]; then
      rc=0
    elif [ "$rc" != 0 ]; then
      new_failures=$(sort -u "$log.retry.identities")
      local base_rc=1
      echo "== gate: running retry receipts on ${main:0:8} alone" >> "$log"
      if git -C "$verify" checkout -q --detach -f "$main" && git -C "$verify" clean -qfd; then
        gate_attempt "$log" main SID_RERUN="$again" SID_FAILURES_OUT="$base"; base_rc=$?
      fi
      if python3 "${gate_worker%/*}/gate_failures.py" check "$log.main.identities" "$base_rc" >> "$log" 2>&1; then
        new_failures=$(python3 "${gate_worker%/*}/gate_failures.py" new "$log.retry.identities" "$log.main.identities") || new_failures='comparison evidence invalid; no forgiveness'
        known=$(python3 "${gate_worker%/*}/gate_failures.py" known "$log.retry.identities" "$log.main.identities") || known=0
        if [ "$base_rc" != 0 ]; then
          python3 "${gate_worker%/*}/train_health.py" "$gate/health" "$repo" "$main" "$log" "$log.main.identities"
        fi
      fi
      if [ "$base_rc" = 124 ]; then
        gate_outcome=infrastructure
        new_failures='infrastructure: main-only diagnosis timed out (exit 124); no forgiveness'
      fi
      rc=1
    else
      rc=1; new_failures='successful retry reported failure outputs; no forgiveness'
    fi
    if [ -n "$recovered_counts" ]; then read -r flaky opaque_flaky <<< "$recovered_counts"; fi
    echo "== gate: $flaky flaky tests, $opaque_flaky recovered opaque files, $known known cases failing on main" >> "$log"
  fi
  if [ "$rc" = 0 ] && [ -f "$gate/health/main-red" ]; then
    if python3 "${gate_worker%/*}/gate_receipts.py" "$gate/health/main-red" "$log.red-tests"; then
      if [ -s "$log.red-tests" ]; then
        gate_attempt "$log" red-fix SID_RERUN="$log.red-tests" SID_FAILURES_OUT="$log.red-again" SID_EXECUTION_RECEIPTS_OUT="$log.red-fix.executions.jsonl"; rc=$?
        if [ "$rc" = 124 ]; then
          gate_outcome=infrastructure; new_failures='infrastructure: main-red verification timed out (exit 124); no forgiveness'
        fi
        [ ! -s "$log.red-again" ] || rc=1
        python3 "${gate_worker%/*}/gate_failures.py" check "$log.red-fix.identities" "$rc" >> "$log" 2>&1 || rc=1
        [ ! -s "$log.red-fix.identities" ] || rc=1
        python3 "${gate_worker%/*}/gate_receipts.py" "$gate/health/main-red" "$log.red-tests" "$log.red-fix.executions.jsonl" >> "$log" 2>&1 || rc=1
      fi
    else
      rc=1
    fi
  fi
  git -C "$verify" checkout -q --detach -f "$main"
  git -C "$verify" clean -qfd
  python3 "${gate_worker%/*}/gate_lease.py" remove "$manifest" "$repo" || return 1
  lane=$(sed -n 's/^gate: lane \([^[:space:]]*\)[[:space:]]*$/\1/p' "$log" | tail -n 1); lane=${lane:-full}
  if [ "$full_required" = true ] && [ "$lane" != full ]; then rc=1; new_failures="main health recovery requires a verified full lane"; fi
  digest=$(sha256sum "$log" | cut -d' ' -f1)
  # Keep failed logs too: train and health results refer to them.
  ls -1t "$gate/logs" | tail -n +101 | while IFS= read -r old; do rm -f "$gate/logs/$old"; done
  [ "$rc" != 0 ] || gate_outcome=passed
  [ "$rc" = 0 ]
}

# Shared queue startup for enqueue callers and the periodic health rescue.
start_runner() {
  [ "${SID_TRAIN_INLINE:-}" != 1 ] || return 0
  local unit
  unit=sid-train-$(printf '%s' "$common" | sha256sum | cut -c1-16)
  if [ -z "${SID_TRAIN_INLINE+x}" ] && command -v systemd-run >/dev/null; then
    systemctl --user is-active --quiet "$unit" 2>/dev/null && return 0
    # Four times the default CPU share: the train decides merges, so it wins over agent worktrees when the machine is busy.
    systemd-run --user --collect --unit="$unit" --working-directory="$repo" --property=CPUWeight=400 --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$here/sid-train.sh" >>"$train/runner.log" 2>&1 && return
    # A responding manager alone is not evidence that a runner exists.
    local unit_state
    unit_state=$(systemctl --user show "$unit" --property=LoadState --property=ActiveState 2>/dev/null) &&
      grep -qx 'LoadState=loaded' <<< "$unit_state" &&
      ! grep -qx 'ActiveState=failed' <<< "$unit_state" && return 0
  fi
  # A second runner waits on runner.lock, covering service shutdown/enqueue races too.
  ( exec 7>&- 8>&- 9>&-; exec setsid -f "$here/sid-train.sh" </dev/null >>"$train/runner.log" 2>&1 ) &
}
