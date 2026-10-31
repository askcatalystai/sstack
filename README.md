# sidstack

Sid's agent stack: pstack's rigor with tstack's ship loop, set up for my models and my repos.

- **From pstack** ([cursor/plugins/pstack](https://github.com/cursor/plugins/tree/main/pstack), MIT, by Lauren Tan): the playbooks, the principles, and the tools (`how`, `why`, `architect`, `interrogate`, `arena`, `swarm`, `unslop`, `blast-radius`, `tdd`, `show-me-your-work`…). They stay installed from upstream and run here through `docs/adapter.md`, so upstream fixes keep flowing.
- **From tstack** ([t3dotgg/tstack](https://github.com/t3dotgg/tstack), MIT): `full-send`, `full-stop`, `council` (with the plan runner and board), `file-pr`, `babysit-pr`, `takeover`, `modernize`, `leaving-pr-comments`, forked and tailored here. `sol-loop` became `review-loop`.
- **New**: `sid-mode` (the entry point), `models.md` (one file for every role), `setup-sidstack`, `install.sh`.

## Use

- `sid mode <task>`: matches a playbook, runs it with my roles and gates.
- `full send` / `full stop`: one change to a merged / ready PR.
- `council` / `council plan`: four-seat review; a plan worked to merged PRs on a live board.
- `review loop` (Astra) / `sol loop` (Sol).
- `/setup-sidstack`: change a model, smoke-test it, relink.

## Roles

See `models.md`. Today: Claude Opus 5.5 orchestrates and does the final review; GPT-6.1 Sol (high) codes; GPT-6 Astra (low) reviews diffs; the Codex GitHub bot reviews every PR and merges wait for it; the council is Opus, Sol, DeepSeek V4.1 Flash and Muse Spark 1.3.

## Install

```bash
git clone <this repo> ~/.local/share/sidstack
git clone --filter=blob:none --sparse https://github.com/cursor/plugins ~/.local/share/pstack-src && git -C ~/.local/share/pstack-src sparse-checkout set pstack
~/.local/share/sidstack/install.sh
```

Update: `git -C ~/.local/share/sidstack pull && git -C ~/.local/share/pstack-src pull && ~/.local/share/sidstack/install.sh`.

Needs `gh`, `python3`, the Codex CLI, and for council/OpenCode seats the `opencode` CLI. Works best in T3 Code (`delegate_task`); falls back to Claude Code and Codex.

## Licenses

pstack and tstack are MIT; their licenses are in `LICENSE.pstack` and `LICENSE.tstack`.
