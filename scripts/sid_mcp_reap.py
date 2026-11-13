#!/usr/bin/env python3
"""Reap finished subagent MCP children and old servers without a matching thread."""
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
            result[pid] = Process(pid, int(stat[1]), int(stat[2]), start,
                                  uptime - start / ticks, int(stat[21]) * page, argv, stat[0])
        except (OSError, ValueError, IndexError):
            continue  # Exited or inaccessible while taking the snapshot.
    return result


def app_server(p):
    return len(p.argv) >= 2 and Path(p.argv[0]).name == 'codex' and p.argv[1] == 'app-server'


def mcp_server(p):
    if app_server(p) or any(Path(a).name == 'codex-code-mode' for a in p.argv):
        return False
    command = ' '.join(p.argv)
    return (any(p.argv[i:i + 3] == ('railway', 'mcp', 'proxy') or
                (Path(p.argv[i]).name == 'railway' and p.argv[i + 1:i + 3] == ('mcp', 'proxy'))
                for i in range(len(p.argv) - 2)) or
            any('rea-agents' in a or Path(a).name in ('node_repl', 'cua_repl', 'launch_codex_app_tools_mcp') or
                re.search(r'(?:^|/)mcp/(?:[^/]+/)*launch\.mjs$', a) for a in p.argv))


@dataclass(frozen=True)
class Thread:
    first_run: float
    title: str
    running: bool
    subagent: bool


def codex_threads(database, emit):
    try:
        with sqlite3.connect(Path(database).resolve().as_uri() + '?mode=ro', uri=True, timeout=0.2) as db:
            rows = db.execute("""
                SELECT min(r.requested_at), t.title, max(r.status = 'running'),
                       json_extract(t.payload_json, '$.lineage.parentThreadId') IS NOT NULL
                FROM orchestration_v2_projection_threads t
                JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
                WHERE r.provider_instance_id = 'codex'
                GROUP BY t.thread_id
                ORDER BY t.thread_id
            """).fetchall()
        return [Thread(datetime.fromisoformat(first.replace('Z', '+00:00')).timestamp(),
                       title, bool(running), bool(subagent))
                for first, title, running, subagent in rows]
    except (sqlite3.Error, OSError, ValueError, TypeError, AttributeError) as error:
        emit(f'Skipped: T3 database cannot be read: {error}')
        return None


def decision(p, threads, now):
    started = now - p.age
    matches = [t for t in threads if 0 <= started - t.first_run <= 120]
    thread = max(matches, key=lambda t: t.first_run) if matches else None
    if thread is not None:
        if thread.running:
            return False, 'running thread'
        if not thread.subagent:
            return False, 'operator thread'
        return True, f'subagent {thread.title} finished'
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
    parents = {p.pid: p for p in initial.values() if app_server(p)}
    candidates = [p for p in initial.values() if p.ppid in parents and mcp_server(p)]
    stopped, freed, failed = 0, 0, False
    pending = []
    planned_count, planned_rss = 0, 0
    for p in candidates:
        # Refresh both identity and ownership immediately before signalling.
        current = table()
        if (not same(p, current) or not same(parents[p.ppid], current) or
                current[p.pid].ppid != p.ppid or current[p.pid].pgid != p.pgid or
                current[p.pid].argv != p.argv or not app_server(current[p.ppid])):
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
        if remaining:
            try:
                send(target, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                emit(f'Failed pid={p.pid}: {error}')
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
