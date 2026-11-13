#!/usr/bin/env bash
# sid-train: drain this repo's queue, gating combined trees and splitting failures oldest half first.
# Shares sid-gate's lock: trains and health must never build side by side.
# Exit: 0 drained, 1 runner/setup failure. Per-PR exit codes and messages live in train/result/<pr>.
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
exec 9>"$gate/lock"; flock 9
# Claims only protect cancellation; a dead runner's queue is safe to rebuild from scratch.
rm -f "$train/active/"*
gh=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1
bot=${SID_PR_BOT:-chatgpt-codex-connector}
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
  rm -f "$train/queue/$pr.req" "$train/active/$pr"
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
# Save a fresh readiness snapshot and verifier together; any failed check stays fail-closed.
validate() (
  local pr=$1 queued_head=$2
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  bot_mode=$("$here/sid-mode.sh" get bot) || exit 1
  need_bot=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["bot"]).lower())' "$train/queue/$pr.req") || exit 1
  ready
  [ "$head" = "$queued_head" ] || { echo "#$pr head changed since queueing; run sid-merge again"; exit 1; }
  [ "$base" = "$default" ] || { echo "#$pr's base just changed to $base; run sid-merge again"; exit 1; }
  ready_verdict
  cp "$tmp/pr.json" "$train/active/$pr.json"
  printf '%s\n' "$verified" > "$train/active/$pr.trailers"
  bot_waiver >> "$train/active/$pr.trailers"
)
after_merge() {
  local gated_tree=$1 newmain hookwt
  git fetch -q origin "$default" || return
  newmain=$(git rev-parse "origin/$default")
  if [ "$(git rev-parse "$newmain^{tree}")" = "$gated_tree" ]; then
    printf 'pass %s\n%s\n' "$lane" "$log" > "$gate/health/$newmain.tmp"
    mv "$gate/health/$newmain.tmp" "$gate/health/$newmain"
  fi
  [ "$(git ls-tree "$newmain" .sidstack/after-merge.sh | cut -d' ' -f1)" = 100755 ] || return 0
  # A private snapshot lets the next train reuse verify while deployment keeps running.
  hookwt=$repo-wt/after-merge-$id
  ( exec 7>&- 8>&- 9>&-
    exec setsid -f env PATH="$PATH" bash -c '
      repo=$1; wt=$2; sha=$3
      git -C "$repo" worktree add -q --detach "$wt" "$sha" || exit 1
      trap '\''git -C "$repo" worktree remove --force "$wt"'\'' EXIT
      cd "$wt" && .sidstack/after-merge.sh
    ' bash "$repo" "$hookwt" "$newmain" </dev/null >>"$train/after-merge.log" 2>&1
  ) &
}
run_train() {
  # Recursive halves get their own ids, logs, and main snapshots.
  local -a candidates=("$@") accepted=() remaining=()
  local pr head branch out tree combined synthetic rc record oid expected trailers message title body
  local id started lane main log members digest attempt merged retry needs_rebuild
  for attempt in 1 2 3; do
    [ "${#candidates[@]}" -gt 0 ] || return 0
    new_id
    members="${candidates[*]}"
    main=$(git rev-parse "origin/$default")
    state gating "${candidates[@]}"
    git fetch -q origin "$default" || { for pr in "${candidates[@]}"; do result_for "$pr" 1 'cannot fetch default branch'; done; history failed; return; }
    main=$(git rev-parse "origin/$default"); combined=$main; accepted=()
    for pr in "${candidates[@]}"; do
      head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$train/queue/$pr.req")
      # Check identity before readiness; only the queued head can be recovered or gated.
      if ! gh pr view "$pr" --repo "$gh" --json state,isDraft,baseRefName,headRefOid,headRefName,mergeCommit > "$train/active/$pr.json"; then result_for "$pr" 1 "could not read #$pr"; continue; fi
      # Recover a successful merge whose runner died before publishing its result.
      if oid=$(python3 - "$train/active/$pr.json" "$head" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
if p['state'] != 'MERGED' or p['headRefOid'] != sys.argv[2]:
    sys.exit(1)
oid = (p.get('mergeCommit') or {}).get('oid')
if not oid:
    sys.exit(1)
print(oid)
PY
      ); then
        branch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefName"])' "$train/active/$pr.json")
        result_for "$pr" 0 "merged #$pr: $oid (found already merged)"
        cleanup_branch "$branch"
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
      out=$(git merge-tree --write-tree "$main" "$head") || { result_for "$pr" 3 "conflicts with $default: merge origin/$default into $branch, then run sid-merge again"; continue; }
      if ! out=$(git merge-tree --write-tree "$combined" "$head"); then
        flock 8; rm -f "$train/active/$pr"; flock -u 8
        continue
      fi
      tree=${out%%$'\n'*}
      # merge-tree needs ancestry for the next member, not just the last tree.
      synthetic=$(git -c user.name=sid-train -c user.email=sid-train@localhost commit-tree "$tree" -p "$combined" -p "$head" -m 'sid-train combined tree') || return 1
      combined=$synthetic; accepted+=("$pr")
    done
    [ "${#accepted[@]}" -gt 0 ] || { history failed; return; }
    candidates=("${accepted[@]}"); members="${candidates[*]}"
    tree=$(git rev-parse "$combined^{tree}")
    SID_LANE=$("$here/sid-mode.sh" get lane) || return 1
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
        message=$(printf 'gate FAILED: %s\n' "$log"; tail -n 25 "$log")
        if grep -q '^fail ' "$gate/health/$main" 2>/dev/null; then
          rc=4; message="main is red at ${main:0:8}, see $(sed -n 2p "$gate/health/$main")"
        fi
        result_for "$pr" "$rc" "$message"; history failed
      fi
      return
    fi
    state merging "${candidates[@]}"
    expected=$main; merged=0; remaining=(); needs_rebuild=false
    record="Gate-Passed: train $id, $default ${main:0:8} + $(printf '#%s ' "${candidates[@]}" | sed 's/ $//'), lane $lane, log sha256 $digest"
    for pr in "${candidates[@]}"; do
      if [ "$needs_rebuild" = true ]; then remaining+=("$pr"); continue; fi
      head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$train/queue/$pr.req")
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
        branch=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["headRefName"])' "$train/active/$pr.json")
        title=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$train/active/$pr.json")
        body=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["body"])' "$train/active/$pr.json")
        trailers=$(git log "$main..$head" --format='%(trailers:only,unfold)' | sed '/^$/d' | sort -u)
        message=$(printf '%s\n\n%s\n%s\n%s\n' "$body" "$trailers" "$(cat "$train/active/$pr.trailers")" "$record")
        rc=1
        gh pr merge "$pr" --repo "$gh" --squash --match-head-commit "$head" --subject "$title (#$pr)" --body "$message" >/dev/null && { rc=0; break; }
      done
      if [ "$needs_rebuild" = true ]; then
        [ ! -f "$train/queue/$pr.req" ] || remaining+=("$pr")
        continue
      fi
      if [ "$rc" != 0 ]; then result_for "$pr" 1 "merge refused for #$pr after retries"; needs_rebuild=true; continue; fi
      oid=$(gh pr view "$pr" --repo "$gh" --json mergeCommit -q .mergeCommit.oid)
      result_for "$pr" 0 "merged #$pr: $oid" "$record"
      merged=$((merged+1)); expected=$oid
      cleanup_branch "$branch"
    done
    [ "$merged" = 0 ] || after_merge "$tree"
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
