"""Read role entries from the sidstack models file."""
import json
import re
import sys

roles = {}
for line in open(sys.argv[1]):
    if line.startswith('## Notes'):
        break
    match = re.match(r"^- ([^:]+):\s*(.*)", line)
    if not match:
        continue
    role, value = match.groups()
    entries = []
    for entry in re.split(r';(?![^()]*\))', value):
        entry = re.sub(r'\s*\(.*\)$', '', entry).strip()
        parts = [part.strip() for part in entry.split(' / ')]
        # Prose entries (such as the GitHub app) are not model roles.
        if role == 'pr bot':
            continue
        # "none" disables a panel role (e.g. review panel: none).
        if entry.lower() == 'none':
            continue
        if len(parts) != 3 or not all(parts):
            sys.exit('malformed model entry for role: ' + role)
        entries.append(dict(zip(('provider', 'model', 'effort'), parts)))
    roles[role] = entries
for role in ('implementer', 'hardest tasks', 'reviewer'):
    if not roles.get(role):
        sys.exit('missing model role: ' + role)
if 'review panel' not in roles:
    sys.exit('missing model role: review panel')
json.dump(roles, sys.stdout)
