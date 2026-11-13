#!/usr/bin/env python3
"""Show who is working on a Kanzo card, and for how long, as tags on the card.

  sid-card.py work <oe#1> <provider> <model> <effort> [status]   set the worker, and optionally the column
  sid-card.py clear <oe#1>                                       remove the worker tags
  sid-card.py shots <oe#1> "<caption>" <image.png> ...           post screenshots as a comment the user can see and flag
  sid-card.py link <card> <owner/repo> <pr>                      persist a PR link
  sid-card.py tick                                               refresh the elapsed tag (a timer runs this each minute)

  sid-card.py inbox                                              print the user's new comments on any card, once each

The user's comments carry a "new-comment" tag until inbox reads them. Screenshot comments start "Terra:" and don't count.
The board synchronizer derives idle tags from worker and PR facts.

The clock is time in the current column: it restarts when a card moves, not when the worker changes.
Only doing, review and deployment cards show tags; moving a card anywhere else clears them.
"""
import datetime as dt, json, os, re, subprocess, sys, urllib.request
from pathlib import Path

from kanzo_client import (KANZO, URL, STATE, ELAPSED, ACTIVE, connect, update, tasks,
                          user_comments, load, save, lock, link_pr)

def elapsed(start):
    minutes = int((dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(start)).total_seconds() // 60)
    if minutes < 1:
        return "<1m"
    if minutes < 60:
        return f"{minutes}m"
    if minutes < 1440:
        return f"{minutes // 60}h {minutes % 60}m" if minutes % 60 else f"{minutes // 60}h"
    return f"{minutes // 1440}d {minutes % 1440 // 60}h" if minutes % 1440 // 60 else f"{minutes // 1440}d"


def shots(task, caption, images):
    number = task.split("#")[1]
    files = []
    for image in images:
        request = urllib.request.Request("http://127.0.0.1:4242/api/images", open(image, "rb").read(), {"Content-Type": "image/png"})
        files.append(json.load(urllib.request.urlopen(request, timeout=30))["file"])
    body = json.dumps({"body": caption, "images": files}).encode()
    urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:4242/api/tasks/{number}/comments", body, {"Content-Type": "application/json"}), timeout=10)


def inbox(state, found):
    seen = state.setdefault("_comments_seen", {})
    for key, task in found.items():
        for comment in user_comments(task):
            if comment["id"] not in seen.get(key, []):
                print(f"{key} ({task['status']}) {task['title'][:50]}: {comment['body']}")
                seen.setdefault(key, []).append(comment["id"])
        if "new-comment" in task["tags"]:
            update(key, tags=", ".join(tag for tag in task["tags"] if tag != "new-comment"))


def own_tags(tags, record):
    worker = [tag.lower() for tag in record.get("worker", [])]
    return [tag for tag in tags if tag not in worker and not ELAPSED.match(tag)]


def tick(state):
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    seen = state.setdefault("_comments_seen", {})
    for task_id, task in tasks().items():
        if any(c["id"] not in seen.get(task_id, []) for c in user_comments(task)) and "new-comment" not in task["tags"]:
            task["tags"] = task["tags"] + ["new-comment"]
            update(task_id, tags=", ".join(task["tags"]))
        record = state.get(task_id)
        if task["status"] not in ACTIVE:
            if record:
                update(task_id, tags=", ".join(own_tags(task["tags"], record)))
                record["worker"] = []
            continue
        if not record:
            record = state[task_id] = {"worker": [], "status": task["status"], "since": now}
        if record["status"] != task["status"]:
            record.update(status=task["status"], since=now)
        tags = own_tags(task["tags"], record) + [tag.lower() for tag in record.get("worker", [])] + [elapsed(record["since"])]
        if tags != task["tags"]:
            update(task_id, tags=", ".join(tags))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "link":
        if len(sys.argv) != 5:
            sys.exit("usage: sid-card.py link <card> <owner/repo> <pr>")
        link_pr(sys.argv[2], sys.argv[3], int(sys.argv[4]))
        return
    explicit = command in ("work", "clear", "shots", "inbox")
    guard = lock(timeout=60 if explicit else 0)
    if guard is None:
        if explicit:
            sys.exit("sid-card: board was busy for 60 seconds; command not applied")
        return
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
    elif command == "shots":
        shots(sys.argv[2], sys.argv[3], sys.argv[4:])
    elif command == "inbox":
        inbox(state, tasks())
    elif command != "tick":
        sys.exit(__doc__)
    tick(state)
    save(state)


if __name__ == "__main__":
    main()
