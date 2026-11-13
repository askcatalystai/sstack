#!/usr/bin/env bash
# Shared gate mechanics; source this, then gate_repo and gate_tree <main> <tree> <log> <description>.
# gate_tree returns 0 passed or 1 failed, leaving lane, digest, flaky, known and new_failures for its caller.
#
# What a repo's .sidstack/gate.sh may do so only new test failures fail a PR (optional; without it any failure fails):
#   SID_FAILURES_OUT=<file>  write the tests that failed, one per line. Leave it non-empty only when every other check passed.
#   SID_RERUN=<file>         run only the tests listed, on the tree checked out, and report the same way.
#                            A listed test that doesn't exist on this tree counts as passing.
set -u
# merge_tree <args>: git merge-tree with the same settings GitHub uses, whatever the operator's config says.
# The pinned rename settings are assumed to match GitHub squash merges; a mismatch yields exit 3 or 5, never an ungated landing.
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
# run_gate <log> [VAR=value ...]: one run of the repo's gate in the verify worktree, appended to the log.
run_gate() {
  local log=$1; shift
  ( cd "$verify" && { [ -f .sidstack/gate.sh ] || { echo 'no .sidstack/gate.sh in this repo'; exit 1; }; } &&
    env "$@" bash .sidstack/gate.sh ) >> "$log" 2>&1
}
gate_tree() {
  local main=$1 tree=$2 log=$3 description=$4 rc failed=$3.failed again=$3.again base=$3.main
  lane=full; digest=; flaky=0; known=0; new_failures=
  echo "== gate: $description" > "$log" || return 1
  rm -f "$failed" "$again" "$base"
  [ -d "$verify" ] || git -C "$repo" worktree add -q --detach "$verify" "$main" || return 1
  # HEAD stays at main so the repo gate sees every member in its diff.
  git -C "$verify" checkout -q --detach -f "$main" && git -C "$verify" clean -qfd &&
    git -C "$verify" read-tree -u --reset "$tree" || return 1
  run_gate "$log" SID_FAILURES_OUT="$failed"; rc=$?
  if [ "$rc" != 0 ] && [ -s "$failed" ]; then
    # Only tests failed. Run just those again: what passes now was flaky, and what also fails on main isn't this tree's fault.
    echo "== gate: running the $(wc -l < "$failed") failed tests again" >> "$log"
    run_gate "$log" SID_RERUN="$failed" SID_FAILURES_OUT="$again"; rc=$?
    if [ "$rc" != 0 ] && [ -s "$again" ]; then
      new_failures=$(sort -u "$again")
      if [ "$(git -C "$repo" rev-parse "$tree^{tree}")" != "$(git -C "$repo" rev-parse "$main^{tree}")" ]; then
        echo "== gate: running them on ${main:0:8} alone" >> "$log"
        git -C "$verify" checkout -q --detach -f "$main" && git -C "$verify" clean -qfd &&
          run_gate "$log" SID_RERUN="$again" SID_FAILURES_OUT="$base"
        new_failures=$(comm -23 <(sort -u "$again") <(sort -u "$base" 2>/dev/null))
      fi
      if [ -z "$new_failures" ]; then rc=0; known=$(sort -u "$again" | wc -l); fi
    fi
    if [ "$rc" = 0 ]; then
      flaky=$(( $(sort -u "$failed" | wc -l) - known ))
      echo "== gate: passed; $flaky flaky, $known already failing on ${main:0:8}" >> "$log"
    fi
  fi
  git -C "$verify" checkout -q --detach -f "$main"
  git -C "$verify" clean -qfd
  lane=$(sed -n 's/^gate: lane \([^[:space:]]*\)[[:space:]]*$/\1/p' "$log" | tail -n 1); lane=${lane:-full}
  digest=$(sha256sum "$log" | cut -d' ' -f1)
  # Keep failed logs too: split trains and health results refer to them.
  ls -1t "$gate/logs" | tail -n +101 | while IFS= read -r old; do rm -f "$gate/logs/$old"; done
  [ "$rc" = 0 ]
}

# Shared queue startup for enqueue callers and the periodic health rescue.
start_runner() {
  [ "${SID_TRAIN_INLINE:-}" != 1 ] || return 0
  local unit
  unit=sid-train-$(printf '%s' "$common" | sha256sum | cut -c1-16)
  if [ -z "${SID_TRAIN_INLINE+x}" ] && command -v systemd-run >/dev/null; then
    systemctl --user is-active --quiet "$unit" 2>/dev/null && return 0
    systemd-run --user --collect --unit="$unit" --working-directory="$repo" --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$here/sid-train.sh" >>"$train/runner.log" 2>&1 && return
    # A responding manager alone is not evidence that a runner exists.
    local unit_state
    unit_state=$(systemctl --user show "$unit" --property=LoadState --property=ActiveState 2>/dev/null) &&
      grep -qx 'LoadState=loaded' <<< "$unit_state" &&
      ! grep -qx 'ActiveState=failed' <<< "$unit_state" && return 0
  fi
  # A second runner waits on runner.lock, covering service shutdown/enqueue races too.
  ( exec 7>&- 8>&- 9>&-; exec setsid -f "$here/sid-train.sh" </dev/null >>"$train/runner.log" 2>&1 ) &
}
