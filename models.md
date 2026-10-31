# sidstack models

Every sidstack skill reads its models from this file, and pstack skills run through sidstack map their roles here (see `docs/adapter.md`). Edit a line, or run `/setup-sidstack`, to change a role. Resolve exact IDs with `orchestrator_capabilities` before delegating; never substitute a model a role names without saying so.

Format: `role: provider / model / effort`. `provider` is the T3 `providerInstanceId`. `effort` is the T3 option (`reasoningEffort` on Codex, `effort` on Claude, `variant` on OpenCode).

## Core roles

- orchestrator: claudesahitya / claude-opus-5-5 / medium
- claude fallback: claudeAgent_claude_2 / claude-opus-5-5 / medium (only after a usage or rate limit on the orchestrator's instance; same model, never a different one)
- implementer: codex / gpt-6.1-sol / high
- hardest tasks: codex / gpt-6.1-sol / xhigh
- review panel: opencode / opencode-go/muse-spark-1.3-contributor / high (first; its findings go to Astra, not to Sol). DeepSeek was removed from reviews on 2026-10-31 (user).
- reviewer: codex / gpt-6-astra / medium (after the panel, with its findings; returns the one consolidated list; Claude takes the final call, Sol fixes once)
- pr bot: chatgpt-codex-connector (GitHub app; every PR; merge waits for its review of the head commit)
- judgment and prose: claudesahitya / claude-opus-5-5 / medium

## Panels (one subagent per entry)

- council: opencode / opencode-go/deepseek-v4.1-flash / high; opencode / opencode-go/muse-spark-1.3-contributor / high (DeepSeek and Muse only, user 2026-10-31; the orchestrator synthesises)
- interrogate reviewers: opencode / opencode-go/deepseek-v4.1-flash / low; opencode / opencode-go/muse-spark-1.3-contributor / high; codex / gpt-6.1-sol / high
- arena runners: claudesahitya / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high
- architect runners: claudesahitya / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high

## Workers

- swarm workers: opencode / opencode-go/deepseek-v4.1-flash / high; opencode / opencode-go/muse-spark-1.3-contributor / high (alternate)
- explorers (how explorer, why investigators, reflect tooling): opencode / opencode-go/deepseek-v4.1-flash / high
- explainers (how explainer, why synthesizer, reflect judgment): claudesahitya / claude-opus-5-5 / medium

## Notes

- DeepSeek V4.1 Flash has no `medium` variant; reviews run it at `low` for speed (it was slow at `high`), the council and explorers keep `high`. It timed out on a 75-file diff (2026-10-31): give panel members narrow briefs, at most ~20 files or one area each, split bigger diffs by area and run the pieces in parallel.
- Muse Spark 1.3 contributor trains on request data: don't send it secrets, credentials or customer data.
- Astra is the diff reviewer, not a council seat.
