# Running pstack and tstack skills under sidstack

sidstack runs in T3 Code first, then plain Claude Code, then Codex. pstack (`~/.local/share/pstack-src/pstack`, installed globally) is written for Cursor. Read this once per session before following a pstack skill, and map each Cursor name below. If a field has no row, drop it and say so in one line. Every subagent brief starts with "Read `~/.local/share/sidstack/rules.md` first.", and its title names the Kanzo card key.

## Subagents

| pstack / Cursor | T3 Code | Claude Code (no T3) |
| --- | --- | --- |
| `Task` with a model slug | `delegate_task` with `target: { providerInstanceId, model, options }` from the role in `models.md` | `Agent`. A Claude role: `model: "opus"` + `effort`. A non-Claude role: route through Codex (`codex exec -m <model>`) or say it ran on the session model. |
| `run_in_background: true` | `mode: "async"`; completion wakes you. Never poll. | Default. |
| `readonly: true` | Say "review only, do not edit" in the brief; check `git status` after. | `subagent_type: "Explore"`. |
| `environment: "cloud"` | `isolation: "worktree"` | `isolation: "worktree"` |
| `poteto-agent` delegate | `delegate_task` on the implementer role, brief starts "Read `<pstack>/skills/poteto-mode/SKILL.md` in full first." | `pstack:poteto-agent` or the `poteto-agent` agent if installed. |
| `resume` | A fresh `delegate_task` with the consolidated brief. | A fresh agent with the earlier result pasted in. |
| `AskQuestion` | `AskUserQuestion` | `AskUserQuestion` |
| Run skill `/name` | `Skill` if listed, else read `<pstack>/skills/<name>/SKILL.md` and follow it. | Same. |

## Which machine

Sol builders run on the Mac; everything else runs here (`models.md`, "Machines"). T3's load balancing setting only picks a machine for a new thread the operator starts from the composer; a `delegate_task` runs here unless it names the other machine, so the orchestrator places every builder itself, whichever thread it is:

1. Once per session, call `t3_environment_links` and `t3_project_list` with the Mac's `environmentId` to get its project for the same repository, and `orchestrator_capabilities` with that `environmentId`. If the Mac isn't reachable or has no such project, run builders here and say so in one line.
2. Every Sol builder (writing logic, and its fix pass) runs on the Mac. T3 refuses `delegate_task` with `isolation: "worktree"` on a linked machine, so start it with `t3_thread_launch`: `environmentId`, the Mac's `projectId`, `modelSelection` from the implementer role, `runtimeMode: "full-access"`, `workspaceStrategy: { type: "worktree", baseRef: "origin/main", startFromOrigin: true }`, the card key in `title`, the brief as `message`. A fix pass launches another thread with `workspaceStrategy: { type: "existing_worktree", worktreePath }`. The UI builder, the bug pass, reviewers, panels, explorers and screenshots stay here as `delegate_task`.
3. A launched thread doesn't wake you. Call `t3_thread_wait` on it (again while it reports `timedOut`) before you end the turn, then `t3_thread_read` its last message. The Mac has 10 cores and 24 GB: keep at most seven agents there at once, counting every lane (operator 2026-11-16) and start the next ones here. The board doesn't see threads on the Mac, so comment on the card when the builder starts and when it reports.
4. The brief's first commands are the repo's setup, then `git fetch origin && git merge-base --is-ancestor origin/main HEAD`; if that fails the builder runs `git merge --ff-only origin/main` before touching a file, so its branch starts from what is pushed.
5. You can't read a worktree on the other machine. A builder on the Mac commits its work on its `t3/...` branch and pushes it, and reports the branch, the commit and its worktree path. Here, `git fetch origin <branch>` and `git worktree add` give you the diff to read and give the bug pass and Astra a path to review. A fix goes to a new builder on the Mac in that worktree. After the merge, remove the Mac worktree with a short `delegate_task` to the Mac (`git worktree remove`), since the merge train only cleans up here.
6. Only tracked files reach the Mac. Paste into the brief anything the builder needs from an untracked file here (plans under `docs/`, design notes), and never name a `/home/...` path in a brief sent there.
7. A test pass on the Mac is the builder's `## Proof`; the merge train's gate, here on Linux, is still the check that decides.

## pstack roles → sidstack roles

| pstack role (`pstack-models`) | sidstack role |
| --- | --- |
| `feature, refactoring`, `bug-fix`, `perf-issue`, `hillclimb` | implementer |
| `hardest tasks` | hardest tasks |
| `judgment and prose` | judgment and prose |
| `how explorer`, `why investigators`, `reflect tooling` | explorers |
| `how explainer`, `why synthesizer`, `reflect judgment, divergent, synthesizer` | explainers |
| `arena runners`, `arena cross-judge pool` | arena runners |
| `architect runners` | architect runners |
| `interrogate reviewers` | interrogate reviewers |
| `swarm workers` | swarm workers |

Verification swarms stay on `swarm workers`. Keep a panel's families distinct, so a diverse panel stays diverse.

## Cursor-only features

| pstack step | Here |
| --- | --- |
| Bugbot (start, wait, triage) | No bot. Risky PRs get one more model from the `risky review` line in `models.md` (`full-send` step 6); triage its findings the same way. |
| `deslop` before commit, `no-comments` before review | `no-comments` works as written, with the `comment-sicko` agent. Prose: the `unslop` skill. Code: Claude Code's built-in `simplify`, then Claude's own read of the diff for dead code, needless guards and comments that restate code. |
| `control-ui` (drive a browser or Electron UI) | In T3: `preview_open`, `preview_act`, `preview_snapshot` (screenshot with `save=true` for proof). Outside T3: the `browse` skill. The project's `verify-*` skill first if it has one. |
| `control-cli` (drive a CLI or TUI) | Run the command directly and keep its output as proof. |
| `swarm` workers | Parallel `delegate_task` calls on the `swarm workers` role in `models.md`, one per partition, then one merged report. |
| Task model slugs, `pstack-models.mdc` | `models.md` roles. `install.sh` writes `~/.claude/rules/pstack-models.md` from it, so pstack skills read your roles directly. Don't edit that file by hand. |
| Cursor Automations, cloud-agent dashboards | Skip with one line: `Skipped here: <step>. <reason>.` |

## Playbook steps that change here

| pstack step | Here |
| --- | --- |
| `architect` running `arena` as a matter of course (Feature step 2) | A single design sketch. Use `arena` only for a contested design or when the user asks; it's too heavy for this machine on small PRs. |
| Bug fix step 5, committing the failing repro first | Sol doesn't commit. Put the failing-then-passing output in `## Proof`. Claude may commit the test first when it's cheap to split. |
| Verifier swarm on each PR | One verdict per PR from an agent that didn't write it: Astra's review of the head commit, or the `ui lead` when it tests the local app before merge. It goes in the PR's `## Review` section, which `sid-merge.sh` requires. `## Review` must include `Approved-Head: <sha> (<who>)` (12+ hex characters, e.g. `Approved-Head: d381a62361f3 (Astra)`) as the last non-empty line of `## Review`, after the free-text review notes, naming the exact head commit and approvers. |

## Paths

`<pstack>` is `~/.local/share/pstack-src/pstack`. `<sidstack>` is `~/.local/share/sidstack`. Transcripts live in `~/.claude/projects/<slug>/` and `~/.claude_2/projects/<slug>/`.
