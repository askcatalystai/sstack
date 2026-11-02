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
the change in its own worktree (never the main checkout); the orchestrator
reviews it, makes small fixes directly, and owns the PR. A role the user names
for the session wins.

## Steps

T3 Code is the orchestrator: every worker is a `delegate_task` thread, the PR is
linked to this thread, and `watch_pull_request` wakes you. Two scripts in
`~/.local/share/sidstack/scripts/` hold the checks that shouldn't depend on
judgment: `sid-gate.sh <branch>` and `sid-merge.sh [--check] <pr>`.

1. **Define done and pick the playbook.** State the exit condition as something you
   can check. Match the task to a pstack playbook (`<pstack>/skills/poteto-mode/playbooks/`:
   `bug-fix`, `feature`, `refactoring`, `perf-issue` and others) and follow its steps,
   through `docs/adapter.md`. For nontrivial work, use `how` first and name the data shape;
   for code crossing a function boundary, use `architect`. Skip a step only by saying why.
   If an answer is a fact you can observe by running something, sketch it instead of asking.
2. **Brief and code.** Anything a user can see follows the `ui-lead` skill: Terra's before
   screenshots come first, and Opus judges Sol's UI before any other review. The brief has the user's goal in their words, the smallest change
   that meets it, the evidence that proves it's done, the area to work in, and any files
   parallel PRs own. It tells the worker to follow that playbook and the Tests section
   below. Use `delegate_task` on the implementer role with `isolation: "worktree"`.
   T3 makes the worktree and a `t3/...` branch but doesn't run setup scripts for
   delegates, so the brief starts with the repo's setup command (project
   instructions name it). Sol reports its `pwd` and branch; it doesn't commit. Before replying it runs what the gate will run for its diff (the repo's changed-tests command, eslint, typecheck), because a gate is minutes of everyone's queue. Check the gate's exit status before opening a PR or writing "gate passed" in it.
   For a trivial change Claude may do this in a worktree itself.
   **Read the diff when it returns, before any review.** If it's bigger than the brief,
   touches unrelated files or is the wrong approach, scrap it (see "Scrap") and start a
   fresh worker with a sharper brief. Then run the slop pass: Claude Code's `simplify`,
   then `no-comments` (`comment-sicko`), then your own read for dead code and needless guards.
3. **Review** (see `review-loop`): Composer bug pass, then Astra, each a
   `delegate_task` whose brief names Sol's worktree path. Claude takes the final
   call, Sol fixes once through a new `delegate_task` naming the same path, a fix that
   changes behaviour goes back to Astra for the changed code, and Claude verifies each
   fix. Skip the fix pass if Astra approved cleanly. If any step is skipped, the PR's
   `## Review` section says "skipped" and why, and `sid-merge.sh` then requires the bot.
4. **Prove it.** Run the real thing (see "Proof"). The author doesn't verify its own
   work: Claude or the bug pass runs it on the real surface. The evidence goes in the
   PR's `## Proof` section, naming the commit it covers: commands, pass counts,
   screenshot paths, and what wasn't checked. It can't be a copy of the review notes.
   This comes after the last fix. Claude commits first, and the brief names that commit. The verifier checks `git status` is clean and `git rev-parse HEAD` matches, runs the change, and ends with the commit and `PASS`, `PASS+NOTES` or `FAIL`. The verifier is the bug pass, or Opus when it tests visible UI in the local app before merge, and never whoever wrote the code; tests after deploy come too late. Once the PR exists, record it from the delegate's result with `sid-verdict.sh <pr> <tested-commit> <result> <verifier> <its childThreadId> "<what it ran and saw>"`. It refuses a commit whose patch isn't the PR's, and any later code change needs a new verdict, whitespace included.
   Run checks so a failure stops you before you commit or push.
5. **Ship.** Claude commits in the worktree and pushes with `--force-with-lease`.
   Run `sid-gate.sh <branch>` under `systemd-run --user` when available, so a T3
   restart doesn't kill it, and wait with a background check and
   `t3_background_wait`. Open the PR (`file-pr`) and `link_pull_request`.
   If it needs the PR bot, `watch_pull_request` and end the turn. If not, go straight to
   step 7: with no CI and no bot, nothing would wake you.
6. **Risky PRs only: ask the PR bot.** For auth, payments, data, migrations, `commerce/`,
   the gate, or a PR that skipped a review step, comment `@codex review`. `sid-merge.sh`
   works out most of these from the paths and forces it; add `--bot` for what it can't see. Findings:
   Claude triages per `<pstack>/skills/poteto-mode/references/bugbot-triage.md` (fix,
   dismiss with a reason, or ask); noise doesn't get code. Sol fixes once, Claude verifies,
   push, resolve the threads. On any PR, conflicts: merge the default branch in the
   worktree and gate again.
7. **Merge.** Run `sid-merge.sh --check <pr>` first. If it prints `proof-failures:` lines, read them and decide from the plan: back to the bug pass, review or coding, or go ahead and say why on the card. No fixed rule. `sid-merge.sh <pr>` refuses until the PR is really ready (`## Proof` must
   name the head commit, so a later push needs fresh proof), reruns the
   gate if the default branch moved, squash-merges using the PR body as the commit
   message, and removes the worktree and branch. Post the `Gate-Passed` line it prints on the card. Then `unwatch_pull_request`.
8. **Check it live** once deployed, then report: the PR link, the merge commit,
   your proof, what was checked on prod and what wasn't, and each decision you
   made for the user.

If you stop before the merge, call `unwatch_pull_request` first.

If the project is on the user's Kanzo board (http://localhost:4242, MCP `kanzo`),
keep its card current: Doing while it's being coded; Review for the Composer bug pass and
Astra; Deployment for the gate, a manual Codex cloud review, and waiting on deploy; Done
once it's merged and checked on prod, with a comment linking the PR. Also comment at every
step (worker started or finished, review findings, gate result, PR opened, bot result,
merge, prod check): what happened, what's next, and anything waiting on the user. The
user follows work from the board and may not read the chat. The card is the
record of what the work asks for; Kanzo is the source of truth, not a plan file.

**Don't wait on Deployment.** Review and local testing are finished by then, so the next card starts as soon as a card reaches Deployment. If it depends on that card's unmerged work, branch from that card's branch; once the parent squash-merges, `git rebase --onto origin/main <parent-head>` before its gate. Its Deployment queue merges in order, and prod checks catch up after each deploy.

Card labels are coloured provider, model and reasoning, plus time in the column, and the
`#` is the `pr-<n>` tag. Put neither in the title. Each time a worker starts, show it on the card with
`scripts/sid-card.py work <oe#n> <provider> <model> <effort> [status]`. While the PR
bot reviews, use `codex-bot chatgpt-codex-connector - deployment`. Doing and review cards
show those tags plus time in the column; a one-minute timer (`sid-card.timer`)
refreshes it, and moving a card elsewhere clears them.

## Proof

Proof is evidence you observed yourself in this session: command output, a
reproduction, a screenshot. Use the most direct proof the change allows:

- Reproduce the original failure, apply the fix, then watch the same
  reproduction pass.
- Run the checks that the repo's CI runs (typecheck, lint, tests).
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
- Each review finding is fixed or dismissed with a written reason. The `pr bot` in
  `models.md` reviews risky PRs, and `sid-merge.sh` requires its review of the head
  commit for those. Open bot threads block any merge.
- The deploy gate passed on the head merged onto the latest default branch.
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
