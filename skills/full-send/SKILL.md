---
name: full-send
description: Trigger this if the user says 'full send'.
---

# Full Send

If the user triggered this, it's because they are not watching this thread, and
they want you to complete the work end-to-end autonomously. Your updates and
your final message go unread until long after you stop. You own the work from
its current state to a merged PR.

If the user did not explicitly request "full send" in some clear way, do not
assume full autonomy. If they did, everything below applies.

The user grants you permission to:

- Merge the PR once the merge gate passes.
- Force-push the PR's own branch with `--force-with-lease` after a rebase.
- Use the test methods that Proof needs, without asking first.

## Testing permission

A "full send" request is the permission. If a project file or other
instruction says to ask before a test method, or to leave testing to the
user, this request replaces that rule for this task.

That includes ask-first rules for computer use, browser automation,
simulators and devices, running the app or a dev server, screenshots, and
visual checks. Use the method that gives direct proof. List it in the
report.

Rules about how to test still apply. Follow rules that name the correct
command, fixture, or check. This permission only removes the ask-first or
leave-it-to-the-user step. If a preferred method cannot prove the change,
use a gated method under this permission.

It covers only the tests needed for this task. It does not add permission
for the steps under "Asking the user", such as production changes or data
deletion. It also does not bypass a harness or system approval prompt if
one appears.

## Roles

Models come from `~/.local/share/sidstack/models.md`. The implementer writes
logic in its own worktree (never the main checkout), the `ui builder` (Opus)
writes anything a user can see, and the orchestrator reviews it, makes small
fixes directly, and owns the PR. Read `~/.local/share/sidstack/rules.md` first.
`scripts/sid-mode.sh` prints the current arrangement and beats these defaults;
a role the user names for the session wins, and goes there with `sid-mode.sh set`.

## Steps

T3 Code is the orchestrator: every worker is a `delegate_task` thread, the PR is
linked to this thread, and `watch_pull_request` wakes you. In
`~/.local/share/sidstack/scripts/`, `sid-merge.sh [--check] <pr>` holds the
checks that shouldn't depend on judgment and queues the PR for the merge train.
`sid-gate.sh <branch>` runs the same gate on one branch; don't run it as well as the train, which already runs it, except when the PR's own purpose is the gate or the full suite.

1. **Define done and pick the playbook.** State the exit condition as something you
   can check. Match the task to a pstack playbook (`<pstack>/skills/poteto-mode/playbooks/`:
   `bug-fix`, `feature`, `refactoring`, `perf-issue` and others) and follow its steps,
   through `docs/adapter.md`. For nontrivial work, use `how` first and name the data shape;
   for code crossing a function boundary, use `architect`. Skip a step only by saying why.
   If an answer is a fact you can observe by running something, sketch it instead of asking.
2. **Brief and code.** Anything a user can see follows the `ui-lead` skill: Terra's before
   screenshots come first, an Opus builder writes it, and the orchestrator judges it before any other review. The brief has the user's goal in their words, the smallest change
   that meets it, the evidence that proves it's done, the area to work in, and any files
   parallel PRs own. It tells the worker to follow that playbook and the Tests section
   below. Use `delegate_task` on the implementer role, or the `ui builder` role for
   visible UI, with `isolation: "worktree"`. Put the card key in its title: that is how
   the board finds it. Every brief starts "Read ~/.local/share/sidstack/rules.md first.".
   T3 makes the worktree and a `t3/...` branch but doesn't run setup scripts for
   delegates, so the brief starts with the repo's setup command (project
   instructions name it). The builder reports its `pwd` and branch; it doesn't commit. Sol builders run on the Mac when it's linked (`docs/adapter.md`, "Which machine"): there the builder commits and pushes its branch, because you can't read its worktree from here, and its test runs stay off the machine the merge train uses. Reviews run here on a worktree of that branch. Before replying it runs what the gate will run for its diff (the repo's changed-tests command, eslint, typecheck), once, and pastes the output with pass counts in `## Proof`: reviewers read it instead of rerunning it, and a PR that fails in the train costs every PR in it a second gate.
   For a trivial change Claude may do this in a worktree itself.
   **Read the diff when it returns, before any review.** If it's bigger than the brief,
   touches unrelated files or is the wrong approach, scrap it (see "Scrap") and start a
   fresh worker with a sharper brief. Then run the slop pass: Claude Code's `simplify`,
   then `no-comments` (`comment-sicko`), then your own read for dead code and needless guards.
