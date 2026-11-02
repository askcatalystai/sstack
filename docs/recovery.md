# Recovery

What happens when work stops midway, from real runs.

## Cancelling a worker during a gate (drilled 2026-11-02)

A `delegate_task` worker (Codex, in a T3 worktree) ran `sid-gate.sh` in the foreground against a throwaway repo whose gate slept for 15 minutes. `task_cancel` then stopped the worker.

| After the cancel | Result |
| --- | --- |
| Task status | `interrupted`, with the worker's last message as its summary |
| Gate and its child process | Both gone within 20 seconds |
| Gate lock | Free, so the next gate isn't blocked |
| Pass stamp | None, so a merge can't use it |
| Next gate on that branch, with a file left in `verify` | Passed, and removed the file |
| The worker's T3 worktree and `t3/...` branch | Still there, clean: remove them yourself (`sid-scrap.sh`, or `git worktree remove` and `git branch -D`) |

## Not drilled

- A T3 restart with a gate under `systemd-run --user`. `full-send` runs gates that way so they survive one; the survival hasn't been tested.
- A cancel while a worker is pushing or opening a PR.
- A machine restart or power loss.
