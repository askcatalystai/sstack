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
APPROVAL_WITHDRAWN = re.compile(r"^\s*(?:[-*]\s+)?Approval-Withdrawn:")
PASSING = {"SUCCESS", "NEUTRAL", "SKIPPED"}


def section_ranges(lines):
    headings = []
    for i, line in enumerate(lines):
        atx = re.match(r"^## ([^\r\n]+)", line)
        if atx:
            headings.append((i, i + 1, atx[1].strip()))
        elif i and lines[i - 1].strip() and re.fullmatch(r" {0,3}(?:-+|=+)[ \t]*", line.rstrip("\r\n")):
            headings.append((i - 1, i + 1, lines[i - 1].strip()))
    return [(title, start, headings[n + 1][0] if n + 1 < len(headings) else len(lines))
            for n, (_, start, title) in enumerate(headings)]


def section(body, name):
    lines = (body or "").splitlines(keepends=True)
    return next(("".join(lines[start:end]).strip("\n") for title, start, end in section_ranges(lines)
                 if re.match(rf"{name}\b", title)), "")


def code_context(lines):
    fence = span = None
    backticks = 0
    comment = False
    contexts = []
    for line in lines:
        in_fence, in_span, in_comment = fence is not None, span is not None, comment
        visible = []
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        if fence:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
        elif marker:
            fence = marker[1]
        else:
            backticks += line.count("`")
            i = 0
            while i < len(line):
                if comment:
                    if line.startswith("-->", i):
                        comment = False
                        i += 3
                    else:
                        i += 1
                    visible.append(" ")
                elif line[i] == "`":
                    run = re.match(r"`+", line[i:])[0]
                    if span is None:
                        span = len(run)
                    elif span == len(run):
                        span = None
                    visible.append(" " * len(run))
                    i += len(run)
                elif span:
                    visible.append(" ")
                    i += 1
                elif line.startswith("<!--", i):
                    comment = True
                    visible.append("    ")
                    i += 4
                else:
                    visible.append(line[i])
                    i += 1
        # Indented code cannot supply visible HTML lines.
        text = "".join(visible) if not re.match(r"^(?: {4}| *\t)", line) else ""
        contexts.append((in_fence, in_span, in_comment, backticks % 2, text))
    return contexts


def review_problems(body, head):
    lines = (body or "").splitlines(keepends=True)
    reviews = [(start, end) for title, start, end in section_ranges(lines) if re.match(r"Review\b", title)]
    found = []
    if len(reviews) > 1:
        found.append("duplicate ## Review")
    contexts = code_context(lines)
    if any(APPROVAL_WITHDRAWN.match(line) for line in lines):
        found.append("PR contains Approval-Withdrawn:")
    start, end = reviews[0] if reviews else (0, 0)
    last = next((i for i in range(end - 1, start - 1, -1) if lines[i].strip()), None)
    trailer = APPROVED_HEAD.fullmatch(lines[last].rstrip("\r\n")) if last is not None else None
    if not trailer or not head.lower().startswith(trailer[1].lower()) or not re.search(r"\b[A-Za-z]{3,}\b", trailer[2]):
        found.append(REVIEW_FORMAT)
    if last is None:
        return found
    in_fence, in_span, in_comment, odd_backticks, _ = contexts[last]
    if in_fence:
        found.append("trailer is inside a code fence")
    if in_span or odd_backticks:
        found.append("## Review approval trailer follows an unbalanced backtick")
    if in_comment:
        found.append("## Review approval trailer is inside an unclosed HTML comment")
    tags = dict.fromkeys(("details", "div", "table", "pre"), 0)
    for line, (_, _, _, _, text) in zip(lines[start:last], contexts[start:last]):
        if re.match(r"^ {0,3}</?(?:details|div|table|pre)\b", line, re.I) and re.match(r"^ {0,3}<", text):
            for tag in re.finditer(r"<(/?)(details|div|table|pre)\b[^>]*>", text, re.I):
                name = tag[2].lower()
                tags[name] = max(0, tags[name] + (-1 if tag[1] else 1))
    for tag, count in tags.items():
        if count:
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
