#!/usr/bin/env bash
# sid-merge [--check] [--bot] [--no-wait] [--cancel] <pr>: check readiness, then join the repo's merge train.
# --check stops at readiness (including stacked PRs); --cancel withdraws a request not yet gating.
# Requests survive their caller. SID_TRAIN_INLINE=1 queues only; tests run the train themselves.
# Exit: 0 merged/ready/queued/cancelled, 1 not ready, 3 conflicts, 4 main red, 5 merged onto an ungated tree, 6 bot findings, 7 bot pending, 8 verdict.
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$here/sid-gate-lib.sh"
source "$here/sid-merge-lib.sh"
check=false; need_bot=false; no_wait=false; cancel=false
while [[ ${1:-} == --* ]]; do
  case "$1" in --check) check=true;; --bot) need_bot=true;; --no-wait) no_wait=true;; --cancel) cancel=true;; *) echo "unknown option: $1"; exit 1;; esac
  shift
done
pr=${1:?usage: sid-merge [--check] [--bot] [--no-wait] [--cancel] <pr>}
[[ $pr =~ ^[0-9]+$ ]] || { echo 'PR must be a number'; exit 1; }
gate_repo || exit 1
cd "$repo" || exit 1
exec 8>"$train/queue.lock"
if [ "$cancel" = true ]; then
  flock 8
  if [ -f "$train/active/$pr" ]; then echo "#$pr has started gating; cannot cancel"
  elif [ -f "$train/queue/$pr.req" ]; then
    printf '1\ncancelled\n' > "$train/result/$pr.tmp"
    mv "$train/result/$pr.tmp" "$train/result/$pr"
    rm -f "$train/queue/$pr.req"; echo "cancelled #$pr"
  else echo "#$pr is not queued"; fi
  exit 0
fi
gh=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1
bot=${SID_PR_BOT:-chatgpt-codex-connector}
bot_mode=$("$here/sid-mode.sh" get bot) || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ready
[ "$check" = true ] || [ "$base" = "$default" ] || { echo "#$pr is stacked on $base: land that first, rebase this onto $default, and set its base to $default"; exit 1; }
ready_verdict
if [ "$check" = true ]; then
  if [ "$base" = "$default" ]; then echo "ready: #$pr ${head:0:8}"; else echo "ready, but stacked on $base: #$pr ${head:0:8}"; fi
  exit 0
fi
flock 8
queued_head=
if [ -f "$train/queue/$pr.req" ]; then
  queued_head=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["head"])' "$train/queue/$pr.req") || exit 1
fi
if [ ! -f "$train/queue/$pr.req" ] || { [ ! -f "$train/active/$pr" ] && [ "$queued_head" != "$head" ]; }; then
  rm -f "$train/result/$pr" "$train/queue/$pr.merge"
  python3 - "$train/queue/$pr.req" "$head" "$need_bot" <<'PY'
import json, os, sys, time
path, head, bot = sys.argv[1:]
with open(path+'.tmp', 'w') as f:
    json.dump(dict(head=head, bot=bot == 'true', queued=time.time_ns()), f)
os.replace(path+'.tmp', path)
PY
  [ "$?" = 0 ] || { echo "could not queue #$pr"; exit 1; }
fi
flock -u 8
start_runner() {
  [ "${SID_TRAIN_INLINE:-}" != 1 ] || return 0
  local unit
  unit=sid-train-$(printf '%s' "$common" | sha256sum | cut -c1-16)
  if [ -z "${SID_TRAIN_INLINE+x}" ] && command -v systemd-run >/dev/null; then
    systemd-run --user --collect --unit="$unit" --working-directory="$repo" --setenv=PATH="$PATH" --setenv=HOME="$HOME" "$here/sid-train.sh" >/dev/null 2>&1 && return
  fi
  # A second runner waits on runner.lock, covering service shutdown/enqueue races too.
  ( exec 8>&-; exec setsid -f "$here/sid-train.sh" </dev/null >>"$train/runner.log" 2>&1 ) &
}
start_runner
if [ "$no_wait" = true ]; then echo "queued #$pr"; exit 0; fi
request_pending() {
  local pending
  flock 8
  if [ -f "$train/result/$pr" ]; then pending=false
  elif [ -f "$train/queue/$pr.req" ]; then pending=true
  else
    flock -u 8
    echo "#$pr has neither a request nor a result; run sid-merge again"
    exit 1
  fi
  flock -u 8
  [ "$pending" = true ]
}
while request_pending; do
  python3 - "$train/state.json" <<'PY'
import datetime, json, sys
try:
    s = json.load(open(sys.argv[1]))
    age = int((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(s['started'].replace('Z', '+00:00'))).total_seconds() / 60)
    print(f"train {s['id']}: {s['phase']} " + ' '.join(f'#{p}' for p in s['members']) + f", {s['lane'] or 'auto'} lane, {max(0, age)} min")
except (OSError, ValueError, KeyError):
    print('train: waiting for runner')
PY
  # Poll results promptly, with one progress line per minute.
  for ((i=0; i<60; i++)); do request_pending || break; sleep 1; done
  [ -f "$train/result/$pr" ] || start_runner
done
rc=$(head -n 1 "$train/result/$pr"); tail -n +2 "$train/result/$pr"
exit "$rc"
