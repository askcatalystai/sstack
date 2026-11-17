#!/usr/bin/env bash
# sid-health [--all | --wait]: full gate on the fetched default branch, or on each ~/.config/sidstack/repos entry.
# PRs take priority: skip queued/busy repos, and let a train terminate a running health gate.
# --wait is an explicit post-landing check: wait for the shared gate, then check fresh main in full.
# Exit: 0 passed/skipped, 1 failed. Results and logs stay under sid-gate/health and sid-gate/logs.
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
if [ "${1:-}" = --all ]; then
  rc=0
  if [ -f "$HOME/.config/sidstack/repos" ]; then
    while IFS= read -r path || [ -n "$path" ]; do
      [ -d "$path" ] || continue
      ( cd "$path" && "$here/sid-health.sh" ) || rc=1
    done < "$HOME/.config/sidstack/repos"
  fi
  exit "$rc"
fi
wait_gate=false
if [ "${1:-}" = --wait ]; then wait_gate=true; shift; fi
[ "$#" = 0 ] || { echo 'usage: sid-health [--all | --wait]'; exit 1; }
source "$here/sid-gate-lib.sh"
gate_repo || exit 1
cd "$repo" || exit 1
git fetch -q origin "$default" || exit 1
main=$(git rev-parse "origin/$default")
exec 8>"$train/queue.lock"; flock 8
exec 9>"$gate/lock"
if [ "$wait_gate" = true ]; then
  # Do not hold queue.lock while waiting: the train needs it to finish its batch.
  flock -u 8
  gate_lock
  git fetch -q origin "$default" || exit 1
  main=$(git rev-parse "origin/$default")
else
  if compgen -G "$train/queue/*.req" >/dev/null; then
    exec 7>"$train/runner.lock"
    if flock -n 7; then
      flock -u 7
      start_runner
    fi
    exit 0
  fi
  if [ ! -f "$gate/health/main-red" ] && grep -Eq '^pass full$' "$gate/health/$main" 2>/dev/null; then exit 0; fi
  gate_lock -n || exit 0
fi
printf '%s %s\n' "$$" "$(awk '{print $22}' /proc/$$/stat)" > "$gate/health.pid"
child=
cleanup() {
  if [ -n "$child" ]; then kill -TERM -- "-$child" 2>/dev/null; wait "$child" 2>/dev/null; fi
  rm -f "$gate/health.pid"
}
trap cleanup EXIT
trap 'exit 1' TERM INT
flock -u 8
log=$gate/logs/health-$main.log
# A separate process group lets preemption stop the gate and its build children together.
export SID_LANE=full
setsid bash -c 'source "$1"; gate_repo; gate_tree "$2" "$2^{tree}" "$3" "health: $2"' bash "$here/sid-gate-lib.sh" "$main" "$log" &
child=$!; wait "$child"; rc=$?; child=
lane=$(sed -n 's/^gate: lane \([^[:space:]]*\)[[:space:]]*$/\1/p' "$log" | tail -n 1); lane=${lane:-full}
# An existing block can only clear on full evidence, never a reported fast lane.
if [ -f "$gate/health/main-red" ] && [ "$lane" != full ]; then rc=1; fi
status=pass; [ "$rc" = 0 ] || status=fail
printf '%s %s\n%s\n' "$status" "$lane" "$log" > "$gate/health/$main.tmp"
mv "$gate/health/$main.tmp" "$gate/health/$main"
if [ "$rc" = 0 ]; then
  rm -f "$gate/health/main-red"
else
  python3 "$here/train_health.py" "$gate/health" "$repo" "$main" "$log" --full-check-required || exit 1
fi
echo "health: $repo ${main:0:8} $status $lane, $log"
[ "$rc" = 0 ]
