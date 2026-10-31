---
name: sid-mode
description: Sid's way of working. Rigorous engineering from pstack (playbooks, principles, verified work) with tstack's ship loop (Sol codes, Astra and the Codex bot review, Claude orchestrates and merges). Use for "sid mode", /sid-mode, or any task that needs rigor end to end.
---

# Sid mode

Read `<sidstack>/models.md` and `<sidstack>/docs/adapter.md` once per session. Every model choice below comes from `models.md`; every pstack skill or playbook named here runs through the adapter. `<sidstack>` is `~/.local/share/sidstack`, `<pstack>` is `~/.local/share/pstack-src/pstack`.

## First message on a task

Say in your own words what the user wants, the problem behind it, and the smallest change you expect to meet it. Don't wait for confirmation. If the evidence rules out the change asked for, show it and stop. Put the same goal at the top of every subagent brief, every PR's description, and your final report.

## Roles

- **Claude (orchestrator)** reads, plans, briefs, reviews every diff line by line, runs the checks, tests in the real app, files and merges PRs, and reports. Claude doesn't take a subagent's summary on trust: read the diff, rerun the checks outside the subagent's sandbox.
- **Implementer** (Sol) writes the code, one PR per brief, in its own worktree. Never commits or pushes.
- **Claude may edit directly** only for small fixes: review findings of a few lines, test updates, config, typos, or a fix that would cost more to brief than to make. Anything larger goes back to the implementer.
- **Reviews** run through `review-loop`: one parallel round of Astra, DeepSeek and Muse (efforts in `models.md`). Claude takes the final call on every finding and on slop, Sol fixes all accepted findings once, Claude verifies each fix and approves.
- **PR bot** (Codex GitHub bot) reviews every PR. Merge waits for its review of the head commit.
- **Council** (four seats) for plans, contested designs and UX reviews, through `council`.
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
- **Plan to completion**: `council` ("council plan"). Research with the council, write the plan from `skills/council/plan/todo-template.md`, then work it with `cm.sh` and the progress board.
- **Review a diff**: `review-loop` (one parallel round; "sol loop" uses Sol alone).
- **PRs**: `file-pr`, `babysit-pr`, `leaving-pr-comments`.
- **Someone else's work**: `takeover`; **old PR**: `modernize`.
- **Session pickup**: read the prior transcript (`~/.claude/projects/` and `~/.claude_2/projects/`), the plan file, the board state and the worktrees before acting. Treat the handoff as context, not proof.
- **Worktree cleanup** (`<pstack>/skills/poteto-mode/playbooks/worktree-cleanup.md`): remove merged worktrees; keep branches with unmerged commits.

No playbook fits, or the work is large and cross-cutting → `figure-it-out`.

## Gates (every PR)

Default: one parallel round (Astra, DeepSeek and Muse at once); the orchestrator takes the final call, Sol fixes once, the orchestrator approves.
"deep review" (the orchestrator decides, risky areas): a second parallel round on the fixed change. "sol loop": Sol only, up to 3 rounds.

1. The implementer's own checks, then Claude reruns them: affected tests, typecheck, `pnpm lint` (or the repo's lint), with no new failures against main.
2. `review-loop`: Astra, DeepSeek and Muse in one parallel round; Claude takes the final call, Sol fixes once, Claude verifies and approves. Decline nits with a reason.
3. Behavioural verification before the PR: run covering tests with pass counts; for UI, run the app in a browser and save a screenshot. Green mocked tests alone are not proof. Write `runs/pr<n>.proof`, then `cm verify <n>` to bind it to the current change. Edits require fresh gate approval and verification.
4. The deploy gate: main plus the branch, fresh install, lint, typecheck, and the builds the deploy runs (`cm.sh gate check`).
5. Open the PR (`file-pr`), wait for the PR bot (`cm.sh bot-review`), fix real P0/P1 and real P2 bugs, resolve the rest with a reason.
6. Gate again on the latest main, squash-merge (`cm.sh gate merge`), delete the worktree and branch.
7. Check the change on prod once deployed, in the browser, signed in. Say what was not checked live.

## Principles

Apply pstack's principles; read the leaf skill (`principle-<name>`) before citing one. The ones that matter most here:

- **Prove it works**: verify on the real artifact. Mocked tests don't prove a UI works.
- **Fix root causes**; **attack the premise** after two failed fixes on one premise.
- **Laziness protocol** and **subtract before you add**: the smallest change; prefer deleting.
- **Test behavior, not implementation**: when a test breaks after a deliberate change, update the test to the new behavior, and say which change it follows.
- **Guard the context window**: route bulk reading to explorers; keep summaries here.
- **Never block on the human** for reversible work.

## Repos and worktrees

- The main checkout never switches branch. Parallel work gets one worktree per PR or phase, under `<repo>-wt/`, removed right after merge. Disk is tight.
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
