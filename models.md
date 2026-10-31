# sidstack models

Every sidstack skill reads its models from this file, and pstack skills run through sidstack map their roles here (see `docs/adapter.md`). Edit a line, or run `/setup-sidstack`, to change a role. Resolve exact IDs with `orchestrator_capabilities` before delegating; never substitute a model a role names without saying so.

Format: `role: provider / model / effort`. `provider` is the T3 `providerInstanceId`. `effort` is the T3 option (`reasoningEffort` on Codex, `effort` on Claude, `variant` on OpenCode).

## Core roles

- orchestrator: claudesahitya / claude-opus-5-5 / medium
- claude fallback: claudeAgent_claude_2 / claude-opus-5-5 / medium (only after a usage or rate limit on the orchestrator's instance; same model, never a different one)
- implementer: codex / gpt-6.1-sol / high
- hardest tasks: codex / gpt-6.1-sol / xhigh
- reviewer: codex / gpt-6-astra / low
- pr bot: chatgpt-codex-connector (GitHub app; every PR; merge waits for its review of the head commit)
- judgment and prose: claudesahitya / claude-opus-5-5 / medium

## Panels (one subagent per entry)

- council: claudesahitya / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high; opencode / opencode-go/deepseek-v4.1-flash / high; opencode / opencode-go/muse-spark-1.3-contributor / medium
- interrogate reviewers: claudesahitya / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high; opencode / opencode-go/deepseek-v4.1-flash / high
- arena runners: claudesahitya / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high
- architect runners: claudesahitya / claude-opus-5-5 / medium; codex / gpt-6.1-sol / high

## Workers

- swarm workers: opencode / opencode-go/deepseek-v4.1-flash / high
- explorers (how explorer, why investigators, reflect tooling): opencode / opencode-go/deepseek-v4.1-flash / high
- explainers (how explainer, why synthesizer, reflect judgment): claudesahitya / claude-opus-5-5 / medium

## Notes

- Muse Spark 1.3 contributor trains on request data (OpenCode workspace privacy setting). It sits only on the council.
- DeepSeek V4.1 Flash has no `medium` variant; `high` is its lowest useful setting here. It timed out on a 75-file diff (2026-10-31), so it is not the diff reviewer; give it narrow, read-only briefs.
- Astra is the diff reviewer, not a council seat.
