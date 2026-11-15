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

The user's decision on 2026-11-02: T3 recovery isn't worth testing ahead of time; fix these if they happen.

- A T3 restart with a gate under `systemd-run --user`. `full-send` runs gates that way so they survive one; the survival hasn't been tested.
- A cancel while a worker is pushing or opening a PR.
- A machine restart or power loss.

## Gate leases (process#542)

The runner holds the admission flock. During a gate, a detached lease holder
also holds that flock; neither the body nor its descendants inherit it, the
runner lock, or the queue lock. The holder records the owner and supervisor PID,
start ticks, boot ID, a random attempt ID and a CLOCK_BOOTTIME expiry in
`sid-gate/lease.json`, renewed every 100ms. The default lease is five seconds
(`SID_GATE_LEASE_SECONDS`, 0.5–60 seconds). Recovery requires both recorded
identities to be gone and the last renewal to have expired. Killing the holder
alone never authorizes a replacement: every admission reconciles its durable
lease while holding the flock. Unreadable attempt membership fails closed.

The supervisor pins the command leader until all group signals finish. Cleanup
uses a unique cgroup v2 directory whose intended path is recorded in the lease
before creating the directory or launching the body. Recovery also removes a
recorded empty directory left by a startup crash; a publication failure creates
no directory. The body attaches before exec; its descendants retain membership
across `setsid`, reparenting and dumpability changes. Cleanup sends TERM through pidfds,
then uses `cgroup.kill` after half a second to cover concurrent forks. Admission
resumes only after `cgroup.events` reports the entire subtree unpopulated. It
never reads unrelated process environments. OOM death follows the same path
as SIGKILL. Recovery can take the lease interval plus process scan/scheduling
time; unobservable or unkillable processes retain fail-closed admission.

Gate execution now requires Linux 5.14+ cgroup v2 with writable `cgroup.kill`
and a writable delegation (normally provided by the user systemd manager). The nearest writable ancestor of the
runner's cgroup hosts `sid-gate-<attempt>`; cleanup removes the directory after
it drains. Without delegation, startup fails before executing the gate body.
No controller limits or systemd units are changed.

Leases created before this change lack a cgroup. Their recovery retains the
original token scan and fails closed if a same-user environment is unreadable:
retroactive ancestry cannot identify an orphaned non-dumpable `setsid` process.
Drain those attempts before updating, or use pause → reboot → repair below if
an old attempt is already wedged. Never discard its lease to force admission.

Each `gate_tree` uses a fresh `verify-<uuid>` worktree and index. An abandoned
attempt's directory is never reused, so even an external service retaining its
old cwd cannot change a replacement's checked tree. Normal completion removes
its own worktree. Before creating a checkout, `attempts/<uuid>.json` records its
owner PID/start ticks/boot and exact path. Admission recovers the lease first,
then removes dead owners' tracked checkouts and Git registrations. Setup failures
remove their own checkout immediately. After reboot, old boot identities are
not live owners, so ordinary admission reclaims those attempts too. A daemon
which deliberately migrates out of its attempt cgroup (or, for legacy leases,
removes the token and creates a new session) can escape cleanup, but cannot
inherit admission locks or share the replacement's mutable index and checkout. This is process containment and
checkout fencing, not a sandbox against deliberately hostile same-user code.


### Installing while a train is running

`git pull` plus `install.sh` can replace the worker while a shell still has old
functions cached. The new worker first reconciles `lease.json` under the
inherited admission flock, before writing anything. It then requires the
`--lease-v2` positional handshake. Cached libraries without that handshake exit
143 without starting a body; their existing fail-closed path stops the caller
before checkout cleanup, batch splitting or acceptance. Restart that runner
with the installed scripts; its durable queue requests remain available.

Old libraries can prepare their legacy shared `verify` checkout before invoking
the worker. New libraries never use that path. Already-running pre-lease bodies
still retain their original inherited flock, so new admission cannot modify
that shared tree while they run. Cached old libraries can no longer start new
bodies once the new worker is installed. Do not bypass a legacy inherited lock
by deleting its lock file; stop the legacy workloads or use the reboot procedure
below if a pre-lease daemon retains it. A worker already loaded before the pull
finishes under its existing supervision; let it drain or stop/restart it.

