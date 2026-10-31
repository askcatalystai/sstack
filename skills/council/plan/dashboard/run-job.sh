#!/usr/bin/env bash
# run-job.sh <id> <plan> <role> <provider> <model> <effort> <cwd> <out> <log> -- <prompts...>
set -u
D=$(cd "$(dirname "$0")" && pwd)
export COUNCIL_STATE=${COUNCIL_STATE:-$HOME/.local/state/council/current}
[ -f "$COUNCIL_STATE/config.json" ] && [ -d "$COUNCIL_STATE/runs" ] || { echo "run-job: no current plan" >&2; exit 1; }
if [ "${1:-}" = --worker ]; then
  shift
  id=$1 plan=$2 role=$3 provider=$4 model=$5 effort=$6 cwd=$7 out=$8 log=$9; shift 10
  echo "$$" > "$COUNCIL_STATE/runs/$id.pid"
  trap 'rm -f "$COUNCIL_STATE/runs/$id.pid"' EXIT
  cd "$cwd" || exit 1
  case $provider in
    codex)
      sandbox=workspace-write; extra=(--add-dir "$(dirname "$out")")
      [ "$role" = review ] && { sandbox=read-only; extra=(); }
      for attempt in 1 2 3 4; do
        : > "$out"
        codex exec -m "$model" -c model_reasoning_effort="$effort" --sandbox "$sandbox" "${extra[@]}" -o "$out" - < <(cat "$@") > "$log" 2>&1
        rc=$?
        if [ "$attempt" -lt 4 ] && grep -q 'at capacity' "$log" && [ ! -s "$out" ]; then
          sleep $((attempt * 90)); continue
        fi
        break
      done
      exit "$rc";;
    opencode)
      agent=build; [ "$role" = review ] && agent=plan
      opencode run -m "$model${effort:+#$effort}" --agent "$agent" --auto "$(cat "$@")" > "$out" 2> "$log";;
    *) echo "unsupported runner provider: $provider" > "$log"; exit 1;;
  esac
  exit $?
fi
id=$1 plan=$2 role=$3 provider=$4 model=$5 effort=$6 out=$8 log=$9
# Truncate old output so a failed rerun cannot inherit a previous verdict.
: > "$out"
pid=""; interrupted=""
trap 'interrupted=1; [ -z "$pid" ] || kill -TERM -- "-$pid" 2>/dev/null || true' INT TERM
setsid bash "$0" --worker "$@" &
pid=$!
[ -z "$interrupted" ] || kill -TERM -- "-$pid" 2>/dev/null || true
trap 'rm -f "$COUNCIL_STATE/runs/$id.pid"' EXIT
python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" running "$log" "$pid"
wait "$pid"; rc=$?
# A trapped signal can interrupt wait before the worker has exited.
if kill -0 "$pid" 2>/dev/null; then wait "$pid" || true; fi
python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" "$([ $rc = 0 ] && echo done || echo failed)" "$log" "$pid"
exit "$rc"
