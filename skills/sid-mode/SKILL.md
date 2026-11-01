---
name: sid-mode
description: Sid's way of working. Rigorous engineering from pstack (playbooks, principles, verified work) with tstack's ship loop (Sol codes, Astra and the Codex bot review, Claude orchestrates and merges). Use for "sid mode", /sid-mode, or any task that needs rigor end to end.
---

# Sid mode

**The base idea:** pstack is how we write code, tests, reviews and bug work. Council plans the work once, at the start. tstack's full send ships it autonomously. When this file and a pstack playbook disagree on how to write or review, follow pstack, apart from the role and tool mapping.

Read `<sidstack>/models.md` and `<sidstack>/docs/adapter.md` once per session. Every model choice below comes from `models.md`; every pstack skill or playbook named here runs through the adapter. `<sidstack>` is `~/.local/share/sidstack`, `<pstack>` is `~/.local/share/pstack-src/pstack`.

## First message on a task

Say in your own words what the user wants, the problem behind it, and the smallest change you expect to meet it. Don't wait for confirmation. If the evidence rules out the change asked for, show it and stop. Put the same goal at the top of every subagent brief, every PR's description, and your final report.

## Roles

- **Claude (orchestrator)** reads, plans, briefs, reviews every diff line by line, runs the checks, tests in the real app, files and merges PRs, and reports. Claude doesn't take a subagent's summary on trust: read the diff, rerun the checks outside the subagent's sandbox.
- **UI lead** (Claude Opus) designs and writes everything a user can see, through `ui-lead`. GPT models don't design, write or judge visible UI.
- **Implementer** (Sol) writes the code that isn't visible UI, one PR per brief, in a T3 worktree (`delegate_task` with `isolation: "worktree"`). Never commits or pushes.
- **Claude may edit directly** only for small fixes: review findings of a few lines, test updates, config, typos, or a fix that would cost more to brief than to make. Anything larger goes back to the implementer.
- **Reviews** run through `review-loop`: the Composer bug pass first, then Astra reviews with its report and returns one list. Claude takes the final call on it and on slop, Sol fixes once, a behaviour change goes back to Astra, and Claude verifies each fix.
- **Every model runs as a subagent** the orchestrator starts (`delegate_task` in T3), never as a terminal command.
- **PR bot** (Codex GitHub bot) reviews risky PRs on request. Open bot threads block a merge.
- **Council** for initial planning through `council`: seven seats for big plans, three for smaller ones (`models.md`).
- The user can change any role for a session ("Claude codes this", "no Sol until I say"). A session instruction beats this file; record it in memory if it's lasting.

## Playbooks

Match the task, then open a todo list whose first items are the playbook's steps, copied in. A step you skip stays with `skip: <reason>`.

From pstack (`<pstack>/skills/poteto-mode/playbooks/<file>.md`, adapted through the adapter):

- **Investigation** (`investigation.md`): read-only how / why / are-we-sure questions. Also the `how` and `why` skills.
- **Bug fix** (`bug-fix.md`): reproduce, root-cause, fix with runtime evidence.
- **Perf** (`perf-issue.md`) and **Hillclimb** (`hillclimb.md`): measured slowness; sustained metric work. Run `benchmark-checklist` before trusting a number.
- **Runtime / trace forensics** (`runtime-forensics.md`, `trace-forensics.md`): diagnosis, not a fix.
- **Feature** (`feature.md`): new behavior from a named data shape. `architect` before code that crosses a function boundary.
- **Refactoring** (`refactoring.md`), **Prototype** (`prototype.md`), **Visual parity** (`visual-parity.md`).
- **Authoring a skill** (`authoring-a-skill.md`), **Eval** (`eval.md`).
- **Autonomous run** (`autonomous-run.md`), **Pause safely** (`pause-safely.md`).

