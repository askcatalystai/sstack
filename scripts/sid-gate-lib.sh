#!/usr/bin/env bash
# Shared gate mechanics; source this, then gate_repo and gate_tree <main> <tree> <log> <description>.
# gate_tree returns 0 passed or 1 failed, leaving lane and digest for its caller.
set -u
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
