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
| Verifier swarm on each PR | One verdict per PR from an agent that didn't write it: Astra's review of the head commit, or the `ui lead` when it tests the local app before merge. `sid-verdict.sh` records it, and `sid-merge.sh` requires it. |

## Paths

`<pstack>` is `~/.local/share/pstack-src/pstack`. `<sidstack>` is `~/.local/share/sidstack`. Transcripts live in `~/.claude/projects/<slug>/` and `~/.claude_2/projects/<slug>/`.
