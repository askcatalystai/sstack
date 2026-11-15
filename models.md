# sidstack models

Every sidstack skill reads its models from this file, and pstack skills run through sidstack map their roles here (see `docs/adapter.md`). Edit a line, or run `/setup-sidstack`, to change a role. Resolve exact IDs with `orchestrator_capabilities` before delegating; never substitute a model a role names without saying so.

Format: `role: provider / model / effort`. `provider` is the T3 `providerInstanceId`. `effort` is the T3 option (`reasoningEffort` on Codex, `effort` on Claude, `variant` on OpenCode).

## Core roles

- orchestrator: claudeAgent / claude-opus-5-5 / medium
- claude fallback: claudeAgent_claude_2 / claude-opus-5-5 / medium (only after a usage or rate limit on the orchestrator's instance; same model, never a different one; not set up in T3 as of 2026-11-13: `orchestrator_capabilities` lists `claudeAgent` only)
- implementer: codex / gpt-6.1-sol / high (logic: server, runtime, data and tests; visible UI goes to the ui builder)
- ui builder: claudeAgent / claude-opus-5-5 / medium (writes everything a user can see, in its own worktree, to the `ui-lead` rules; user 2026-11-13: "yes opus for ui")
- hardest tasks: codex / gpt-6.1-sol / xhigh
- bug pass: cursor / composer-2.5 / fastMode=false (first, before any review; pstack poteto bug-fix playbook: reproduce, root-cause, minimal fix; user 2026-11-01)
- review panel: none (user 2026-11-01: Sol → bug pass → Astra directly; Muse stays on the council)
- reviewer: codex / gpt-6-astra / medium (after the bug pass, with its report; returns one list; its approval of the head commit is the merge verdict since 2026-11-13; Claude takes the final call, the builder fixes once; a fix that changes behaviour goes back to Astra, user 2026-11-01)
- ui lead: claudeAgent / claude-opus-5-5 / medium (the orchestrator: judges all visible UI before other review and does the final test; the ui builder writes it; user 2026-11-01; see the `ui-lead` skill)
- screenshots: codex / gpt-6.1-terra / medium (low stopped after two shots and posted nothing, 2026-11-01; before and after shots in T3's in-app browser, posted on the Kanzo card; user 2026-11-01)
- risky review: opencode / opencode-go/deepseek-v4.1-flash / low; cursor / composer-2.5 / fastMode=false (one extra review on risky PRs: auth, payments, data, migrations, `commerce/`, the merge scripts, or a PR that skipped a review step. Pick a family that hasn't reviewed the PR yet. A finding blocks the merge only when every model that reviewed the PR calls it risky; otherwise the orchestrator decides and writes why in `## Review`. Replaces the Codex GitHub bot: no `@codex review`; user 2026-11-13)
- judgment and prose: claudeAgent / claude-opus-5-5 / medium

## Panels (one subagent per entry)

- council: claudeAgent / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high; codex / gpt-6-astra / medium; codex / gpt-6.1-terra / high; cursor / composer-2.5 / fastMode=false; opencode / opencode-go/muse-spark-1.3-contributor / high; opencode / opencode-go/deepseek-v4.1-flash / high (seven seats, user 2026-11-01; every seat plans the whole brief, no per-seat categories; the orchestrator synthesises and leads UI and UX itself)
- council small: claudeAgent / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high; cursor / composer-2.5 / fastMode=false (smaller plans, user 2026-11-01)
- interrogate reviewers: opencode / opencode-go/deepseek-v4.1-flash / low; opencode / opencode-go/muse-spark-1.3-contributor / high; codex / gpt-6.1-sol / high
- arena runners: claudeAgent / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high
- architect runners: claudeAgent / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high

## Workers

- swarm workers: opencode / opencode-go/deepseek-v4.1-flash / high; opencode / opencode-go/muse-spark-1.3-contributor / high (alternate)
- explorers (how explorer, why investigators, reflect tooling): opencode / opencode-go/deepseek-v4.1-flash / high
- explainers (how explainer, why synthesizer, reflect judgment): claudeAgent / claude-opus-5-5 / medium

## Notes

- DeepSeek V4.1 Flash has no `medium` variant; reviews run it at `low` for speed (it was slow at `high`), the council and explorers keep `high`. It timed out on a 75-file diff (2026-10-31): give panel members narrow briefs, at most ~20 files or one area each, split bigger diffs by area and run the pieces in parallel.
- Muse Spark 1.3 contributor trains on request data: don't send it secrets, credentials or customer data.
- Astra is the diff reviewer and also a council seat (user 2026-11-01).
- Council briefs must require reading the installed Mastra docs where relevant, with citations: replies without them were thin (2026-11-01). Terra at `ultra` and Muse at `xhigh` both work when asked for maximum effort.
- Cursor on the Plus plan accepts Composer 2.5 only with fast mode off. T3's Cursor SDK path defaults to fast when no option is sent and fails with "Model unavailable on Plus … with fixed settings"; always pass `options: { fastMode: "false" }` (2026-11-01).
- DeepSeek was removed from PR reviews on 2026-10-31 (user); it stays on the council and explorers.

## Machines

Two machines are linked in T3 (`t3_environment_links` lists them with their `environmentId`). A role runs where its provider is signed in and where there is room; `docs/adapter.md` ("Which machine") has the rules.

- orx (Linux, 16 cores): the orchestrator, every Claude role, the merge train and its gate, Kanzo.
- sid's Mac mini (M4, 10 cores, 24 GB): Codex, Cursor and OpenCode roles (implementer, bug pass, reviewer, risky review, workers), with their builds and test runs. Claude isn't signed in there, so no Claude role runs on it (user 2026-11-15: "use that machine for codex work and test suites").
