#!/usr/bin/env python3
"""Keep gate locks in both the supervisor and body until cleanup completes."""
import os, signal, subprocess, sys, time
from pathlib import Path

owner = int(sys.argv[1])
try:
    birth = Path(f"/proc/{owner}/stat").read_text().split(") ", 1)[1].split()[19]
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
        fields = Path(f"/proc/{owner}/stat").read_text().split(") ", 1)[1].split()
        return fields[0] != "Z" and fields[19] == birth
    except FileNotFoundError:
        return False
    except OSError:
        return True

if not alive():
    sys.exit(143)
# The body must retain the locks even if this supervisor is OOM/SIGKILLed.
locks = []
for fd in (7, 8, 9):
    try:
        os.fstat(fd)
        locks.append(fd)
    except OSError:
        pass
child = subprocess.Popen(sys.argv[2:], start_new_session=True, pass_fds=locks)
exit_seen = None

def exited():
    global exit_seen
    # WNOWAIT pins the leader PID/PGID until every group signal has been sent.
    result = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    if result is not None and exit_seen is None:
        exit_seen = time.clock_gettime(time.CLOCK_BOOTTIME) * os.sysconf("SC_CLK_TCK")
    return result is not None

while not exited() and not stopped and alive():
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
                    fields = Path(entry.path, "stat").read_text().split(") ", 1)[1].split()
                    if (fields[0] != "Z" and int(fields[2]) == child.pid and
                            (exit_seen is None or int(fields[19]) <= exit_seen)):
                        return True
                except OSError:
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
child.wait()
sys.exit(143 if stopped or not alive() else child.returncode)
