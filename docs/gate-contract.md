# Unified gate contract: sstack #28 / openec #1010

This is the single producer/consumer contract. Keep #1010's comparison sidecar
and add one execution sidecar. Execution-log parsing and the former optional
receipt fallback are removed.

## Variables and formats

All output variables contain absolute file paths supplied by sstack. The repo
gate forwards them unchanged to the runner:

| Repo gate variable | Runner variable | Format and purpose |
| --- | --- | --- |
| `SID_FAILURES_OUT` | `TEST_BATCHES_FAILURES_OUT` | UTF-8 retry receipts, one per line; safe Node/Vitest case selections, whole files for Bun/opaque failures, or `package:name`. Never comparison proof. |
| `SID_FAILURE_IDENTITIES_OUT` | `TEST_BATCHES_FAILURE_IDENTITIES_OUT` | UTF-8 comparison identities, one per line. Required for every invocation. |
| `SID_EXECUTION_RECEIPTS_OUT` | `TEST_BATCHES_EXECUTION_RECEIPTS_OUT` | JSONL execution receipts. Required whenever this nonempty variable is supplied: retry recovery and main-red verification. |

`SID_RERUN` is an input file. Ordinary retries/main-only diagnosis consume retry
receipts. Main-red verification consumes recorded comparison identities: known
cases select the exact case; opaque files/packages request their whole scope.
If an opaque file and cases in that file are recorded together, sstack requests
the whole file once but still verifies execution receipts for every recorded case.

## Shared identity format and comparison

- Known case: `relative/file::encodeURIComponent(caseName)`.
- Opaque: a bare relative file path or `package:name`.

Identity strings are identical in comparison and execution outputs. Compare
encoded case strings exactly; never interpret names as regexes or infer a case
from a filename. Opaque suite/hook/grouped failures retain their opaque entry,
even when the same file also emits named failures.

```
known = candidate known cases intersect main known cases
new   = all opaque candidate entries + (candidate known cases - main known cases)
```

Here candidate means the still-failing retry. Opaque entries always remain new,
even if main emits the same string. There is no subset exception or filename
fallback. Flaky test counts include only recovered known cases. Recovered opaque
files are counted separately as files in the gate note and squash record, never
as named tests.

## Execution receipts

The runner writes one final JSON object per identity from actual completed test
results. Emit case receipts for all reliably identified cases that ran, including
cases encountered during a whole-file request. Emit a file/package aggregate
only for its actual unfiltered whole-scope execution. This lets one whole-file
run prove both an opaque file and recorded cases inside it.

```json
{"identity":"tests/a.test.ts::suite%20%3E%20case","scope":"case","status":"passed","executed":1,"skipped":0}
{"identity":"tests/a.test.ts","scope":"file","status":"passed","executed":8,"skipped":0}
{"identity":"package:example","scope":"package","status":"passed","executed":12,"skipped":0}
```

Required fields:

- `identity`: the exact shared identity string; no decoding/re-encoding changes.
- `scope`: `case` for a known identity, `file` for a bare file, `package` for `package:name`.
- `status`: `passed`, `failed`, `skipped`, `missing`, or `incomplete`.
- `executed`, `skipped`: nonnegative JSON integers counting actual tests, not
  selected files, suite headings or successful commands; booleans are invalid.
  Counts describe distinct tests in the final completed result, not retry attempts.

To accept a successful retry, every identity in the original candidate failure
sidecar needs exactly one `passed` execution receipt from that retry. An empty
retry failure sidecar or process exit 0 does not prove anything ran. For partial
recovery, every candidate identity absent from the still-failing retry must have
the same passing proof before it can be counted as recovered; an opaque file
requires a clean unfiltered whole-file receipt. Missing execution proof fails the
gate and prevents landing. Main-only diagnosis does not require passing receipts
for absent tests and cannot substitute for retry proof.

To clear main-red, every recorded identity needs exactly one `passed` receipt
with `skipped:0`. A case requires `executed:1`; a whole file/package requires
`executed>0`. Whole-scope `passed` also means all tests passed, with no hooks,
suite errors, pending/cancelled tests, incomplete reporting or infrastructure
errors. A filtered/partial file run must not emit a passed `file` aggregate.

