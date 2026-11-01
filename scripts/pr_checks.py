#!/usr/bin/env python3
"""What a PR body and its changed files require before merge. Used by sid-merge.sh.

  pr_checks.py <head-sha> <body-file> <files-file>
Prints "needs-bot: <reason>" for each reason the PR bot must review it. Exits 1 with the problem if the body fails.
"""
import re, sys

RISKY = re.compile(r"(^|[/_.-])(auth|oauth|payments?|billing|migrations?)([/_.-]|$)|^commerce/|^\.sidstack/|^app/scripts/test-batches", re.I)


def section(body, name):
    match = re.search(rf"^## {name}\b[^\n]*\n(.*?)(?=^## |\Z)", body, re.M | re.S)
    return match[1].strip() if match else ""


def problems(head, body):
    found = [f"PR body needs content under: ## {name}" for name in ("Proof", "Review") if not section(body, name)]
    proof = section(body, "Proof")
    if proof and head[:7] not in proof:
        found.append(f"## Proof must name the commit it covers ({head[:8]}); push a change and the proof needs renewing")
    return found


def bot_reasons(body, files):
    reasons = [f"risky path {file}" for file in files if RISKY.search(file)][:3]
    if re.search(r"\bskipp?ed\b|\bdidn't run\b", section(body, "Review"), re.I):
        reasons.append("## Review records a skipped step")
    return reasons


if __name__ == "__main__":
    head, body_file, files_file = sys.argv[1:4]
    body = open(body_file).read()
    bad = problems(head, body)
    if bad:
        sys.exit("\n".join(bad))
    for reason in bot_reasons(body, open(files_file).read().split()):
        print(f"needs-bot: {reason}")
