#!/usr/bin/env python3
"""Gate lease recovery. Only the holder inherits flock; workloads inherit a token.

CLOCK_BOOTTIME includes suspend. Boot identity and /proc start ticks prevent PID
reuse after restart. Unknown process state is fail-closed, never evidence of death.
"""
import json
import os
import shutil
import subprocess
import uuid
from pathlib import Path
import signal
import sys
import time

BOOT = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
BOUND = float(os.environ.get('SID_GATE_LEASE_SECONDS', '5'))
if not 0.5 <= BOUND <= 60:
    raise ValueError('SID_GATE_LEASE_SECONDS must be between 0.5 and 60')


def now():
    return time.clock_gettime(time.CLOCK_BOOTTIME)


def identity(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_bytes().rsplit(b') ', 1)[1].split()
        return [pid, fields[19].decode(), BOOT] if fields[0] != b'Z' else None
    except FileNotFoundError:
        return None


def alive(who):
    return who is not None and identity(who[0]) == who


def write(path, record):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(record))
    os.replace(tmp, path)


def tagged(token, session=None, since=0):
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry/'stat').read_bytes().rsplit(b') ', 1)[1].split()
            if int(fields[19]) < since or fields[0] == b'Z':
                continue
            in_session = session is not None and int(fields[3]) == session
            if in_session or b'SID_GATE_ATTEMPT=' + token.encode() in (entry/'environ').read_bytes().split(b'\0'):
                who = identity(int(entry.name))
                if who:
                    found.append(who)
        except (FileNotFoundError, ProcessLookupError):
            pass
        except PermissionError:
            # Other users cannot descend from this gate. Same-user unreadable
            # entries must fail closed (e.g. a dumpability change).
            try:
                if entry.stat().st_uid == os.getuid():
                    raise
            except FileNotFoundError:
                pass
    return found


def send(who, sig):
    # pidfd pins the target across the identity check and signal; no PGID reuse.
    try:
        fd = os.pidfd_open(who[0])
    except ProcessLookupError:
        return
    try:
        if alive(who):
            signal.pidfd_send_signal(fd, sig)
    finally:
        os.close(fd)


def cleanup(token, session=None, since=0):
    end = now() + .5
    terminated = set()
    while True:
        members = tagged(token, session, since)
        if not members:
            return
        for who in members:
            key = tuple(who)
            if now() >= end:
                send(who, signal.SIGKILL)
            elif key not in terminated:
                send(who, signal.SIGTERM)
                terminated.add(key)
        time.sleep(.05)


def create_cgroup(attempt):
    # Use the nearest writable cgroup v2 delegation; no systemd client or
    # privileged daemon is needed. Publish membership before any workload runs.
    root = Path('/sys/fs/cgroup')
    relative = next(line[3:] for line in Path('/proc/self/cgroup').read_text().splitlines()
                    if line.startswith('0::'))
    current = root / relative.lstrip('/')
    for parent in (current, *current.parents):
        if parent == root.parent:
            break
        group = parent / ('sid-gate-' + attempt)
        try:
            group.mkdir()
        except PermissionError:
            continue
        return str(group)
    raise PermissionError('gate requires a writable cgroup v2 delegation')


def cleanup_record(record):
    if 'cgroup' not in record:
        # Leases written before cgroup containment have only the token as
        # evidence. Preserve their fail-closed behavior rather than guess.
        cleanup(record['attempt'], since=int(record['supervisor'][1]))
        return
    group = Path(record['cgroup']).resolve()
    if (not group.is_relative_to('/sys/fs/cgroup') or
            group.name != 'sid-gate-' + record['attempt']):
        raise ValueError('invalid attempt cgroup')
    end = now() + .5
    terminated = set()
    while group.exists():
        # Include nested cgroups should a workload create any. cgroup.kill
        # catches concurrent forks at escalation, independently of dumpability.
        if now() >= end:
            (group/'cgroup.kill').write_text('1')
        for procs in group.rglob('cgroup.procs'):
            try:
                pids = procs.read_text().split()
            except FileNotFoundError:
                continue
            for pid in pids:
                who = identity(int(pid))
                if who and tuple(who) not in terminated:
                    send(who, signal.SIGTERM)
                    terminated.add(tuple(who))
        if 'populated 0' in (group/'cgroup.events').read_text().splitlines():
            for child in sorted(group.rglob('*'), key=lambda p: len(p.parts), reverse=True):
                if child.is_dir():
                    child.rmdir()
            group.rmdir()
            return
        time.sleep(.05)