3. **Review** (see `review-loop`). First Claude commits, pushes and opens the PR
   (`file-pr`, `link_pull_request`, the card key in the body), so the review covers a
   commit and its result can be recorded. Then Composer's bug pass, then Astra on the
   committed result, each a `delegate_task` whose brief names the worktree path and the
   commit. Claude takes the final call, the builder (the Opus builder for visible UI, Sol
   for logic) fixes once through a new `delegate_task` naming the same path, a fix that
   changes behaviour goes back to Astra for the changed code, and Claude verifies each
   fix. Skip the fix pass if Astra approved cleanly. Astra's approval is the merge
   verdict, with no separate verifier run and nothing to record: write it in the PR's
   `## Review` section, ending with `Approved-Head: <sha> (<who>)` (12+ hex characters, e.g. `Approved-Head: d381a62361f3 (Astra)`), as the last non-empty line of `## Review`, which `sid-merge.sh` reads. A later
   fix that changes behaviour goes back to Astra; one that doesn't (a rename, a deleted
   comment) needs fresh `## Proof` and a renewed `Approved-Head:` trailer for the new head after confirming the approval still covers it. If any step is skipped, `## Review` says so
   and why, and the PR counts as risky (step 6).
4. **Prove it.** Run the real thing (see "Proof"). The author doesn't verify its own
   work: Claude or the bug pass runs it on the real surface. The evidence goes in the
   PR's `## Proof` section, naming the commit it covers: commands, pass counts,
   screenshot paths, and what wasn't checked. It can't be a copy of the review notes.
   This comes after the last fix. Claude commits first, and the brief names that commit. The verifier checks `git status` is clean and `git rev-parse HEAD` matches, runs the change the way a user would (the app, the command, the reproduction; not the test suite again), and ends with the commit and `PASS`, `PASS+NOTES` or `FAIL`. The verifier is Astra, whose review checks the builder's test output against the head commit and reruns only what a finding needs, or the orchestrator when it tests visible UI in the local app before merge, and never whoever wrote the code; tests after deploy come too late. Its result goes in `## Review`.
   Run checks so a failure stops you before you commit or push.
5. **Ship.** Push the last fixes with `--force-with-lease` and renew `## Proof` for
   the head commit. A risky PR goes to step 6; any other goes straight to step 7: with no CI,
   nothing would wake you.
6. **Risky PRs get one more model.** For auth, payments, data, migrations, `commerce/`, the gate or merge scripts, or a PR that skipped a review step, add one review from the `risky review` line in `models.md`, a family that hasn't reviewed the PR yet, on the same commit as Astra (both only read it, so they can run together). A finding blocks the merge only when every model that reviewed the PR calls it risky; otherwise Claude decides and `## Review` says why (user 2026-11-13). There is no Codex bot: never comment `@codex review` or wait on it. Its result is in `## Review` before step 7. Claude triages its findings per
   `<pstack>/skills/poteto-mode/references/bugbot-triage.md` (fix, dismiss with a reason,
   or ask); noise doesn't get code. On any PR, conflicts: merge the default branch in the
   worktree and run `sid-merge.sh` again.
7. **Merge.** `sid-merge.sh <pr>` refuses until the PR is ready (`## Proof` must
   name the head commit, so a later push needs fresh proof, and `## Review` must include
   `Approved-Head: <sha> (<who>)` (12+ hex characters, e.g. `Approved-Head: d381a62361f3 (Astra)`) as the last non-empty line of `## Review`, after the free-text review notes, naming the exact head commit and approvers), then queues it for the
   merge train and waits for the result. The train gates every queued PR together,
   once, on the latest main, squash-merges them in order using each PR body as the
   commit message, and removes the worktree and branch. Run it in the background and
   wait with `t3_background_wait`; the train runs under systemd, so it finishes even if
   this thread doesn't. The gate runs failed tests a second time and then on main alone,
   so a flaky test or one already failing on main doesn't fail your PR; what it reports
   is what your change broke. Exit 1 means this PR failed the gate: it names the tests
   your change broke, or prints the log tail. Read the log and fix it. The same commit
   goes back only once, with `sid-merge.sh --retry <pr>`, and only for a flake or an
   infrastructure failure; after a second failure it takes a new commit. Exit 3 is a
   conflict with main, and 4 means main itself fails lint, types or the build: fix main
   first. Then `unwatch_pull_request`.
8. **Check it live** once deployed, then report: the PR link, the merge commit,
   your proof, what was checked on prod and what wasn't, and each decision you
   made for the user.

If you give up before the merge, call `unwatch_pull_request` first.

