# Gate retry receipts, comparison identities and main-red execution evidence

This implements openec PR #1010's `sstack #28 contract` at head
`644b25f208e1de1068dd52768670e4b168570dfa`.

## Independent outputs for each invocation

- `SID_FAILURES_OUT` is forwarded as `TEST_BATCHES_FAILURES_OUT`. These are
  **retry receipts**, not comparison identities: safe Node/Vitest case selections,
  whole files for Bun/opaque failures, or `package:name` commands.
- `SID_FAILURE_IDENTITIES_OUT` is forwarded as
  `TEST_BATCHES_FAILURE_IDENTITIES_OUT`. It contains comparison identities, one
  per line, also available as `report.json.failureIdentities`.

Sstack supplies fresh, distinct identity paths and logs for candidate, retry,
main-only and red-fix invocations. The gate/runner must initialize the sidecar,
including on success, and clear both output files on infrastructure timeouts.
Sstack does not create an empty sidecar on the consumer's behalf. Missing outputs,
nonzero exits with empty identities, and infrastructure exits fail closed. A zero
exit with nonempty failure identities is also invalid.

## Comparison and forgiveness

A known case has the exact form `relative/file::encodeURIComponent(caseName)`.
Sstack compares these encoded strings exactly; it never interprets names as
regular expressions. Bare file paths and `package:name` are opaque. Grouped Node
failures and suite/hook failures must retain their opaque component.

```
known = candidate known cases intersect main known cases
new   = all opaque candidate identities + (candidate known cases - main known cases)
```

The candidate here is the still-failing retry. Opaque identities always stay new,
even if main emits the same string, or the same file also has a matching case.
The former file-marker subset exception is removed. There is no fallback to retry
receipt intersections, filenames or human-readable log parsing. Recovery counts
only known case identities that disappeared on a successful retry, never files.

## Main-red verification

Main-red records the comparison identities, not retry receipts. Each recorded
known case must actually execute and pass. A recorded opaque file must run clean
as a whole file, with positive executed-test evidence and no failures or skips.
Failure sidecars alone cannot establish that missing/skipped tests ran. When a
file has both opaque and known recorded identities, its whole-file request
overrides narrower case selectors; the resulting evidence must still prove every
recorded known case passed. Filtered execution never proves an opaque file clean.

Sstack verifies the current invocation's durable runner evidence advertised by
`Batch evidence: ...`: completed `report.json`, clean attempts, Vitest's structured
`browserReport`, or Node/Bun execution results in the attempt logs. Paths must
belong to the active verification checkout. Encoded case names are decoded only
for matching actual executed results. Missing cases, missing files, skipped cases,
empty selections, opaque unhandled errors and incomplete evidence fail closed.
For opaque Node files, a clean unfiltered whole-file summary with positive test
count can establish execution even when individual suite names are opaque.

Consumers may alternatively emit explicit JSONL execution receipts through
`SID_EXECUTION_RECEIPTS_OUT`. Each recorded identity needs exactly one receipt:

```json
{"identity":"relative/file::encoded%20case","status":"passed","executed":1,"skipped":0}
```

These must derive from actual completed results, not from the request list. Opaque
files require a whole-file aggregate with a positive executed count and no skips.
Opaque package commands without auditable execution evidence remain blocked.

The existing #1010 Node/Bun/Vitest evidence is supported without requiring a new
execution-output variable in that consumer. Its failure-identity sidecar is
mandatory; silent missing-file success cannot clear main-red.
