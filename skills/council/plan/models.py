"""Read role entries from the sidstack models file."""
import json
import re
import sys

roles = {}
for line in open(sys.argv[1]):
    match = re.match(r"^- ([^:]+):\s*(.*)", line)
    if not match:
        continue
    role, value = match.groups()
    value = re.split(r"\s+\(", value, maxsplit=1)[0]
    entries = []
    for entry in value.split(';'):
        parts = entry.strip().split(' / ')
        if len(parts) == 3:
            entries.append(dict(zip(('provider', 'model', 'effort'), parts)))
    roles[role] = entries
for role in ('implementer', 'hardest tasks', 'review panel', 'reviewer'):
    if not roles.get(role):
        sys.exit('missing model role: ' + role)
json.dump(roles, sys.stdout)
