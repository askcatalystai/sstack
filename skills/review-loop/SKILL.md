---
name: review-loop
description: A Composer bug pass (pstack poteto bug-fix playbook) runs first, then Astra reviews, Claude takes the final call, the builder fixes once, Claude verifies and approves; risky PRs get one more model from another family. Use for "review loop", "sol loop" (Sol reviews instead), or before filing a PR.
---

# review-loop

Make your change more correct before filing a PR. Models come from
`~/.local/share/sidstack/models.md`. Every model runs as a subagent the orchestrator starts, never as a terminal
command. The builder changes nothing until the bug pass and Astra are done and Claude has
triaged. Review follows pstack's skeptical posture: only a bug a user would hit, a failed
gate or a wrong shipped doc blocks; the rest is a follow-up or gets declined.

## The sequence

The builder builds (Sol for logic, an Opus builder for visible UI) and the orchestrator commits it and opens the PR → **bug pass** (Composer) → the orchestrator commits its fixes → **Astra** reviews that commit with the bug-pass report and returns one list → the orchestrator takes the final call → the builder (the Opus builder for visible UI, Sol for logic) fixes once → **a fix that changes behaviour goes back to Astra**, for the changed code only (user, 2026-11-01) → the orchestrator verifies → Astra's approval of the head commit is recorded as the merge verdict (`sid-verdict.sh`) → merge train → live check. Risky PRs get one more model from another family (step 6), and `sid-mode.sh get reviewers` can narrow the reviewers to Astra alone or none. "sol loop": Sol only, up to 3 rounds. A model or round count the user names wins.

1. **Bug pass** (`bug pass` in models.md, Cursor Composer 2.5, started with `options: { fastMode: "false" }` — Plus rejects Composer without it), before Astra. It follows pstack's poteto-mode bug-fix playbook (`~/.local/share/pstack-src/pstack/skills/poteto-mode/playbooks/bug-fix.md`) and the fix-root-causes principle, applied to the change:
   - **Hunt:** read the diff and the code it touches; list candidate defects (correctness, races, data loss, security/privacy, auth, idempotency, error paths, regressions in callers).
   - **Reproduce each one:** a failing test (or a scripted run) that shows the defect. No repro, no finding: a hypothesis it cannot reproduce is reported as "unconfirmed", never fixed.
   - **Root-cause:** trace each reproduced symptom to the first wrong decision; fix there, not where it surfaced. Guards, retries and swallowed errors are not fixes unless the state is legitimate. Check for the same fault elsewhere in the change.
   - **Fix minimally:** the smallest change the evidence justifies, failing test first, then the fix; revert anything a refuted hypothesis motivated.
   - **Adversarial fixtures:** equal timestamps, ids that sort differently from time, empty and huge inputs, malformed config (could an error print a secret?). A fixture that spaces everything neatly hides ordering bugs (PR 54, 2026-11-01).
   - **Report**: each finding with repro command, failing-then-passing output, root cause, fix; and a list of hypotheses it ruled out. It never commits or pushes.
   If the bug pass can't run (provider error), retry once, then write it as skipped in the PR's `## Review` section and go on to Astra. The PR then counts as risky (step 6).
2. **Astra reviews** (`reviewer`) the commit that holds the change and the bug-pass fixes, with the bug-pass report: confirms, rejects with evidence, or adds what was missed. It reads the builder's test output in `## Proof` and reruns only a test it needs to confirm or refute a finding, through the repo's runner, never the suite; it says what it ran, and returns one list. Nobody edits the worktree while it runs.
3. **The orchestrator takes the final call** on Astra's list (ledger: accepted, or declined with a reason) and reads the diff for slop.
4. **The builder fixes once** (the Opus builder for visible UI, Sol for logic): every accepted finding in one brief.
5. **Fixes get reviewed.** A fix that changes behaviour goes back to Astra with the original finding and the changed code only. The orchestrator verifies every fix (diff, a focused test, and the real-database tests for runtime/persistence changes; skipped DB tests are a blocker, not a footnote). Each finding and its outcome goes in the PR's `## Review` section.
6. The PR is already open when shipping (`full-send` opens it before review). **Risky PRs get one more model.** For auth, payments, data, migrations, `commerce/`, the gate or merge scripts, or a PR that skipped a review step, add one review from the `risky review` line in `models.md`, a family that hasn't reviewed the PR yet, on the same commit as Astra (both only read it, so they can run together). A finding blocks the merge only when every model that reviewed the PR calls it risky; otherwise Claude decides and `## Review` says why (user 2026-11-13). There is no Codex bot: never comment `@codex review` or wait on it. Triage per `poteto-mode/references/bugbot-triage.md` (fix / dismiss with a concrete reason / ask); the builder fixes the accepted ones.

