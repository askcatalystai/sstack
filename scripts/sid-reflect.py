#!/usr/bin/env python3
"""Print what the operator typed in T3 lately, so the nightly-rules skill can find what they had to repeat.

  sid-reflect.py [--hours 24] [--week]
Prints one line per message the operator typed in a top-level thread: time, thread title, text.
--week prints the last 7 days instead, which is the window for "said more than once".
Reads T3's database read-only. Messages agents sent to subagents, and subagent threads, are left out.
"""
import datetime as dt, os, sqlite3, sys

DB = os.path.expanduser("~/.t3/userdata/statev2.sqlite")
QUERY = """
select m.created_at, t.title, json_extract(m.payload_json, '$.text')
from orchestration_v2_projection_messages m
join orchestration_v2_projection_threads t on t.thread_id = m.thread_id
where m.role = 'user' and m.created_at >= ?
  and json_extract(m.payload_json, '$.createdBy') = 'user'
  and json_extract(t.payload_json, '$.lineage.parentThreadId') is null
order by m.created_at
"""


def main():
    args = sys.argv[1:]
    hours = 168 if "--week" in args else int(args[args.index("--hours") + 1]) if "--hours" in args else 24
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S")
    db = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=10)
    for when, title, text in db.execute(QUERY, (since,)):
        text = " ".join((text or "").split())
        if not text or text.startswith("/"):
            continue
        print(f"{when[:16].replace('T', ' ')} [{(title or '')[:24]}] {text[:600]}")


main()
