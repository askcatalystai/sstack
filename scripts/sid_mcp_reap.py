#!/usr/bin/env python3
"""Reap finished helper MCP servers and old servers without a matching thread."""
import argparse
from dataclasses import dataclass
from datetime import datetime
import os
from pathlib import Path
import re
import shlex
import signal
import sqlite3
import time


@dataclass(frozen=True)
class Process:
    pid: int
    ppid: int
    pgid: int
    started: int  # Kernel start ticks distinguish reused PIDs.
    age: float
    rss: int
    argv: tuple
    state: str = 'S'
    cwd: str | None = None
    uid: int | None = None


def process_table():
    ticks = os.sysconf('SC_CLK_TCK')
    page = os.sysconf('SC_PAGE_SIZE')
    uptime = float(Path('/proc/uptime').read_text().split()[0])
    result = {}
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            # comm may contain spaces and parentheses.
            stat = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            argv = tuple(os.fsdecode(a) for a in (entry / 'cmdline').read_bytes().split(b'\0') if a)
            pid, start = int(entry.name), int(stat[19])
            try:
                cwd = str((entry / 'cwd').readlink())
            except OSError:
                cwd = None
            result[pid] = Process(pid, int(stat[1]), int(stat[2]), start,
                                  uptime - start / ticks, int(stat[21]) * page, argv, stat[0], cwd, entry.stat().st_uid)
        except (OSError, ValueError, IndexError):
            continue  # Exited or inaccessible while taking the snapshot.
    return result


def app_server(p):
    return len(p.argv) >= 2 and Path(p.argv[0]).name == 'codex' and p.argv[1] == 'app-server'


def mcp_server(p):
    if not p.argv or app_server(p):
        return False
    executable = Path(p.argv[0])
    if executable in (Path('/usr/lib/chatgpt/resources/cua_node/bin/node_repl'),
                      Path('/usr/lib/chatgpt/resources/cua_node/bin/cua_repl')):
        return True
    if executable.name == 'railway' and p.argv[1:] == ('mcp', 'proxy'):
        return True
    # npm rewrites /proc/cmdline to a single process title on this machine.
    rea = r'rea-agents@[^\s/]+'
    if (len(p.argv) == 1 and re.fullmatch(r'npm exec ' + rea + r' mcp', p.argv[0]) or
            executable.name == 'npm' and len(p.argv) == 4 and
            p.argv[1] == 'exec' and re.fullmatch(rea, p.argv[2]) and p.argv[3] == 'mcp'):
        return True
    # Only executable/script positions count, never arbitrary argv keywords.
    script = p.argv[1] if executable.name == 'node' and len(p.argv) >= 2 else p.argv[0]
    path = Path(script)
    if not path.is_absolute():
        if p.cwd is None:
            return False
        path = Path(p.cwd) / path
    try:
        path = path.resolve()
        roots = (Path.home() / '.codex', Path.home() / '.cache/codex-runtimes')
        installed = any(path.is_relative_to(root.resolve()) for root in roots)
    except (OSError, RuntimeError):
        return False
    return installed and (path.name == 'launch_codex_app_tools_mcp' or
                          path.name == 'launch.mjs' and 'mcp' in path.parts)


def user_systemd(p):
    return (p.uid == os.getuid() and p.argv in
            (('/usr/lib/systemd/systemd', '--user'), ('/lib/systemd/systemd', '--user')))


@dataclass(frozen=True)
class Thread:
    requested_at: float
    title: str
    running: bool
    subagent: bool
    operator: bool


def codex_threads(database, emit):
    try:
        with sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True, timeout=0.2) as db:
            rows = db.execute("""
                SELECT r.requested_at, t.title,
                       max(r.status IN ('queued', 'preparing', 'starting', 'running', 'waiting'))
                           OVER (PARTITION BY t.thread_id),
                       json_extract(t.payload_json, '$.lineage.parentThreadId') IS NOT NULL,
                       json_extract(t.payload_json, '$.createdBy') = 'user'
                FROM orchestration_v2_projection_threads t
                JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
                WHERE r.provider_instance_id = 'codex'
                ORDER BY t.thread_id
            """).fetchall()
        return [Thread(datetime.fromisoformat(requested.replace('Z', '+00:00')).timestamp(),
                       title, bool(running), bool(subagent), bool(operator))
                for requested, title, running, subagent, operator in rows]
    except (sqlite3.Error, OSError, ValueError, TypeError, AttributeError) as error:
        emit(f'Skipped: T3 database cannot be read: {error}')
        return None


