"""Shared local Kanzo transport and card state."""
import json, os, re, subprocess, sys, urllib.request
from pathlib import Path
KANZO = os.environ.get("KANZO_BIN", os.path.expanduser("~/.local/bin/kanzo"))
URL = os.environ.get("KANZO_URL", "http://127.0.0.1:4242/mcp")
STATE = Path(os.path.expanduser("~/.local/state/sidstack/cards.json"))
ELAPSED = re.compile(r"^(<1m|\d+m|\d+h( \d+m)?|\d+d( \d+h)?|stale)$")
ACTIVE = ("doing", "review", "deployment")
session, seq = None, 0
_connected = False


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
    with urllib.request.urlopen(urllib.request.Request(URL, json.dumps(body).encode(), headers), timeout=10) as reply:
        session = reply.headers.get("mcp-session-id") or session
        content = reply.read().decode()
    if content.lstrip().startswith("{"):
        return json.loads(content)
    for line in content.splitlines():
        if line.startswith("data: {"):
            return json.loads(line[6:])


def connect():
    global _connected
    if _connected:
        return
    reply = rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "sid-card", "version": "1"}})
    if not reply or "error" in reply:
        raise RuntimeError(f"Kanzo initialize: {reply}")
    rpc("notifications/initialized", notify=True)
    _connected = True


def update(task, **fields):
    reply = rpc("tools/call", {"name": "update_task", "arguments": {"id": task, **fields}})
    if not reply or "error" in reply or reply["result"].get("isError"):
        raise RuntimeError(f"{task}: {reply}")


def tasks():
    data = export()
    found = {}
    for project in data["projects"]:
        for task in project["tasks"]:
            found[task["key"]] = task
    return found


def user_comments(task):
    return [c for c in task.get("comments", []) if c.get("author") == "me" and not c.get("body", "").startswith("Terra:")]


def load():
    return json.loads(STATE.read_text()) if STATE.exists() else {}


def save(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    temporary = STATE.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=1))
    temporary.replace(STATE)



def call(name, **arguments):
    reply = rpc("tools/call", {"name": name, "arguments": arguments})
    if not reply or "error" in reply or reply["result"].get("isError"):
        raise RuntimeError(str(reply))
    return reply["result"]


def export():
    return json.loads(subprocess.run([KANZO, "export", "-f", "json"], check=True,
                                    capture_output=True, text=True, timeout=15).stdout)


def human(key):
    request = urllib.request.Request("http://127.0.0.1:4242/api/tasks/" + key.split("#")[1],
        json.dumps({"human": True}).encode(), {"Content-Type": "application/json"}, method="PATCH")
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()


def lock(timeout=0):
    import fcntl
    import time
    STATE.parent.mkdir(parents=True, exist_ok=True)
    handle = (STATE.parent / "cards.lock").open("w")
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                handle.close()
                return None
            time.sleep(min(0.1, remaining))


KEY = r'[\w-]+#\d+(?![\w#])'


def body_keys(body):
    declaration = (r'\bKanzo\s*:?\s+' + KEY +
                   r'(?:(?:\s*,\s*(?:and\s+)?|\s+and\s+|\s*\(also\s+)' + KEY + r'\)?)*')
    return {key.lower() for match in re.finditer(declaration, body, re.I)
            for key in re.findall(KEY, match.group(), re.I)}


def pr_keys(pr):
    return sorted(body_keys(pr.get('body') or '') | {
        key.lower() for field in ('title', 'headRefName')
        for key in re.findall(r'(?<![\w#-])' + KEY, pr.get(field) or '', re.I)})


def link_pr(key, repo, number):
    connect()
    return call("link_pr", id=key, repo=repo, number=int(number))


def resolve_pr(path, explicit):
    candidates = list(dict.fromkeys(explicit)) if explicit else pr_keys(json.loads(Path(path).read_text()))
    try:
        known = tasks()
    except Exception as error:
        print(f"warning: Kanzo unreachable; cannot validate cards: {error}", file=sys.stderr)
        return candidates
    return [key for key in candidates if key in known]


if __name__ == '__main__':
    keys = resolve_pr(sys.argv[1], sys.argv[2:])
    if not keys:
        sys.exit("No Kanzo card resolved; supply --card <key>.")
    print('\n'.join(keys))
