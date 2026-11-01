#!/usr/bin/env python3
"""Show who is working on a Kanzo card, and for how long, as tags on the card.

  sid-card.py work <oe#1> <provider> <model> <effort> [status]   set the worker, and optionally the column
  sid-card.py clear <oe#1>                                       remove the worker tags
  sid-card.py tick                                               refresh the elapsed tag (a timer runs this each minute)

A card more than 2 hours in one column gets a "stale" tag, so stuck work shows without opening it.

The clock is time in the current column: it restarts when a card moves, not when the worker changes.
Only doing and review cards show tags; moving a card anywhere else clears them.
"""
import datetime as dt, json, os, re, subprocess, sys, urllib.request
from pathlib import Path

KANZO = os.path.expanduser("~/.local/bin/kanzo")
URL = "http://127.0.0.1:4242/mcp"
STATE = Path(os.path.expanduser("~/.local/state/sidstack/cards.json"))
ELAPSED = re.compile(r"^(<1m|\d+m|\d+h( \d+m)?|\d+d( \d+h)?|stale)$")
ACTIVE = ("doing", "review")
session, seq = None, 0


def rpc(method, params=None, notify=False):
    global session, seq
    seq += 1
    body = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        body["params"] = params
    if not notify:
        body["id"] = seq
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session:
        headers["mcp-session-id"] = session
    reply = urllib.request.urlopen(urllib.request.Request(URL, json.dumps(body).encode(), headers), timeout=10)
    session = reply.headers.get("mcp-session-id") or session
    for line in reply.read().decode().splitlines():
        if line.startswith("data: {"):
            return json.loads(line[6:])


def connect():
    rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "sid-card", "version": "1"}})
    rpc("notifications/initialized", notify=True)


def update(task, **fields):
    reply = rpc("tools/call", {"name": "update_task", "arguments": {"id": task, **fields}})
    if "error" in reply or reply["result"].get("isError"):
        sys.exit(f"{task}: {reply}")


def tasks():
    data = json.loads(subprocess.run([KANZO, "export", "-f", "json"], check=True, capture_output=True, text=True).stdout)
    found = {}
    for project in data["projects"]:
        for task in project["tasks"]:
            found[task["key"]] = task
    return found


def elapsed(start):
    minutes = int((dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(start)).total_seconds() // 60)
    if minutes < 1:
        return "<1m"
    if minutes < 60:
        return f"{minutes}m"
    if minutes < 1440:
        return f"{minutes // 60}h {minutes % 60}m" if minutes % 60 else f"{minutes // 60}h"
    return f"{minutes // 1440}d {minutes % 1440 // 60}h" if minutes % 1440 // 60 else f"{minutes // 1440}d"


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(state, indent=1))


def own_tags(tags, record):
    worker = [tag.lower() for tag in record.get("worker", [])]
    return [tag for tag in tags if tag not in worker and not ELAPSED.match(tag)]


def tick(state):
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    for task_id, task in tasks().items():
        record = state.get(task_id)
        if task["status"] not in ACTIVE:
            if record:
                update(task_id, tags=", ".join(own_tags(task["tags"], record)))
                del state[task_id]
            continue
        if not record:
            record = state[task_id] = {"worker": [], "status": task["status"], "since": now}
        if record["status"] != task["status"]:
            record.update(status=task["status"], since=now)
        tags = own_tags(task["tags"], record) + [tag.lower() for tag in record["worker"]] + [elapsed(record["since"])]
        if (dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(record["since"])).total_seconds() > 7200:
            tags.append("stale")
        if tags != task["tags"]:
            update(task_id, tags=", ".join(tags))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    connect()
    state = load()
    if command == "work":
        task_id, provider, model, effort, *status = sys.argv[2:]
        if status:
            update(task_id, status=status[0])
        current = tasks()[task_id]
        record = state.setdefault(task_id, {"worker": [], "status": current["status"], "since": dt.datetime.now(dt.timezone.utc).isoformat()})
        update(task_id, tags=", ".join(own_tags(current["tags"], record)))
        record["worker"] = [tag for tag in (provider, model, effort) if tag != "-"]
    elif command == "clear":
        record = state.get(sys.argv[2])
        if record:
            update(sys.argv[2], tags=", ".join(own_tags(tasks()[sys.argv[2]]["tags"], record)))
            record["worker"] = []
    elif command != "tick":
        sys.exit(__doc__)
    tick(state)
    save(state)


main()