For a planned upgrade, stop `sid-health.timer`, let the current runner drain,
then run `git pull --ff-only` and `./install.sh` from the installed sstack
checkout. `install.sh` enables the health timer again. If pulling mid-run,
expect cached callers to refuse and restart them from the installed scripts.
There is no need to delete queued requests or clear pass/fail records.

### Corrupt lease: pause, reboot, quarantine, restart

Do not remove `lease.json` or the flock file while workloads might still run.
Invalid JSON deliberately stops admission. The repair command requires a
reboot after pausing, so it never infers workload death from corrupt state.
Run these commands from the affected repository, using the installed script
path (substitute it if sstack is installed elsewhere):

```bash
S=$HOME/.local/share/sidstack
common=$(git rev-parse --path-format=absolute --git-common-dir)
unit=sid-train-$(printf '%s' "$common" | sha256sum | cut -c1-16)
"$S/scripts/sid-gate-recover.sh" --pause
systemctl --user stop sid-health.timer sid-health.service "$unit.service"
```

The pause marker blocks new-library admission and newly loaded workers,
including cached old callers. Stop any manually launched train/gate shells too;
do not launch more gates. Reboot the host (`systemctl reboot`) to prove that
all old local workloads, escaped sessions and lease holders are gone. Disable
any custom external service that would relaunch an old workload on boot before
rebooting. A changed boot ID is mandatory; same-boot repair refuses and leaves
both the marker and corrupt evidence intact.

After logging back in, return to the affected repository and run:

```bash
S=$HOME/.local/share/sidstack
"$S/scripts/sid-gate-recover.sh" --after-reboot
systemctl --user start sid-health.timer
"$S/scripts/sid-train.sh"
```

`--after-reboot` acquires the existing admission flock, verifies the pause boot
ID differs from this boot, renames the corrupt lease to `lease.corrupt-<uuid>`,
and removes abandoned tracked checkouts and Git registrations before resuming
admission. No queued requests are deleted. If checkout reclamation fails, the
pause marker stays in place: fix the reported filesystem/Git error and rerun
the command. The quarantined lease is retained for diagnosis.

Checkouts created by the first PR revision or a pre-lease library have no
ownership manifest. After reboot, while admission is still paused, inventory
`git worktree list --porcelain`; inspect only the affected repo's sibling
`<repo>-wt/verify` and `verify-<uuid>` entries, then remove each confirmed legacy
gate checkout explicitly under the unchanged admission lock:

```bash
common=$(git rev-parse --path-format=absolute --git-common-dir)
( exec 9>"$common/sid-gate/lock"; flock 9
  git worktree remove --force /absolute/path/to/confirmed/legacy/gate-checkout
)
```

Do this before `--after-reboot`; never wildcard-delete worktrees or replace the
lock inode. Current-version crashed checkouts are tracked and reclaimed
automatically; this manual inventory is only for older untracked layouts.


### Noticing unbounded fail-closed stops

There is no automatic alert for an unreadable `/proc` or an unobservable
workload. A lease timeout is not permission to ignore that uncertainty: the
holder/supervisor can keep admission stopped indefinitely. Notice this as
queued requests that do not gain a result, or a `gating` entry whose `started`
time in `<common>/sid-gate/train/state.json` and log modification time stop
advancing. Check the board and inspect the affected repo directly:

```bash
common=$(git rev-parse --path-format=absolute --git-common-dir)
unit=sid-train-$(printf '%s' "$common" | sha256sum | cut -c1-16)
cat "$common/sid-gate/train/state.json"
ls -lt "$common/sid-gate/train/queue" "$common/sid-gate/logs"
journalctl --user -u "$unit.service" -n 100 --no-pager
tail -n 100 "$common/sid-gate/train/runner.log"
flock -n "$common/sid-gate/lock" true
```

The last command returning 1 means admission is still held; it does not prove
that the holder is stale. Inspect the latest gate log for `/proc`/permission
errors and compare the lease's PID/start identities with the processes. A
supervisor stuck observing unknown state may produce no further log lines.
Restore `/proc` visibility if possible and allow recovery to finish. If it
cannot be restored, use pause → reboot → repair above, preserving the corrupt
or uncertain state for diagnosis. Do not delete a lock file or force concurrent
admission to make a stalled queue look healthy.
