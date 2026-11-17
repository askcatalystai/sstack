#!/usr/bin/env python3
"""Decide whether a PR is ready to merge. Used by sid-merge.sh.

  pr_checks.py <pr-json-file>
The JSON comes from gh pr view. Exits 1 with the problems if it isn't ready. Anything missing or unknown counts as not ready.
The body needs two things: ## Proof naming the head commit, so it is renewed after a push, and ## Review recording approval with an Approved-Head: <sha> (<who>) trailer.
Whether the words are true is the reviewer's call, not this script's.
"""
import json, re, sys

APPROVED_HEAD = re.compile(r"^(?:[-*] )?Approved-Head: ([0-9a-fA-F]{12,40}) \(([A-Za-z][A-Za-z0-9 ,;:.'/&+-]{2,})\)\s*$")
REVIEW_FORMAT = "## Review must end with `Approved-Head: <12+ hex of head> (<who>)`"
APPROVAL_WITHDRAWN = re.compile(r"^\s*(?:[-*]\s*)?Approval-Withdrawn:")
PASSING = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def section(body, name):
    match = re.search(rf"^## {name}\b[^\n]*\n(.*?)(?=^## |\Z)", body or "", re.M | re.S)
    return match[1].strip("\n") if match else ""


def review_problems(body, head):
    match = re.search(r"^## Review\b[^\n]*\n(.*?)(?=^## |\Z)", body or "", re.M | re.S)
    review = match[1] if match else ""
    lines = review.splitlines(keepends=True)
    last = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].strip()), None)
    trailer = APPROVED_HEAD.fullmatch(lines[last].rstrip("\r\n")) if last is not None else None
    found = []
    if not trailer or not head.lower().startswith(trailer[1].lower()) or not re.search(r"\b[A-Za-z]{3,}\b", trailer[2]):
        found.append(REVIEW_FORMAT)
    if any(APPROVAL_WITHDRAWN.match(line) for line in lines):
        found.append("## Review contains Approval-Withdrawn:")
    if last is None:
        return found
    before = "".join(lines[:last])
    prefix = body[:match.start(1)] + before
    fences = backticks = 0
    for line in prefix.splitlines():
        if re.match(r"^(?:```|~~~)", line):
            fences += 1
        elif fences % 2 == 0:
            backticks += line.count("`")
    if fences % 2:
        found.append("## Review approval trailer is inside an unbalanced code fence")
    if backticks % 2:
        found.append("## Review approval trailer follows an unbalanced backtick")
    outside_code = []
    fence_count = 0
    for line in before.splitlines(keepends=True):
        if re.match(r"^(?:```|~~~)", line):
            fence_count += 1
        elif fence_count % 2 == 0:
            outside_code.append(line)
    html_before = "".join(outside_code)
    comment_open = False
    for marker in re.findall(r"<!--|-->", html_before):
        comment_open = marker == "<!--"
    if comment_open:
        found.append("## Review approval trailer is inside an unclosed HTML comment")
    # Count block HTML only: a tag mentioned within prose or inline code is not a block.
    for tag in ("details", "div", "table", "pre"):
        opens = len(re.findall(rf"^[ \t]*<{tag}\b", html_before, re.M | re.I))
        closes = len(re.findall(rf"</{tag}\s*>", html_before, re.I))
        if opens > closes:
            found.append(f"## Review approval trailer is inside unclosed HTML <{tag}>")
    return found


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
    found += review_problems(pr["body"], head)
    return found


if __name__ == "__main__":
    required = [line.strip() for line in open(sys.argv[2]) if line.strip() and not line.lstrip().startswith("#")] if len(sys.argv) > 2 else []
    bad = problems(json.load(open(sys.argv[1])), required)
    if bad:
        sys.exit("\n".join(bad))
