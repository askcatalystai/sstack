#!/usr/bin/env python3
"""Decide whether a PR is ready to merge. Used by sid-merge.sh.

  pr_checks.py <pr-json-file> <files-file>
The JSON comes from gh pr view. Prints "needs-bot: <reason>" for each reason the PR bot must review it.
Proof lines reporting failures go to stderr as "proof-failures: <line>". They don't block: the orchestrator reads them and decides.
Exits 1 with the problems if it isn't ready. Anything missing or unknown counts as not ready.
"""
import json, os, re, sys

RISKY = re.compile(r"(^|[/_.-])(auth|oauth|payments?|billing|migrations?|db|database|schema|persistence)([/_.-]|$)|^commerce/|^\.sidstack/|^app/scripts/test-batches|(^|/)(sid-[a-z]+\.sh|pr_checks\.py|bot_review\.py)$", re.I)
VISIBLE_UI = re.compile(r"^app/(apps/(app|desktop)|packages/(ui|apps-catalog))/src/.*\.(tsx|css)$")
NOT_UI = re.compile(r"\.(test|spec)\.tsx$")
# These catch empty and careless sections. They can't tell whether the words are true; review of the PR does that.
EVIDENCE = re.compile(r"\b\d+ (pass|passed|fail|failed)\b|\b(passed|exit 0|measured|reproduced)\b|\S\.png\b", re.I)
OUTCOME = re.compile(r"\b(approved|changes|found|fixed|declined|no (new )?(bugs|findings|issues))\b|\b(skipped|not run)\b", re.I)
SKIPPED = re.compile(r"(?<!no steps )(?<!nothing )(?<!not )\bskipp?ed\b|\bnot run\b|\bdidn't run\b", re.I)
NO_FAILURE = re.compile(r"\b(?:0|no|none|zero|nothing|never|not|didn't|without) (?:(?:tests?|checks?|jobs?|steps?|suites?|specs?|files?) )?fail(?:s|ed|ing|ures?)?\b", re.I)
FAILURE = re.compile(r"\bfail(?:s|ed|ing|ures?)?\b|\btimed out\b|\bexit(?:ed)?(?: with)?(?: code| status)?:? [1-9]\d*\b", re.I)
SCREENSHOT = re.compile(r"[^\s`'\"()<>\[\]]+\.png\b", re.I)
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
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


def failure_lines(proof):
    return [line.strip() for line in proof.splitlines() if FAILURE.search(NO_FAILURE.sub("", line))]


def is_png(path):
    try:
        with open(os.path.expanduser(path), "rb") as image:
            return image.read(len(PNG_SIGNATURE)) == PNG_SIGNATURE
    except OSError:
        return False


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
    if not EVIDENCE.search(proof) and not failure_lines(proof):
        found.append("## Proof must show what ran and the result, not just a commit")
    if not OUTCOME.search(review):
        found.append("## Review must say what each reviewer concluded, or what was skipped and why")
    for path in SCREENSHOT.findall(proof):
        if not re.match(r"https?://", path, re.I) and not is_png(path):
            found.append(f"## Proof names {path}, which is not a PNG file here; use an absolute path")
    ui = [file for file in files if VISIBLE_UI.search(file) and not NOT_UI.search(file)]
    if ui and not re.search(r"\S\.png\b|no visible change", proof, re.I):
        found.append(f"## Proof needs a screenshot path, or \"no visible change\" and why; UI changed: {ui[0]}")
    return found


def bot_reasons(pr, files):
    reasons = [f"risky path {file}" for file in files if RISKY.search(file)][:3]
    if SKIPPED.search(section(pr["body"], "Review")):
        reasons.append("## Review records a skipped step")
    return reasons


if __name__ == "__main__":
    pr = json.load(open(sys.argv[1]))
    files = open(sys.argv[2]).read().split()
    bad = problems(pr, files)
    if bad:
        sys.exit("\n".join(bad))
    for line in failure_lines(section(pr["body"], "Proof")):
        print(f"proof-failures: {line}", file=sys.stderr)
    for reason in bot_reasons(pr, files):
        print(f"needs-bot: {reason}")
