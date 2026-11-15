#!/usr/bin/env python3
"""Supervise a gate body; a detached sibling holds its renewable lease."""
import json, os, signal, subprocess, sys, time, traceback, uuid
from gate_lease import BOOT, BOUND, now, identity, cleanup_record, create_cgroup, recover, reclaim
from pathlib import Path

def unconfirmed(kind, value, tb):
    # An unexpected supervisor error is not a confirmed test failure. Stop the
    # caller before it cleans the tree, splits a batch, or accepts any result.
    traceback.print_exception(kind, value, tb)
    os._exit(143)

sys.excepthook = unconfirmed
owner = int(sys.argv[1])
try:
    birth = Path(f"/proc/{owner}/stat").read_bytes().rsplit(b") ", 1)[1].split()[19]
except FileNotFoundError:
    sys.exit(143)
stopped = False

def stop(*_):
    global stopped
    stopped = True

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
def alive():
    try:
        fields = Path(f"/proc/{owner}/stat").read_bytes().rsplit(b") ", 1)[1].split()
        return fields[0] != b"Z" and fields[19] == birth
    except FileNotFoundError:
        return False
    except (OSError, ValueError, IndexError):
        return True

if not alive():
    sys.exit(143)
# Require the caller to identify its gate lock. Never hand queue/runner locks
# to a body whose descendants can escape supervision with setsid.
gate_lock = int(os.environ["SID_GATE_LOCK_FD"])
common = Path(subprocess.check_output(
    ['git', 'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip())
expected_lock = common/'sid-gate'/'lock'
actual, expected = os.fstat(gate_lock), expected_lock.stat()
if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
    print('inherited gate fd does not identify this repository admission lock', file=sys.stderr)
    sys.exit(143)
lease = expected_lock.with_name('lease.json')
# Admission belongs here as well as in the shell: a cached old library may
# acquire flock directly while loading this newly installed worker.
if (lease.parent/'admission-paused').exists():
    sys.exit(143)
recover(lease)
if sys.argv[2:3] != ['--lease-v2']:
    print('obsolete gate caller; restart the runner with the installed library', file=sys.stderr)
    sys.exit(143)
# Protocol rejection exits >=128 so old shells stop before tree cleanup or acceptance.
reclaim(lease.parent, common.parent)
attempt = uuid.uuid4().hex
record = dict(owner=identity(owner), supervisor=identity(os.getpid()), boot=BOOT,
              attempt=attempt, expires=now() + BOUND)
create_cgroup(lease, record)
ready, notify = os.pipe()
holder = subprocess.Popen([sys.executable, str(Path(__file__).with_name("gate_lease.py")),
                           "hold", str(lease), json.dumps(record), str(notify)],
                          start_new_session=True, pass_fds=(gate_lock, notify))
os.close(notify)
if os.read(ready, 1) != b"1":
    sys.exit(143)
os.close(ready)
os.close(gate_lock)
body_env = {**os.environ, "SID_GATE_ATTEMPT": attempt}
body_env.pop('SID_GATE_LOCK_FD', None)
child = subprocess.Popen([sys.executable, str(Path(__file__).with_name('gate_lease.py')),
                          'exec', record['cgroup'], *sys.argv[3:]],
                         start_new_session=True, env=body_env)
exit_seen = None

def exited():
    global exit_seen
    # WNOWAIT pins the leader PID/PGID until every group signal has been sent.
    result = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if result is not None and exit_seen is None:
        exit_seen = time.clock_gettime(time.CLOCK_BOOTTIME) * os.sysconf("SC_CLK_TCK")
    return result is not None

while not exited() and not stopped and alive() and holder.poll() is None:
    time.sleep(.2)
# Clean descendants even when the command leader already exited. Do not reap it.
try:
    os.killpg(child.pid, signal.SIGTERM)
except ProcessLookupError:
    pass

def group_alive():
    exited()
    unknown = False
    try:
        with os.scandir("/proc") as entries:
            for entry in entries:
                if not entry.name.isdigit():
                    continue
                try:
                    fields = Path(entry.path, "stat").read_bytes().rsplit(b") ", 1)[1].split()
                    if (fields[0] != b"Z" and int(fields[2]) == child.pid and
                            (exit_seen is None or int(fields[19]) <= exit_seen)):
                        return True
                except (OSError, ValueError, IndexError):
                    unknown = True
    except OSError:
        return True
    return unknown

# Allow TERM handlers to finish, including detached-batch cleanup after shell exit.
deadline = time.monotonic() + 3
while group_alive() and time.monotonic() < deadline:
    time.sleep(.05)
try:
    os.killpg(child.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
# Unknown /proc state must never release our locks. Keep the leader unreaped too.
while group_alive():
    time.sleep(.05)
cleanup_record(record)
child.wait()
if holder.poll() is not None or stopped or not alive():
    sys.exit(143)
# Cleanup was observed by the supervisor. The owner still holds its flock, so
# retiring the sibling here cannot authorize another runner mid-acceptance.
holder.terminate()
holder.wait()
lease.unlink()
sys.exit(child.returncode)