Missing/unmatched cases or files, zero tests, skipped cases and opaque results
without reliable counts must not receive passed receipts. Omit them or report
`missing`, `skipped`, or `incomplete`. Duplicate/ambiguous names must not generate
case receipts; a clean unfiltered file can still generate a file aggregate.
A zero process exit or a request/selection list is never execution proof.

## Invocation lifecycle and fail-closed rules

Sstack supplies distinct fresh paths for candidate, retry, main-only and red-fix
invocations and removes previous files. The producer initializes each requested
output at invocation start; sstack does not fabricate empty supported outputs.
Write final execution receipts only after result collection completes, preferably
by atomic replacement. On infrastructure failure, clear/invalidate all requested
outputs, including execution receipts.

A successful invocation has empty retry and comparison outputs. A nonzero test
exit needs nonempty comparison identities for diagnosis; a missing/unsupported
comparison sidecar, an empty identity file on nonzero exit, contradictory success outputs,
or an infrastructure exit fails closed. Retry recovery and main-red additionally fail closed on
missing/empty/malformed execution output, duplicate identities, wrong scopes,
invalid counts, or any identity being forgiven/verified lacking the required passed receipt.

Main-red stores comparison identities. Neither failure output alone nor runner
logs/reports substitute for execution receipts. Existing #1010 retry receipts
and comparison output remain unchanged; its producer change is forwarding and
populating `TEST_BATCHES_EXECUTION_RECEIPTS_OUT` under the rules above.

## Stale main-red recovery

A missing identity on the candidate is not evidence that main is green. Sstack
keeps the block and includes the marker path and recovery procedure in admission
and gate-failure messages; it does not automatically prune recorded failures.

If a recorded identity no longer exists on **current main**, pause the queue and
runner first. Audit the current-main tests and the marker's log. Edit the marker
to retain every valid failure; if a renamed or opaque failure still applies,
replace the obsolete identity with its current identity or whole-file scope. Only
remove an identity confirmed obsolete on current main, never one absent only on
a proposed fix. If no valid failures remain, archive the marker while admission
is paused. Run `sid-health.sh --wait` and require a green full gate of current main
before resuming the queue. If that gate fails, restore/reconcile the blocking
marker and fix main before resuming. This is an explicit audited manual escape,
not permission for a candidate to clear a missing test automatically.

Child retargeting is limited to five list/edit passes. Failure to settle retains
the parent branch and reports the failure so children never lose their live base.

## Sstack's native producer

`.sidstack/gate.sh` always runs the complete `scripts/check.sh` in the full lane.
It initializes all requested sidecars to empty before running that workload.
Success therefore supplies supported, empty comparison and retry outputs.
Sstack does not currently produce per-case failure diagnosis or execution
receipts: failure with empty comparison identities fails closed, and no sstack
failure may be forgiven as flaky or known on main. This producer mode changes
no openec contract and grants no exception in the gate library. The producer
fixture uses the real wrapper with only the expensive check workload substituted;
the complete check is also run through the real wrapper for shipping proof.

## Undiagnosed main-health failures

Every unsuccessful main-health gate persists a card-linked `main-red` marker,
even when infrastructure fails or comparison/retry evidence is unavailable.
The marker contains the existing `card`, `sha`, `log`, and `tests` fields, plus
`full_check_required: true`. Known test identities are retained; an empty `tests`
list is permitted only with that explicit flag and means diagnosis is unknown,
not that main passed. The card/log describe the missing diagnosis. Kanzo being
unreachable retains the durable fallback card reference and prints the failure.

Such a marker forces `SID_LANE=full` and requires the producer's reported lane
to be full. A successful candidate must still supply valid empty failure outputs;
any retained known identities additionally require the usual passing execution
receipts. With no identities, no empty filtered rerun is used as proof: the fresh
full candidate gate is the proof. Admission still permits only a PR naming the
card as its fix. The block clears only on a verified green full main-health run
or when the exact full-gated fix tree lands. Failed health records are never
cached as a reason to skip future periodic verification.