If Astra approves with no blocker or should, steps 4 and 5 don't apply. Astra's APPROVE on the head commit is the merge verdict: write the free-text review notes in the PR's `## Review` section as soon as it returns, then add as the last non-empty line of `## Review`: `Approved-Head: <sha> (<who>)` (12+ hex characters, e.g. `Approved-Head: d381a62361f3 (Astra)`) naming the exact head commit and approvers. A withdrawn approval must be recorded with an `Approval-Withdrawn:` line; remove it only after renewed approval.

Don't put `## Review` in examples or lone backticks before the trailer; the check fails closed on them.

## Rules

- **Every model runs as a subagent** (`delegate_task` in T3, target from `models.md`): Sol, Composer and Astra, one subagent per job, so each shows as its own thread. Never run a model from the terminal (`opencode run`, `codex exec`).
- Astra gets the brief, the commit to review and the bug-pass report. Each title names the card key, and each brief starts "Read ~/.local/share/sidstack/rules.md first."
  A diff over ~20 files is split by area, one brief per area. Never send secrets or customer data.
- A reviewer that times out or errors is retried once. If it still fails, write it as skipped in `## Review`, which makes the PR risky (step 6).
- Reviewers must not start subagents or reviewers.
- Keep one list of findings in `## Review`: source, severity, outcome. Never guess usage.

## 1. Scope

Run `git status --short`. Do not stash, discard, or include unrelated
changes. Limit review to the change paths if they separate cleanly.
Otherwise stop and ask.

Find the base after `git fetch origin`:

- PR: `gh pr view <n> --json baseRefName,headRefOid`. Check out the branch
  only if clean. Confirm `HEAD` is the PR head, or ahead only by this
  change. Base: `git merge-base HEAD origin/<baseRefName>`.
- Local: `git merge-base HEAD origin/<default-branch>`. No remote: a base
  the user names, or `HEAD` for uncommitted changes only.

The change is base to working tree in those paths, with untracked files.
Use one diff command all rounds. State intent and out-of-scope in 1-2
sentences. Run covering checks. Do not send code this change breaks. Note
missing or pre-failing checks in the brief.

## 2. Start the reviewer

In T3, call `orchestrator_capabilities` and confirm the reviewer role's
provider, model and effort exist. If it doesn't, say so and stop; do not
substitute. Record provider, model, and effort
only if exposed. Use `delegate_task` every round (`role: "review"`,
`mode: "async"`). Save `taskId`. New `clientRequestId` per round.
`childThreadId` is storage, not the next target. Do not use
`t3_thread_send`, `create_threads`, or `t3_thread_launch` for review.

If T3 tools aren't listed, try one direct capability call. If no route runs the reviewer, report the blocker. Do not
substitute a model.

Do not edit scoped files while review runs. Wait for the notice. Do not
poll or start a second reviewer. Timeout, error, or no reply is not
approval.

Round 1 brief (T3 children get no history):

```
Review only. Do not edit, commit, push, comment on PRs, or start subagents.
Repo: <abs path> Base: <sha> Intent: <intent> Out of scope: <scope> Checks: <results>
See: git diff <base> [-- <paths>]; git status --short (read untracked).
Read surrounding code. Find bugs, broken callers, mismatch with intent.
Skip style unless it hides a bug. Hold to the smallest change. For each new or
changed test: would it fail if the behavior broke, and pass if only internals
changed? If not, or if the change doesn't need it, flag it to rewrite or delete. Flag code,
tests, or guards the intent does not need. Other paths, rare cases, small
perf, extra compat: nits.
blocker = intended case wrong. should = real bug callers will hit, in intent. nit = rest.
Reply:
VERDICT: APPROVE or CHANGES
S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)
```

## 3. Answer findings

Check each finding and severity yourself. The orchestrator fixes small findings directly; larger ones go back to the implementer with the finding and the file:line. Another path, rare case, or
small cost is a nit, whatever label it came with.

- Agree: smallest fix. Prefer delete or narrow over new lock, cache,
  helper, or option. Fix the case that happened. Add one focused test
  that fails without the fix, if intent needs it.
- Disagree: say why, with evidence (file:line, test, output).
- Out of scope or nit: decline in one line. List as follow-up.

Update the ledger. Re-run checks and `git diff --shortstat <base>`. If
review grew the diff, cut first. Do not agree just to end the loop.

## 4. Re-review fixes

After Sol's fix, a behaviour change gets a fresh `delegate_task` to Astra with the round 1 brief, the findings and their outcomes (`fixed:` / `disagree:` / `declined:` + evidence), and the change since the last review. Tell it: open ids and changed code only. A fix with no behaviour change, such as a rename or a deleted comment, skips the re-review: renew `## Proof` for the new head and carry on. Sol doesn't get a third pass: two failures means the `Scrap` section in `full-send`.

## 5. Stop

Agreed: APPROVE on the current behaviour diff, no blocker or should open, no concern of your own. If an item stays disputed after two replies, it blocks only when every reviewer on the PR calls it risky; otherwise the orchestrator decides and `## Review` shows both sides in 2-3 lines each and the decision.

Report: rounds, what the review changed, diff size before and after, fixed and declined findings with reasons.