def decision(p, threads, now):
    started = now - p.age
    matches = [t for t in threads if 0 <= started - t.requested_at <= 120]
    # Threads started within seconds of each other (parallel reviewers) make the match ambiguous,
    # so a running thread that could own the server keeps it until that thread finishes.
    if any(t.running for t in matches):
        return False, 'running thread'
    thread = max(matches, key=lambda t: t.requested_at) if matches else None
    if thread is not None:
        if thread.operator:
            return False, 'operator thread'
        kind = 'subagent' if thread.subagent else 'agent thread'
        return True, f'{kind} {thread.title} finished'
    if p.age > 7200:
        return True, f'no thread, {int(p.age // 3600)}h old'
    return False, 'no thread, too young'


def same(p, table):
    current = table.get(p.pid)
    return current is not None and current.started == p.started


def reap(database, dry=False, table=process_table, send=os.kill, wait=time.sleep, emit=print, now=time.time):
    threads = codex_threads(database, emit)
    if threads is None:
        return 0
    snapshot_time = now()
    initial = table()
    parents = {p.pid: p for p in initial.values() if app_server(p) or user_systemd(p)}
    candidates = [p for p in initial.values()
                  if (p.ppid in parents or p.ppid == 1) and mcp_server(p)]
    stopped, freed, failed = 0, 0, False
    pending = []
    planned_count, planned_rss = 0, 0
    for p in candidates:
        # Refresh both identity and ownership immediately before signalling.
        current = table()
        if (not same(p, current) or
                p.ppid != 1 and (not same(parents[p.ppid], current) or
                                 not (app_server(current[p.ppid]) or user_systemd(current[p.ppid]))) or
                current[p.pid].ppid != p.ppid or current[p.pid].pgid != p.pgid or
                current[p.pid].argv != p.argv or current[p.pid].cwd != p.cwd or
                current[p.pid].uid != p.uid):
            continue
        # Re-read run state before each signal, so a resumed thread is protected.
        threads = codex_threads(database, emit)
        if threads is None:
            break
        stop, reason = decision(p, threads, snapshot_time)
        details = f'pid={p.pid} age={int(p.age)}s command={shlex.join(p.argv)[:100]} reason={reason}'
        if not stop:
            emit(f'Keep {details}')
            continue
        group = p.pgid == p.pid
        members = [q for q in current.values() if q.pgid == p.pid] if group else [p]
        # A process group must not reach outside this app-server's subtree.
        def owned(q):
            seen = set()
            while q.pid not in seen:
                if q.pid == p.pid:
                    return True
                seen.add(q.pid)
                q = current.get(q.ppid)
                if q is None:
                    break
            return False
        if group and not all(owned(q) and not app_server(q) and
                             not any(Path(a).name == 'codex-code-mode' for a in q.argv)
                             for q in members):
            emit(f'Skipped {details}: process group includes protected processes or processes outside server subtree')
            continue
        if dry:
            planned_count += 1
            planned_rss += sum(q.rss for q in members)
            emit(f'Would stop {details}')
            continue
        target = -p.pid if group else p.pid
        try:
            send(target, signal.SIGTERM)
            pending.append((p, target, members, details))
        except ProcessLookupError:
            continue
        except OSError as error:
            emit(f'Failed pid={p.pid}: {error}')
            failed = True
    if pending:
        wait(5)
    for p, target, members, details in pending:
        current = table()
        # Include surviving group children even when their leader has exited.
        remaining = [q for q in members if same(q, current) and current[q.pid].state != 'Z']
        # SIGKILL only the checked processes still alive, never the group again: anything that joined
        # it during the grace period hasn't been checked.
        for q in remaining:
            try:
                send(q.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                emit(f'Failed pid={q.pid}: {error}')
                failed = True
        # Delivery of SIGKILL is asynchronous; give the kernel time to reap.
        for _ in range(10):
            current = table()
            if not any(same(q, current) and current[q.pid].state != 'Z' for q in members):
                break
            wait(0.05)
        if any(same(q, current) and current[q.pid].state != 'Z' for q in members):
            emit(f'Failed pid={p.pid}: still running after SIGKILL')
            failed = True
        else:
            stopped += 1
            emit(f'Stopped {details}')
        freed += sum(q.rss for q in members if not same(q, current) or current[q.pid].state == 'Z')
    if dry:
        emit(f'Summary: dry-run; would stop {planned_count} server(s); RSS {planned_rss} bytes; stopped 0')
    else:
        emit(f'Summary: stopped {stopped} server(s); RSS freed {freed} bytes (snapshot estimate)')
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    return reap(Path.home() / '.t3/userdata/statev2.sqlite', args.dry_run)


if __name__ == '__main__':
    raise SystemExit(main())
