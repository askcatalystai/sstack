#!/usr/bin/env python3
"""Hold inherited gate locks until a cancelled worker's process group is gone."""
import os, signal, subprocess, sys, time
from pathlib import Path

owner = int(sys.argv[1])
# Keep inherited lock descriptors here; never pass them to the command.
try:
    birth = open(f"/proc/{owner}/stat").read().split(") ", 1)[1].split()[19]
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
        fields = open(f'/proc/{owner}/stat').read().split(') ', 1)[1].split()
        return fields[0] != 'Z' and fields[19] == birth
    except FileNotFoundError:
        return False

if not alive():
    sys.exit(143)
child = subprocess.Popen(sys.argv[2:], start_new_session=True, close_fds=True)
while child.poll() is None and not stopped and alive():
    try:
        child.wait(timeout=.2)
    except subprocess.TimeoutExpired:
        pass
# Clean descendants even when the command leader already exited.
try:
    os.killpg(child.pid, signal.SIGTERM)
except ProcessLookupError:
    pass
# The shell can exit before its children finish their TERM handlers (including
# the test runner's cleanup of detached batches). Give the whole group grace.
def group_alive():
    for entry in Path("/proc").glob("[0-9]*/stat"):
        try:
            fields = entry.read_text().split(") ", 1)[1].split()
            if fields[0] != "Z" and int(fields[2]) == child.pid:
                return True
        except (FileNotFoundError, ProcessLookupError):
            pass
    return False

deadline = time.monotonic() + 3
while group_alive() and time.monotonic() < deadline:
    time.sleep(.05)
try:
    os.killpg(child.pid, signal.SIGKILL)
except ProcessLookupError:
    pass
child.wait()
sys.exit(143 if stopped or not alive() else child.returncode)
