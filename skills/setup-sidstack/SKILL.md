---
name: setup-sidstack
description: Change which model sidstack uses for each role (orchestrator, implementer, reviewer, council seats, workers), check the models are live, and reinstall the links. Use for /setup-sidstack, "change my models", "set the reviewer to X", or after adding a provider.
---

# Setup sidstack

`<sidstack>` is `~/.local/share/sidstack`. All roles live in `<sidstack>/models.md`.

## Steps

1. **Read** `<sidstack>/models.md`. Show the current roles as a short table.
2. **Detect.** In T3 Code, call `orchestrator_capabilities` (once, plus a `search` per family the user mentions). List the providers that can run child tasks and their models with effort options. Outside T3, list what `codex` and `opencode models` report, and the Claude models the `Agent` tool offers.
3. **Ask** what to change with `AskUserQuestion`: the role, then the model and effort, with the current choice first. Change only what the user asks for. A panel role (council, interrogate, arena, architect) is a list, one subagent per entry.
4. **Validate.** Every provider and model written must be in the detected set, with an effort the model offers. If not, say which and ask again.
5. **Smoke test** each new or changed model: one `delegate_task` per model (`mode: "async"`, `role: "test"`) asking it to run `git log --oneline -1`, read one file, and state its model name. A failure (funds, privacy setting, disabled provider) is reported with its exact error; don't write that model until it passes.
6. **Write** `<sidstack>/models.md` in place, keeping its format and notes. Add a note for any quirk the test found.
7. **Reinstall** with `<sidstack>/install.sh` so links and `~/.claude/rules/sidstack-models.md` are current.
8. **Commit and push** `<sidstack>` (`git -C <sidstack> commit -am "models: <change>" && git -C <sidstack> push`).
9. **Report** the new table and which models were smoke-tested. New roles apply to new sessions and to the next delegate in this one.
