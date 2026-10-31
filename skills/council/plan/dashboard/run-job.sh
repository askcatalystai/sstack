#!/usr/bin/env bash
# run-job.sh <id> <plan> <role> <model> <effort> <cwd> <outfile> <logfile> -- <prompt files...>
# Runs one Codex or OpenCode job (review jobs are read-only), shows it on the board, and records how it ended.
set -u
D=$(cd "$(dirname "$0")" && pwd)
id=$1 plan=$2 role=$3 model=$4 effort=$5 cwd=$6 out=$7 log=$8; shift 9
sandbox=workspace-write; extra=(--add-dir "$(dirname "$out")"); [ "$role" = review ] && { sandbox=read-only; extra=(); }
# provider/model ids (opencode-go/deepseek-v4.1-flash) run through OpenCode; the rest through Codex.
provider=openai; case $model in */*) provider=$(case $model in *deepseek*) echo deepseek;; *muse*) echo muse;; *) echo opencode;; esac);; esac
python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" running "$log"
if [ "$provider" != openai ]; then
  # Reviews use OpenCode's read-only plan agent; --auto approves what that agent does not deny (reads, git diff).
  agent=build; [ "$role" = review ] && agent=plan
  (cd "$cwd" && opencode run -m "$model${effort:+#$effort}" --agent "$agent" --auto "$(cat "$@")" > "$out" 2> "$log"); rc=$?
  python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" $([ $rc = 0 ] && echo done || echo failed) "$log"
  exit $rc
fi
for attempt in 1 2 3 4; do
  cat "$@" | (cd "$cwd" && codex exec -m "$model" -c model_reasoning_effort="$effort" --sandbox "$sandbox" "${extra[@]}" -o "$out" - > "$log" 2>&1)
  rc=$?
  # Same model only: wait and retry when the provider reports it is at capacity.
  if grep -q "at capacity" "$log" && [ ! -s "$out" ]; then sleep $((attempt * 90)); continue; fi
  break
done
python3 "$D/jobs.py" upsert "$id" "$plan" "$role" "$provider" "$model" "$effort" $([ $rc = 0 ] && echo done || echo failed) "$log"
exit $rc
