---
name: review-loop
description: Review a change in a fixed sequence (DeepSeek and Muse twice, Astra once), then Sol fixes everything once, before the PR bot reviews the PR. Use for "review loop", "sol loop" (Sol reviews instead), or before filing a PR.
---

# review-loop

Make your change more correct before filing a PR. Models come from
`~/.local/share/sidstack/models.md`. Reviews come first; Sol changes nothing
until Astra has reviewed.

## The sequence

Default: two panel rounds (DeepSeek and Muse in parallel, no fixes between) + one gate round (Astra), then Sol fixes once.
"light review": one panel round + gate, then Sol once; "sol loop": Sol only, up to 3 rounds.

1. **Panel round 1**: DeepSeek and Muse (`review panel`), in parallel, full
   review of the change.
2. **Panel round 2**: DeepSeek and Muse again, in parallel, on the same code
   plus the combined round-1 ledger. Each one confirms or rejects every finding
   (with evidence) and adds what both missed. No code changes between rounds.
3. **Astra** (`reviewer`, low), **one pass**, on the change plus the checked
   ledger. This is the gate: it gives the verdict and its own findings.
4. **Sol fixes once**, through the orchestrator: every accepted blocker and
   should from all three reviewers in one brief. The orchestrator declines nits
   and findings it disproved, with a reason in the ledger.
5. **The orchestrator verifies every fix** against the ledger (diff, checks,
   a focused test where the finding needs one) and records the approval for the
   fixed change. Astra does not run again unless a fix changed behavior beyond
   its finding.
6. File the PR. The **PR bot** (Codex GitHub bot) reviews it automatically;
   `babysit-pr` / `cm.sh bot-review` handle its findings the same way.

If Astra approves with no blocker or should open, step 4 is skipped and the
approval stands as is.

"light review" (the user's words, routine changes): panel round 1 only, then
Astra, then Sol once. "sol loop": Sol reviews alone, up to 3 rounds. A model or
round count the user names for the run wins.

## Rules

- **In T3 Code every review round is a `delegate_task` subagent** (`role: "review"`, `mode: "async"`, target from `models.md`), one per reviewer per round, so it shows as its own thread. Never run reviewers from the terminal (`opencode run`, `codex exec`) in T3. The only terminal reviewers are `cm.sh review` rounds inside a council plan, which feed the plan board.
- Panel members get narrow briefs: at most ~20 files or one area each. Split
  a bigger diff by area and run the pieces in parallel. Never send them
  secrets or customer data (Muse trains on requests).
- A panel member that times out or errors is noted in the ledger and the
  sequence continues; it is not waited on again.
- Stop early (skip to Astra) only if round 1 returns nothing but nits.
- Reviewers must not start subagents or reviewers.
- Keep one ledger across all rounds: id, source (DeepSeek/Muse/Astra/bot),
  round, severity, outcome. Never guess usage.

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

If T3 tools are not listed, try one direct capability call. Outside T3, run
a Codex reviewer with `codex exec -m <model> -c model_reasoning_effort=<effort>
--sandbox read-only`. If no route runs the reviewer, report the blocker. Do not
substitute a model.

Do not edit scoped files while review runs. Wait for the notice. Do not
poll or start a second reviewer. Timeout, error, or no reply is not
approval. On failure, cancel, verify stop, restart with the ledger.

Round 1 brief (T3 children get no history):

```
Review only. Do not edit, commit, push, comment on PRs, or start subagents.
Repo: <abs path> Base: <sha> Intent: <intent> Out of scope: <scope> Checks: <results>
See: git diff <base> [-- <paths>]; git status --short (read untracked).
Read surrounding code. Find bugs, broken callers, mismatch with intent.
Skip style unless it hides a bug. Hold to the smallest change. Flag code,
tests, or guards the intent does not need. Other paths, rare cases, small
perf, extra compat: nits.
blocker = intended case wrong. should = real bug callers will hit, in intent. nit = rest.
Reply:
VERDICT: APPROVE or CHANGES
S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)
```

## 2b. Review panel

Alongside the reviewer, send the same round-1 brief to each `review panel`
member in `models.md` (DeepSeek and Muse by default), in parallel, read-only.
Split a diff over ~20 files by area, one brief per area per member. Panel
findings go into the same ledger with their source; the reviewer's verdict is
still the gate. A panel member that times out or errors is noted, not waited on
again. Never send the panel secrets or customer data.

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

## 4. Next round

Start one only if budget remains and a blocker or should is open, behavior code
changed, or approval does not cover the current behavior diff. Use a fresh
`delegate_task` in T3, or follow up the saved native ID. Send the round 1 brief,
the ledger (`fixed:` / `disagree:` / `declined:` + evidence), the same base
diff, and the change since last round. Tell the reviewer: open ids and changed code only.
Mark each old id `resolved` or `still open: <reason>`.

## 5. Stop and ship

Agreed: APPROVE on the current behavior diff, no blocker or should open,
no concern of your own. Stuck: an item stays disputed after two replies,
or budget ends. Show both sides in 2-3 lines each. The user decides.
Budget end is not approval.

Do not push during the loop. Push after agreement only if the user asked
to push, ship, or update the PR. If you push to a PR, add above the model
blurb:

`Reviewed with review-loop: <N> rounds with <model>. Verdict: approved`.

Add `on <effort>` only if verified.

Report: rounds, model, what the review changed, diff size before/after, fixed and
declined findings with reasons, usage if exposed (else say not), pushed or not.
