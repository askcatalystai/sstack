#!/usr/bin/env bash
# Shared gate mechanics; source this, then gate_repo and gate_tree <main> <tree> <log> <description>.
# gate_tree returns 0 passed or 1 failed, leaving lane and digest for its caller.
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
  mkdir -p "$gate/logs" "$gate/health" "$train/queue" "$train/result" "$train/active"
}
gate_tree() {
  local main=$1 tree=$2 log=$3 description=$4 rc
  lane=full; digest=
  : > "$log" || return 1
  [ -d "$verify" ] || git -C "$repo" worktree add -q --detach "$verify" "$main" || return 1
  # HEAD stays at main so the repo gate sees every member in its diff.
  git -C "$verify" checkout -q --detach -f "$main" && git -C "$verify" clean -qfd &&
    git -C "$verify" read-tree -u --reset "$tree" || return 1
  ( cd "$verify" && echo "== gate: $description" &&
    { [ -f .sidstack/gate.sh ] || { echo 'no .sidstack/gate.sh in this repo'; exit 1; }; } &&
    bash .sidstack/gate.sh ) > "$log" 2>&1; rc=$?
  git -C "$verify" checkout -q --detach -f "$main"
  git -C "$verify" clean -qfd
  lane=$(sed -n 's/^gate: lane \([^[:space:]]*\)[[:space:]]*$/\1/p' "$log" | tail -n 1); lane=${lane:-full}
  digest=$(sha256sum "$log" | cut -d' ' -f1)
  # Keep failed logs too: split trains and health results refer to them.
  ls -1t "$gate/logs" | tail -n +51 | while IFS= read -r old; do rm -f "$gate/logs/$old"; done
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