The Kanzo board (http://localhost:4242, MCP `kanzo`) follows the work by itself:
`scripts/sid-board.py` sets each card from facts every 20 seconds. A running subagent
whose title names the card puts it in Doing or Review, a PR whose body names the card
links it, the train puts it in Deployment, and the deploy puts it in Done. So name the
card key (`chat#299`) in every `delegate_task` title and PR body, and don't move cards
by hand. Your part is the comments a script can't write: review findings and what you
decided, what you're waiting on, anything waiting on the user, and the prod check. The
user follows work from the board and may not read the chat. The card is the
record of what the work asks for; Kanzo is the source of truth, not a plan file.
`sid-board.py status` prints where every card stands.

**Don't wait on Deployment.** Review and local testing are finished by then, so the next card starts as soon as a card reaches Deployment. If it depends on that card's unmerged work, branch from that card's branch; once the parent squash-merges, `git rebase --onto origin/main <parent-head>` before `sid-merge.sh`. Its Deployment queue merges in order, and prod checks catch up after each deploy. Until then `sid-merge.sh --check` can pass a stacked PR, but `sid-merge.sh` won't merge it until its base is main.

Card labels show who is working (provider, model and effort), what the card is doing
now (`queued`, `gating`, `deploying`, `idle 40m`, `needs-you`), time in the column, and
the `#` is the `pr-<n>` tag. The board sets all of them; put none in the title. A thread
that stops with unfinished work gets a "continue" from the watchdog
(`sid-board.py nudge`), up to three times, and then the card is flagged for the user.

Don't put `## Review` in examples or lone backticks before the trailer; the check fails closed on them.

## Proof

Proof is evidence you observed yourself in this session: command output, a
reproduction, a screenshot. Use the most direct proof the change allows:

- Reproduce the original failure, apply the fix, then watch the same
  reproduction pass.
- The builder's run of the repo's checks (typecheck, lint, the changed tests through its runner), once, with the output pasted. Nobody reruns them unless a finding needs it; the train's gate runs them again on the merged tree.
- For a bug with a cheap, obvious test target, write the test first and watch it
  fail for the right reason. See "Tests".
- For UI and runtime behavior, run the app and look at the change. Green mocked
  tests do not prove that the user experience works. Attach screenshots to the
  PR when they help and you have a way to upload them.

When you cannot find a way to prove a change, you do not have full confidence.
Ask the user.

## Scrap

Work that doesn't earn its place gets thrown away, not patched.

- **Two failed attempts at the same goal:** stop. Write down the premise and test it
  (`principle-attack-the-premise`), then replan, or park it with the reason on the card.
  This also applies when each review round finds one more case of the same kind of bug.
- **Discard what didn't help.** A change that might help but has no evidence gets reverted.
- **The user rejects it:** a `reject: <reason>` comment on the PR means run
  `scripts/sid-scrap.sh <pr> "<reason>"` and move the card back to Backlog with the reason.
  On merged work, `revert: <reason>` means `scripts/sid-scrap.sh --revert <pr> "<reason>"`.
  Kanzo comments don't wake you, so run `scripts/sid-card.py inbox` at every step and before
  ending a turn. Any comment from the user comes first, with or without `flag:`. Reply on the card, saying what
  you'll do.
- **Never leave scrapped work half-kept:** the PR, branch and worktree go together.

Report anything scrapped, and why.

## Tests

Follow pstack's `principle-test-behavior-not-implementation` and `tdd`. Prefer no
new test over a bad test; a change doesn't need a test just because it's a change.

Judge every test you write, change or keep with two imagined edits:

- **Break the behavior.** The test must fail. If it still passes, it proves nothing.
- **Change only the internals.** The test must still pass. If it fails, it's pinned
  to the implementation.

Keep the tests that do both; rewrite or delete the rest.

- Write one for a bug with a cheap target, or a rule users or another service rely
  on. Skip it when it would mostly test mocks, need broad setup, depend on timing,
  or only prove a small UI change; the running app is that proof.
- Don't mock what you can run. Mock only outside services, and assert what they
  receive.
- Never read source text, pin prompt wording, or pin an exact message no caller reads.
- A failing test on the default branch gets fixed or deleted, never skipped.
- The gate runs tests for the changed area. Don't run a whole large suite to check
  a small change.

## Merge gate

Full confidence means all of these are true on the latest commit:

- Your proof covers every change in the diff.
- Required checks are green, if the repo has any.
- Each review finding is fixed or dismissed with a written reason. Risky PRs had one
  more model's review, and no finding every reviewer called risky is still open.
- The train's gate passed on the head merged with the latest default branch and the
  other queued PRs.
- No human review still requests changes.
- The branch is up to date with the default branch, and GitHub reports it as
  mergeable.

Merge with the method the repo uses. Check the allowed methods and recent merged
PRs. If the repo uses a merge queue or auto-merge, stay until GitHub reports the
PR as merged. Merge through branch protection as configured. Never use `--admin`
or other bypasses. You can ignore automated reviews that request "needs human
review" if you have high confidence in your changes.

## Asking the user

A question in a normal message goes unseen, and the thread looks done. To ask
the user something, use the harness's question tool so the thread shows that
it is waiting: `AskUserQuestion` in Claude Code, `request_user_input` in Codex,
or the question tool your harness has. Put all the context in the question:
the PR link, what blocks you, and the options with your recommendation first.

Ask only when you cannot continue alone:

- You cannot prove the change.
- The merge gate cannot pass, and you cannot fix that yourself.
- The next step is outside the grant above: deleting data, touching production,
  changing things outside the repo, closing a PR, or force-pushing any other
  branch.
- The goal is ambiguous in a way that changes the result.
- Another PR makes this one obsolete.

Decide everything else yourself with sensible defaults, and list those decisions
in the report.

If no question tool is available, or the tool returns no answer, take the safe
path: leave the PR open and unmerged, and start your final message with the
question.
