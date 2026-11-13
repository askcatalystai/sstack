#!/usr/bin/env python3
"""Decide whether a PR is ready to merge. Used by sid-merge.sh.

  pr_checks.py <pr-json-file>
The JSON comes from gh pr view. Exits 1 with the problems if it isn't ready. Anything missing or unknown counts as not ready.
The body needs two things: ## Proof naming the head commit, so it is renewed after a push, and ## Review saying who approved.
Whether the words are true is the reviewer's call, not this script's.
"""
import json, re, sys

APPROVED = re.compile(r"\bapprov(e|ed|es|al)\b", re.I)
PASSING = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def section(body, name):
    match = re.search(rf"^## {name}\b[^\n]*\n(.*?)(?=^## |\Z)", body or "", re.M | re.S)
    return match[1].strip() if match else ""


def check_failures(rollup):
    bad = []
    for check in rollup:
        result = check.get("conclusion") or check.get("state") or "PENDING"
        if result not in PASSING:
            bad.append(f"{check.get('name') or check.get('context') or 'check'}: {result}")
    return bad


def problems(pr):
    found = []
    if pr["state"] != "OPEN":
        found.append(f"PR is {pr['state']}, not open")
    if pr["isDraft"]:
        found.append("PR is a draft")
    if pr["mergeable"] != "MERGEABLE":
        found.append(f"GitHub reports mergeable={pr['mergeable']}")
    if pr["reviewDecision"] == "CHANGES_REQUESTED":
        found.append("a reviewer requested changes")
    found += [f"check not passing: {bad}" for bad in check_failures(pr["statusCheckRollup"])]
    head = pr["headRefOid"]
    if head[:7] not in section(pr["body"], "Proof"):
        found.append(f"## Proof must name the commit it covers ({head[:8]}); after a push it needs renewing")
    if not APPROVED.search(section(pr["body"], "Review")):
        found.append("## Review must say who approved this change")
    return found


if __name__ == "__main__":
    bad = problems(json.load(open(sys.argv[1])))
    if bad:
        sys.exit("\n".join(bad))
