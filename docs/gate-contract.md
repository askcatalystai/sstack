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
| `SID_EXECUTION_RECEIPTS_OUT` | `TEST_BATCHES_EXECUTION_RECEIPTS_OUT` | JSONL execution receipts. Required when this nonempty variable is supplied for main-red verification; unused otherwise. |

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
fallback. Flaky counts include recovered known cases, never retry file counts.

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
or an infrastructure exit fails closed. Main-red additionally fails closed on
missing/empty/malformed execution output, duplicate identities, wrong scopes,
invalid counts, or any recorded identity lacking the required passed receipt.

Main-red stores comparison identities. Neither failure output alone nor runner
logs/reports substitute for execution receipts. Existing #1010 retry receipts
and comparison output remain unchanged; its producer change is forwarding and
populating `TEST_BATCHES_EXECUTION_RECEIPTS_OUT` under the rules above.