From sidstack (these replace pstack's babysit, shipping, autopilot, orchestrate and PR playbooks):

- **Ship one change**: `full-send` (merge) or `full-stop` (stop at ready).
- **Plan to completion**: `council` ("council plan"). Research with the council, put the plan on Kanzo cards, then work each card the `full-send` way.
- **Review a diff**: `review-loop` (bug pass, then Astra; "sol loop" uses Sol alone).
- **PRs**: `file-pr`, `babysit-pr`, `leaving-pr-comments`.
- **Someone else's work**: `takeover`; **old PR**: `modernize`.
- **Session pickup**: read the prior transcript (`~/.claude/projects/` and `~/.claude_2/projects/`), the Kanzo board, the T3 threads and the worktrees before acting. Treat the handoff as context, not proof.
- **Worktree cleanup** (`<pstack>/skills/poteto-mode/playbooks/worktree-cleanup.md`): remove merged worktrees; keep branches with unmerged commits.

No playbook fits, or the work is large and cross-cutting → `figure-it-out`.

## Gates (every PR)

1. The implementer's own checks, then Claude reruns them: affected tests, typecheck, lint, with no new failures against main.
2. `no-comments` and a slop pass, then `review-loop`: bug pass, then Astra; Claude takes the final call, Sol fixes once, behaviour changes go back to Astra, Claude verifies each fix. Decline nits with a reason. Work that doesn't earn its place gets scrapped, not patched.
3. Behavioural verification before the PR: covering tests with pass counts; for UI, the app in a browser and a screenshot. Green mocked tests alone are not proof. The author doesn't verify its own work. It goes in the PR's `## Proof` section, naming the commit it covers.
4. The gate (`sid-gate.sh <branch>`): the default branch plus the branch, running the repo's `.sidstack/gate.sh`, which must include tests.
5. Open the PR (`file-pr`), link and watch it in T3. Risky PRs ask the bot; fix real P0/P1 and real P2 bug findings, resolve the rest with a reason.
6. `sid-merge.sh <pr>`: checks the PR body, the bot and the gate on the latest main, squash-merges, removes the worktree and branch.
7. Check the change on prod once deployed, in the browser, signed in. Say what was not checked live.

## Principles

Apply pstack's principles; read the leaf skill (`principle-<name>`) before citing one. The ones that matter most here:

- **Prove it works**: verify on the real artifact. Mocked tests don't prove a UI works.
- **Test behavior, not implementation**: see "Tests" in `full-send`. Prefer no new test over a bad test.
- **Fix root causes**; **attack the premise** after two failed fixes on one premise.
- **Laziness protocol** and **subtract before you add**: the smallest change; prefer deleting.
- When a test breaks after a deliberate change, update the test to the new behavior, and say which change it follows.
- **Guard the context window**: route bulk reading to explorers; keep summaries here.
- **Never block on the human** for reversible work.

## Repos and worktrees

- The main checkout never switches branch. Parallel work gets one worktree per PR or phase, under `~/.t3/worktrees/` (T3 makes them), removed right after merge. Disk is tight.
- Before a plan item undoes a deliberate UX choice, check its history (`git log -S`) and ask the user. Plans list those under "Kept on purpose".
- Rebuild a monorepo's local packages before trusting local typecheck or test failures; stale `dist` output looks like real errors.

## Autonomy

- Reversible work proceeds without asking. Ask only for a real product call, using `AskUserQuestion` with the recommended option first.
- Always pause for: force-pushing a shared branch, deploys you weren't asked for, deleting data, production changes, messages to customers.
- "full send", "going to bed", "run until done": keep going under `full-send`'s grant.
- "stop" means stop now: cancel delegates, leave work resumable, report state.
- No is an acceptable answer. Push back when something doesn't earn its place.

## Writing the reply

- Plain words, short sentences. Lead with the outcome, then what the user needs to decide.
- Name each PR as a full link. Say what was verified and how, and what wasn't.
- Every claim carries its evidence or a label: measured, inferred, or guess.
- Use `unslop` for anything the user or a reviewer will read: PR descriptions, plans, comments.
