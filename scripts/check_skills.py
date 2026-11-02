#!/usr/bin/env python3
"""Every skill has a name and description, and every sidstack path it names exists in this repo."""
import glob, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
bad = []
for path in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
    text = open(path).read()
    name = os.path.relpath(path, root)
    front = re.match(r"---\n(.*?)\n---\n", text, re.S)
    for key in ("name", "description"):
        if not (front and re.search(rf"^{key}:\s*\S", front[1], re.M)):
            bad.append(f"{name}: no {key}")
    for linked in re.findall(r"~/\.local/share/sidstack/([\w./-]*\w)", text):
        if not os.path.exists(os.path.join(root, linked)):
            bad.append(f"{name}: {linked} doesn't exist")
sys.exit("\n".join(bad) or 0)
