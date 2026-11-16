# Gate reruns and red-main fix verification

Ordinary gates and baseline diagnosis retain `SID_FAILURES_OUT` (one failing
identity per line) and `SID_RERUN` (the identities to rerun). A missing test may
count as passing only during baseline diagnosis, when a PR adds a test absent
from main.

Baseline comparison only counts an exact `file::case` match as known on main.
A whole-file failure never counts as a known case. It remains new when main
also reports that file, or when the PR supplies no explicit failing cases.
A redundant file marker may be omitted from new failures only when main reports
per-case failures for that file and the PR supplies a nonempty failing case set
that is a subset of them. The file marker itself never increments known cases.

For red-main fix verification sstack also sets `SID_EXECUTION_RECEIPTS_OUT` to a
fresh absolute path. The **test runner** must write JSONL execution receipts there
from its completed test results, not from the selection/request list or a zero
process exit. Each requested identity needs exactly one receipt:

```json
{"identity":"tests/example.test.ts::suite > test", "status":"passed", "executed":1, "skipped":0}
```

`identity` must exactly match the requested identity. `executed` counts tests that
actually ran and passed; it must be a positive integer. `skipped` must be zero.
Missing, skipped, pending, failed, filtered-out, or zero-test results cannot be
reported as passed. Missing receipts, duplicate receipts and invalid evidence
fail verification in sstack even when `gate.sh` exits zero. Do not synthesize
receipts for missing files or unmatched test names.

For legacy file identities, the runner may aggregate the file's completed test
results into one receipt only when at least one test executed, every executed
test passed, and none was skipped. Per-test identities use their actual result.

Openec PR #1010 needs this runner integration: forward the environment variable
unchanged through `.sidstack/gate.sh` to the runner; write receipts using its
Node/Bun/Vitest result evidence after reruns finish; support both legacy file
identities and the new per-test identities from tests#599. Its current silent
missing-file success remains valid for baseline diagnosis, but is insufficient
for red-main verification. Until receipts are supplied, red-main fixes fail
closed in sstack. Existing ordinary green gates require no consumer change.
