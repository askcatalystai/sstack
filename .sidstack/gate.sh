#!/usr/bin/env bash
set -eu
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# This producer runs the full check, without per-case diagnosis or forgiveness.
# Empty identities on failure prove nothing and are rejected by the consumer.
for output in "${SID_FAILURES_OUT:-}" "${SID_FAILURE_IDENTITIES_OUT:-}" "${SID_EXECUTION_RECEIPTS_OUT:-}"; do
  [ -z "$output" ] || : > "$output"
done
export SID_LANE=full
bash scripts/check.sh
