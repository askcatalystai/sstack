#!/usr/bin/env bash
# run-job.sh <id> <plan> <role> <provider> <model> <effort> <cwd> <out> <log> -- <prompts...>
set -u
D=$(cd "$(dirname "$0")" && pwd)
if [ "${1:-}" = --worker ]; then
  shift
  id=$1 plan=$2 role=$3 provider=$4 model=$5 effort=$6 cwd=$7 out=$8 log=$9; shift 10
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
setsid bash "$0" --worker "$@" &
pid=$!
echo "$pid" > "$COUNCIL_STATE/runs/$id.pid"
python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" running "$log" "$pid"
wait "$pid"; rc=$?
python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" "$([ $rc = 0 ] && echo done || echo failed)" "$log" "$pid"
exit "$rc"
