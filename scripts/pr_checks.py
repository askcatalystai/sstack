#!/usr/bin/env python3
"""Decide whether a PR is ready to merge. Used by sid-merge.sh.

  pr_checks.py <pr-json-file>
The JSON comes from gh pr view. Exits 1 with the problems if it isn't ready. Anything missing or unknown counts as not ready.
The body needs two things: ## Proof naming the head commit, so it is renewed after a push, and ## Review naming the approved head and saying who approved.
Whether the words are true is the reviewer's call, not this script's.
"""
import json, re, sys

APPROVED = re.compile(r"\bapprov\w*", re.I)
NOT_APPROVED = re.compile(r"\b(not|no|never|without|pending|awaiting)\s+(\w+\s+){0,2}approv\w*|\bapproval\s+(is\s+)?(pending|needed|required)\b", re.I)
REVIEW_PENDING = re.compile(
    r"\b(?:require(?:s|d)?|need(?:s|ed)?|await(?:s|ing)?|waiting\s+for|outstanding|pending)\b"
    r"[^.!?]*?\b(?:re-?check|re-?review|review|sign-?off)\b"
    r"|\bre-?review\s+(?:is\s+)?pending\b"
    r"|\bnot\s+(?:yet\s+)?(?:re-?)?reviewed\b"
    r"|\bdoes\s+not\s+cover\b|\bretracted\b|\bdo\s+not\s+merge\b", re.I)
HIDDEN = re.compile(r"<!--.*?-->|~~.*?~~", re.S)
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
    review = HIDDEN.sub(" ", section(pr["body"], "Review"))
    # Match only actual prefixes of this head, never a substring of another SHA.
    prefixes = "|".join(re.escape(head[:length]) for length in range(len(head), 6, -1))
    approved_head = re.compile(rf"(?<![0-9a-f])(?:{prefixes})(?![0-9a-f])", re.I)
    if not approved_head.search(review):
        found.append(f"## Review must name the approved head ({head[:8]})")
    approval = any(APPROVED.search(sentence) and approved_head.search(sentence)
                   for sentence in re.split(r"[.!?\n]+", NOT_APPROVED.sub("", review)))
    if REVIEW_PENDING.search(pr["body"] or "") or not approval:
        found.append("## Review must say who approved this change")
    return found


if __name__ == "__main__":
    required = [line.strip() for line in open(sys.argv[2]) if line.strip() and not line.lstrip().startswith("#")] if len(sys.argv) > 2 else []
    bad = problems(json.load(open(sys.argv[1])), required)
    if bad:
        sys.exit("\n".join(bad))
