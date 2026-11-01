# sidstack

Sid's agent stack: pstack's rigor with tstack's ship loop, set up for my models and my repos.

- **From pstack** ([cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack), MIT, by Lauren Tan): the playbooks, the principles, and the tools (`how`, `why`, `architect`, `interrogate`, `arena`, `swarm`, `unslop`, `blast-radius`, `tdd`, `show-me-your-work`…). They stay installed from upstream and run here through `docs/adapter.md`, so upstream fixes keep flowing.
- **From tstack** ([t3dotgg/tstack](https://github.com/t3dotgg/tstack), MIT): `full-send`, `full-stop`, `council`, `file-pr`, `babysit-pr`, `takeover`, `modernize`, `leaving-pr-comments`, forked and tailored here. `sol-loop` became `review-loop`.
- **New**: `sid-mode` (the entry point), `models.md` (one file for every role), `setup-sidstack`, `install.sh`.

## The idea

sstack is three things on T3 Code:

- **Claude Opus leads UI and UX:** the `ui-lead` skill adapts pstack's experience-first, prototype and visual-parity, with our taste rules.
- **pstack is how we write:** code, tests, reviews and bug work follow its playbooks and principles as closely as this setup allows.
- **Council is how we plan:** several models plan the work once, at the start, onto Kanzo cards, which are the source of truth.
- **tstack's full send is how we ship:** fast and autonomous, from brief to merged PR.

## Use

- `sid mode <task>`: matches a playbook, runs it with my roles and gates.
- `full send` / `full stop`: one change to a merged / ready PR.
- `council` / `council plan`: seven seats for big plans, three for smaller ones; the plan goes on Kanzo cards, worked to merged PRs through T3.
- `review loop` (Astra) / `sol loop` (Sol).
- `/setup-sidstack`: change a model, smoke-test it, relink.

## Roles

See `models.md` (the only place models and efforts are set). Claude Opus orchestrates, triages every review finding and takes the final call; GPT-6.1 Sol writes the code; Composer runs a bug pass and Astra reviews, returning one list; every model runs as a subagent; the Codex GitHub bot reviews risky PRs; the council is Claude, Sol, Astra, Terra, Composer, Muse and DeepSeek, and the orchestrator synthesises.

## Install

```bash
git clone <this repo> ~/.local/share/sidstack
git clone --filter=blob:none --sparse https://github.com/cursor/plugins ~/.local/share/pstack-src && git -C ~/.local/share/pstack-src sparse-checkout set pstack
~/.local/share/sidstack/install.sh
```

Update: `git -C ~/.local/share/sidstack pull && git -C ~/.local/share/pstack-src pull && ~/.local/share/sidstack/install.sh`.

Needs `gh`, `python3`, the Codex CLI, and for council/OpenCode seats the `opencode` CLI. Works best in T3 Code (`delegate_task`); falls back to Claude Code and Codex.

## Checks and upstream

Run `scripts/check.sh` for shell and Python syntax checks. See `UPSTREAM.md` for copied skill origins
and `scripts/upstream-check.sh` for upstream change reports.

## Licenses

pstack and tstack are MIT; their licenses are in `LICENSE.pstack` and `LICENSE.tstack`.