def checkout_record(manifest, repo):
    record = json.loads(manifest.read_text())
    expected = Path(str(repo) + '-wt') / ('verify-' + manifest.stem)
    if len(manifest.stem) != 32 or any(c not in '0123456789abcdef' for c in manifest.stem):
        raise ValueError('invalid checkout manifest name')
    if record['checkout'] != str(expected):
        raise ValueError('checkout manifest path mismatch')
    return record, expected


def remove_checkout(manifest, repo):
    record, checkout = checkout_record(manifest, repo)
    registered = subprocess.check_output(['git', '-C', str(repo), 'worktree', 'list', '--porcelain', '-z'])
    if b'worktree ' + os.fsencode(checkout) in registered.split(b'\0'):
        subprocess.run(['git', '-C', str(repo), 'worktree', 'remove', '--force', str(checkout)], check=True)
    elif checkout.exists():
        shutil.rmtree(checkout)
    manifest.unlink()


def reclaim(gate, repo):
    # Call only under admission flock, after lease recovery. A live owner can
    # still be setting up a checkout before it has launched any supervisor.
    for manifest in sorted((gate/'attempts').glob('*.json')):
        record, _ = checkout_record(manifest, repo)
        if not alive(record['owner']):
            remove_checkout(manifest, repo)


def prepare(gate, repo, owner, main):
    recover(gate/'lease.json')
    reclaim(gate, repo)
    attempt = uuid.uuid4().hex
    checkout = Path(str(repo) + '-wt') / ('verify-' + attempt)
    manifest = gate/'attempts'/f'{attempt}.json'
    manifest.parent.mkdir(exist_ok=True)
    write(manifest, dict(owner=identity(owner), checkout=str(checkout)))
    try:
        subprocess.run(['git', '-C', str(repo), 'worktree', 'add', '-q', '--detach', str(checkout), main], check=True)
    except BaseException:
        remove_checkout(manifest, repo)
        raise
    return checkout


def repair(gate, repo):
    paused = json.loads((gate/'admission-paused').read_text())
    if paused['boot'] == BOOT:
        raise ValueError('repair requires a reboot after pausing admission')
    # Reboot proves local workloads are gone without trusting a corrupt lease.
    lease = gate/'lease.json'
    if lease.exists():
        lease.rename(gate/('lease.corrupt-' + uuid.uuid4().hex))
    reclaim(gate, repo)
    (gate/'admission-paused').unlink()


def recover(path):
    if not path.exists():
        return
    record = json.loads(path.read_text())
    while record['boot'] == BOOT:
        # Never reclaim a live owner or supervisor, even after expiry.
        if not alive(record['owner']) and not alive(record['supervisor']):
            cleanup_record(record)
            while now() < record['expires']:
                time.sleep(.05)
            break
        time.sleep(.05)
    path.unlink()


def hold(path, record, ready):
    # This sibling of the body is outside the runner group and never launches
    # workloads. Only it holds the inherited flock after supervisor startup.
    record['holder'] = identity(os.getpid())
    write(path, record)
    os.write(ready, b'1')
    os.close(ready)
    while alive(record['supervisor']):
        record['expires'] = now() + BOUND
        write(path, record)
        time.sleep(.1)
    # Do not expire a live caller's lock. It still owns fd 9; crashed callers
    # are reclaimed only once the last renewal expires.
    while alive(record['owner']):
        time.sleep(.05)
    cleanup_record(record)
    while now() < record['expires']:
        time.sleep(.05)
    path.unlink()


if __name__ == '__main__':
    action, path = sys.argv[1], Path(sys.argv[2])
    if action == 'recover':
        recover(path)
        if len(sys.argv) > 3:
            reclaim(path.parent, Path(sys.argv[3]))
    elif action == 'prepare':
        print(prepare(path, Path(sys.argv[3]), int(sys.argv[4]), sys.argv[5]))
    elif action == 'remove':
        remove_checkout(path, Path(sys.argv[3]))
    elif action == 'pause':
        # Exclusive creation preserves the original boot across repeat pauses.
        with (path/'admission-paused').open('x') as f:
            json.dump(dict(boot=BOOT), f)
    elif action == 'repair':
        repair(path, Path(sys.argv[3]))
    elif action == 'exec':
        # Failure to attach exits before exec, so an uncontained body cannot run.
        (path/'cgroup.procs').write_text(str(os.getpid()))
        os.execvpe(sys.argv[3], sys.argv[3:], os.environ)
    elif action == 'hold':
        hold(path, json.loads(sys.argv[3]), int(sys.argv[4]))
    else:
        sys.exit('unknown lease action')
