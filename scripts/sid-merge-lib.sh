#!/usr/bin/env bash
# Shared readiness and verdict checks. Call ready, then ready_verdict with a private tmp directory.
# Refusals retain sid-merge's exit codes: 1 readiness/API, 6 findings, 7 bot, 8 verdict.
set -u
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$tmp/pr.json" "$1"; }
# Read everything fresh, and stop on any failure: an API error must never look like "nothing wrong".
ready() {
  # GitHub answers UNKNOWN until it has worked out mergeability, and a just-pushed head has checks still pending.
  for wait in 0 3 5 10 15 30 30 30; do
    sleep "$wait"
    gh pr view "$pr" --repo "$gh" --json state,isDraft,mergeable,reviewDecision,statusCheckRollup,body,title,headRefOid,headRefName,baseRefName > "$tmp/pr.json" || { echo "could not read #$pr"; exit 1; }
    [ "$(field mergeable)" != UNKNOWN ] && ! python3 -c 'import json,sys;sys.exit(any(not (c.get("conclusion") or c.get("state") not in (None,"PENDING","EXPECTED")) for c in json.load(open(sys.argv[1]))["statusCheckRollup"]) is False)' "$tmp/pr.json" && break
  done
  # The files API handles PRs too big for `gh pr diff`, and a rename counts under both its names. It stops at 3000 files.
  gh api --paginate "repos/$gh/pulls/$pr/files?per_page=100" --jq '.[] | [.filename, .previous_filename // empty] | join(" ")' > "$tmp/files" || { echo "could not read #$pr's files"; exit 1; }
  [ "$(wc -l < "$tmp/files")" -lt 3000 ] || { echo "#$pr has too many changed files to check"; exit 1; }
  body=$(field body) && title=$(field title) && head=$(field headRefOid) && branch=$(field headRefName) && base=$(field baseRefName) || exit 1
  required=$(python3 "$here/pr_checks.py" "$tmp/pr.json" "$tmp/files") || exit 1
  bot_needed=$need_bot
  if [ -n "$required" ]; then echo "$required"; bot_needed=true; fi
  if [ "$bot_mode" = off ]; then return; fi
  if [ "$bot_needed" = true ]; then
    read -r sha status < <(python3 "$here/bot_review.py" state "$gh" "$pr" "$bot" 2>/dev/null || echo "- -")
    [ "$sha" = "$head" ] || { echo "bot has not reviewed ${head:0:8} yet (last: ${sha:0:8} $status); comment '@codex review' if it stays quiet"; exit 7; }
    [ "$status" = completed ] || { echo "bot status on ${head:0:8}: $status"; exit 7; }
  fi
  open=$(python3 "$here/bot_review.py" open "$gh" "$pr" "$bot") || { echo "could not read review threads"; exit 7; }
  [ -z "$open" ] || { echo "open bot findings:"; echo "$open"; exit 6; }
}
ready_verdict() {
  git fetch -q origin "$default" "$base" "$branch" || exit 1
  patch=$(git diff "$(git merge-base "origin/$base" "$head")" "$head" | git patch-id --verbatim | cut -d' ' -f1)
  verdict=$(awk -F'\t' -v p="$patch" '$3==p{v=$0} END{print v}' "$common/sid-gate/verdicts/$pr.tsv" 2>/dev/null)
  result=$(printf '%s' "$verdict" | cut -f2)
  case "$result" in
    PASS|PASS+NOTES) ;;
    FAIL) echo "the verifier failed this patch: $(printf '%s' "$verdict" | cut -f7)"; exit 8;;
    *) echo "no verdict on patch ${patch:0:8}: have a verifier who didn't write it run the change, then sid-verdict.sh $pr <tested-commit> <PASS|PASS+NOTES|FAIL> <verifier> <t3-thread-id> \"<what it ran and saw>\""; exit 8;;
  esac
  verified="Verified-By: $(printf '%s' "$verdict" | cut -f5) $result, T3 thread $(printf '%s' "$verdict" | cut -f6)"
}
