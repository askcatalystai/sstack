#!/usr/bin/env python3
"""Read a PR review bot's state. Used by cm.sh bot-review.

  bot_review.py state <owner/repo> <pr> <bot-login>     -> "<sha> <status>" of the bot's last code review
  bot_review.py open  <owner/repo> <pr> <bot-login>     -> one line per unresolved bot thread
"""
import json, re, subprocess, sys

def gh(*args):
    return json.loads(subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout)

mode, repo, pr, bot = sys.argv[1:5]
if mode == "state":
    comments = gh("pr", "view", pr, "--repo", repo, "--json", "comments")["comments"]
    last = ""
    for c in comments:
        if c["author"]["login"].startswith(bot):
            m = re.search(r"codex-review-state:v1 (\{.*?\}) -->", c["body"])
            if m: last = m.group(1)
    cr = json.loads(last).get("code_review", {}) if last else {}
    print(cr.get("commit_sha", "-"), cr.get("status", "-"))
else:
    owner, name = repo.split("/", 1)
    q = ("query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p)"
         "{reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{author{login} path line originalLine body}}}}}}}")
    d = gh("api", "graphql", "-f", f"o={owner}", "-f", f"n={name}", "-F", f"p={pr}", "-f", f"query={q}")
    for t in d["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]:
        c = (t["comments"]["nodes"] or [None])[0]
        if t["isResolved"] or not c or not c["author"]["login"].startswith(bot): continue
        title = c["body"].strip().splitlines()[0]
        sev = (re.search(r"\bP([0-3])\b", title) or [None, "?"])[1]
        title = re.sub(r"<[^>]+>|!\[[^\]]*\]\([^)]*\)|\*", "", title).strip()
        print(f"P{sev}  {c['path']}:{c['line'] or c['originalLine'] or 0}  {title}  [thread {t['id']}]")
