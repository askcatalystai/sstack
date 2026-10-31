#!/usr/bin/env python3
"""Progress board for one council plan: the page, /jobs (live Codex jobs) and /health. Data lives in the plan's state dir."""
import argparse
import datetime as dt
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import threading
import time
from urllib.parse import urlsplit

import observe

DATA = observe.DATA
STOP = threading.Event()
ANSI = re.compile(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]')

def log_activity(path):
    """Read a bounded tail, even when a CLI log has grown very large."""
    with path.open('rb') as stream:
        stat = os.fstat(stream.fileno())
        start = max(0, stat.st_size - 65536)
        stream.seek(start)
        tail = stream.read(65536).decode('utf-8', errors='replace')
    lines = tail.splitlines()
    if start:
        lines = lines[1:]  # The first line may start in the middle of a record.
    for raw in reversed(lines):
        line = ' '.join(ANSI.sub('', raw).split())
        if not any(char.isalpha() for char in line):
            continue
        if re.fullmatch(r'(?:(?:(?:total|input|output|cached)\s+)?tokens?(?:\s+(?:used|count|usage))?\s*[:=]?\s*[\d,.kKmM]*|[\d,.kKmM]+\s+tokens?)', line, re.I):
            continue
        return (line if len(line) <= 160 else line[:159] + '…'), stat.st_mtime
    return '', stat.st_mtime

def jobs_payload():
    """Independent of the minute snapshot; shared lock matches jobs.py's writer."""
    now = time.time()
    try:
        with (DATA/'jobs.json').open() as stream:
            fcntl.flock(stream, fcntl.LOCK_SH)
            data = json.load(stream)
    except FileNotFoundError:
        data = {'jobs': []}
    result = []
    for source in data['jobs']:
        job = dict(source)
        job.update(lastLine='', logMtime=None, lastActivitySeconds=None, stalled=False)
        if job.get('status') == 'running' and job.get('log'):
            path = Path(job['log'])
            if not path.is_absolute():
                path = DATA/path
            try:
                job['lastLine'], job['logMtime'] = log_activity(path)
                job['lastActivitySeconds'] = max(0, int(now - job['logMtime']))
                job['stalled'] = now - job['logMtime'] > 600
            except OSError:
                job['logUnavailable'] = True
                # A running job with no log for 30 minutes is a dead job (for example an agent that ended with its session).
                started = dt.datetime.fromisoformat(job.get('updatedAt') or job.get('startedAt')).timestamp() if (job.get('updatedAt') or job.get('startedAt')) else now
                job['stalled'] = now - started > 1800
        result.append(job)
    return {'jobs': result, 'checkedAt': dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat()}

def update():
    while not STOP.is_set():
        try:
            snapshot = observe.collect()
            observe.render(snapshot)
            print(observe.iso(), snapshot['status'], 'PR', snapshot['currentNumber'], flush=True)
        except Exception as error:
            print(observe.iso(), type(error).__name__, str(error), flush=True)
        STOP.wait(observe.INTERVAL)

def browser_page():
    page = (DATA/'progress.html').read_text()
    theme = '<style id="browser-theme">'+(observe.HERE/'kanban.css').read_text()+'</style>'
    return page.replace('</head>', theme+'</head>', 1).encode()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/favicon.ico':
            self.send_response(204)
            self.end_headers()
            return
        if path not in ['/', '/progress.html', '/health', '/jobs']:
            self.send_error(404)
            return
        if path == '/jobs':
            try:
                payload = json.dumps(jobs_payload()).encode()
            except (OSError, ValueError, KeyError, TypeError):
                self.send_error(503, 'Job state temporarily unavailable')
                return
            content_type = 'application/json'
        elif path == '/health':
            snapshot = json.loads((DATA/'snapshot.json').read_text())
            payload = json.dumps({'checkedAt':snapshot['checkedAt'], 'intervalSeconds':observe.INTERVAL}).encode()
            content_type = 'application/json'
        else:
            payload = browser_page()
            content_type = 'text/html; charset=utf-8'
        self.send_response(200)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        if urlsplit(self.path).path in ['/health', '/jobs']:
            return
        super().log_message(format, *args)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8787)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    initial = observe.collect()
    observe.render(initial)
    worker = threading.Thread(target=update, daemon=True)
    worker.start()
    print('Dashboard listening on '+args.host+':'+str(server.server_port), flush=True)
    try:
        server.serve_forever()
    finally:
        STOP.set()
        server.server_close()

if __name__ == '__main__':
    main()
