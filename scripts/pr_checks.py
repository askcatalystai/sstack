#!/usr/bin/env python3
"""Decide whether a PR is ready to merge. Used by sid-merge.sh.

  pr_checks.py <pr-json-file> <files-file>
The JSON comes from gh pr view. Prints "needs-bot: <reason>" for each reason the PR bot must review it.
Exits 1 with the problems if it isn't ready. Anything missing or unknown counts as not ready.
"""
import json, re, sys

RISKY = re.compile(r"(^|[/_.-])(auth|oauth|payments?|billing|migrations?)([/_.-]|$)|^commerce/|^\.sidstack/|^app/scripts/test-batches", re.I)
VISIBLE_UI = re.compile(r"^app/apps/(app|desktop)/src/.*\.(tsx|css)$")
NOT_UI = re.compile(r"\.(test|spec)\.tsx$")
EVIDENCE = re.compile(r"\b(pass(ed|es)?|fail(ed|s)?|ran|exit|measured|screenshot|reproduc\w*)\b", re.I)
REVIEWER = re.compile(r"\b(astra|composer|bot|skipp?ed)\b", re.I)
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


def problems(pr, files=()):
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
    proof, review = section(pr["body"], "Proof"), section(pr["body"], "Review")
    head = pr["headRefOid"]
    if head[:7] not in proof:
        found.append(f"## Proof must name the commit it covers ({head[:8]}); after a push it needs renewing")
    if not EVIDENCE.search(proof):
        found.append("## Proof must show what ran and the result, not just a commit")
    if not REVIEWER.search(review):
        found.append("## Review must say who reviewed it, or what was skipped and why")
    ui = [file for file in files if VISIBLE_UI.search(file) and not NOT_UI.search(file)]
    if ui and not re.search(r"screenshot|\.png\b|no visible change", proof, re.I):
        found.append(f"## Proof needs a screenshot, or \"no visible change\" and why; UI changed: {ui[0]}")
    return found


def bot_reasons(pr, files):
    reasons = [f"risky path {file}" for file in files if RISKY.search(file)][:3]
    if re.search(r"\bskipp?ed\b|\bdidn't run\b", section(pr["body"], "Review"), re.I):
        reasons.append("## Review records a skipped step")
    return reasons


if __name__ == "__main__":
    pr = json.load(open(sys.argv[1]))
    files = open(sys.argv[2]).read().split()
    bad = problems(pr, files)
    if bad:
        sys.exit("\n".join(bad))
    for reason in bot_reasons(pr, files):
        print(f"needs-bot: {reason}")
