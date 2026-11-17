#!/usr/bin/env python3
"""Decide whether a PR is ready to merge. Used by sid-merge.sh.

  pr_checks.py <pr-json-file>
The JSON comes from gh pr view. Exits 1 with the problems if it isn't ready. Anything missing or unknown counts as not ready.
The body needs two things: ## Proof naming the head commit, so it is renewed after a push, and ## Review recording approval with an Approved-Head: <sha> (<who>) trailer.
Whether the words are true is the reviewer's call, not this script's.
"""
import json, re, sys

APPROVED_HEAD = re.compile(r"^\s*(?:[-*]\s*)?Approved-Head:\s*([0-9a-fA-F]{7,40})\b(.*)$")
APPROVAL_WITHDRAWN = re.compile(r"^\s*(?:[-*]\s*)?Approval-Withdrawn:")
PASSING = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def section(body, name):
    match = re.search(rf"^## {name}\b[^\n]*\n(.*?)(?=^## |\Z)", body or "", re.M | re.S)
    return match[1].strip() if match else ""


def review_text(body):
    # Preserve line boundaries so removing hidden text cannot create a trailer.
    def blank(match):
        return re.sub(r"[^\n]", " ", match[0])

    body = re.sub(r"<!--.*?(?:-->|\Z)", blank, body or "", flags=re.S)
    visible = []
    fence = None
    for line in body.splitlines():
        marker = re.match(r"^[ \t]*(`{3,}|~{3,})(.*)$", line)
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
            visible.append("")
        elif marker:
            fence = marker[1]
            visible.append("")
        else:
            visible.append(line)
    body = re.sub(r"~~.*?~~", blank, "\n".join(visible), flags=re.S)
    return section(body, "Review")


def approves_head(line, head):
    match = APPROVED_HEAD.match(line)
    if not match or not head.lower().startswith(match[1].lower()):
        return False
    approvers = re.fullmatch(r"\s*\((.*)\)\s*", match[2])
    if not approvers:
        return False
    # Comments, strikethrough and fences were removed by review_text.
    visible = re.sub(r"(`+).*?\1", " ", approvers[1])
    return any(char.isalpha() for char in visible)


def check_failures(rollup):
    bad = []
    for check in rollup:
        result = check.get("conclusion") or check.get("state") or "PENDING"
        if result not in PASSING:
            bad.append(f"{check.get('name') or check.get('context') or 'check'}: {result}")
    return bad


def problems(pr, required=()):
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
    for name in required:
        matches = [c for c in pr["statusCheckRollup"] if (c.get("name") or c.get("context")) == name]
        if not matches or any((c.get("conclusion") or c.get("state")) != "SUCCESS" for c in matches):
            found.append(f"required check not successful: {name}")
    head = pr["headRefOid"]
    if head[:7] not in section(pr["body"], "Proof"):
        found.append(f"## Proof must name the commit it covers ({head[:8]}); after a push it needs renewing")
    review = review_text(pr["body"])
    approved = any(approves_head(line, head) for line in review.splitlines())
    withdrawn = any(APPROVAL_WITHDRAWN.match(line) for line in review.splitlines())
    if withdrawn or not approved:
        found.append(f"## Review must contain `Approved-Head: {head[:8]}` naming who approved this head.")
    return found


if __name__ == "__main__":
    required = [line.strip() for line in open(sys.argv[2]) if line.strip() and not line.lstrip().startswith("#")] if len(sys.argv) > 2 else []
    bad = problems(json.load(open(sys.argv[1])), required)
    if bad:
        sys.exit("\n".join(bad))
