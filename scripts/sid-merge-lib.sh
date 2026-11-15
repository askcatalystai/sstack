#!/usr/bin/env bash
# Shared readiness checks. Call ready with a private tmp directory; it exits 1 when the PR isn't ready or can't be read.
set -u
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$tmp/pr.json" "$1"; }
# Read everything fresh, and stop on any failure: an API error must never look like "nothing wrong".
ready() {
  # GitHub answers UNKNOWN until it has worked out mergeability, and a just-pushed head has checks still pending.
  for wait in 0 3 5 10 15 30 30 30; do
    sleep "$wait"
    gh pr view "$pr" --repo "$gh" --json state,isDraft,mergeable,reviewDecision,statusCheckRollup,body,title,headRefOid,headRefName,baseRefName,autoMergeRequest > "$tmp/pr.json" || { echo "could not read #$pr"; exit 1; }
    if python3 -c 'import json,sys;sys.exit(not bool(json.load(open(sys.argv[1])).get("autoMergeRequest")))' "$tmp/pr.json"; then
      echo "#$pr has auto-merge armed; run gh pr merge $pr --disable-auto"
      exit 1
    fi
    [ "$(field mergeable)" != UNKNOWN ] && ! python3 -c 'import json,sys;sys.exit(any(not (c.get("conclusion") or c.get("state") not in (None,"PENDING","EXPECTED")) for c in json.load(open(sys.argv[1]))["statusCheckRollup"]) is False)' "$tmp/pr.json" && break
  done
  body=$(field body) && title=$(field title) && head=$(field headRefOid) && branch=$(field headRefName) && base=$(field baseRefName) || exit 1
  git -C "$repo" fetch -q origin "$default" || { echo "could not refresh required checks"; exit 1; }
  if git -C "$repo" cat-file -e "origin/$default:.sidstack/required-checks" 2>/dev/null; then
    git -C "$repo" show "origin/$default:.sidstack/required-checks" > "$tmp/required-checks" || exit 1
  else
    git -C "$repo" rev-parse --verify "origin/$default^{commit}" >/dev/null || exit 1
    : > "$tmp/required-checks"
  fi
  python3 "$here/pr_checks.py" "$tmp/pr.json" "$tmp/required-checks" || exit 1
}
# A commit that failed the gate goes back once, with --retry; after a second failure only a new commit does.
retry_allowed() {
  local failed_head failures log
  [ -f "$train/failed/$pr" ] && read -r failed_head failures log < "$train/failed/$pr" || return 0
  [ "$failed_head" = "$head" ] || return 0
  if [ "$failures" -ge 2 ]; then
    echo "${head:0:8} has failed the gate twice, so it was never a flake: read $log, fix it and push a new commit"
    return 1
  fi
  [ "$retry" = true ] && return 0
  echo "${head:0:8} already failed the gate: read $log. Fix it and push; only for a flake or an infrastructure failure, run sid-merge --retry $pr (once)"
  return 1
}

# Refused/unconfirmed CLI calls can arm auto-merge. Re-read after disarming,
# including when the disable command itself fails: only observed state counts.
disarm_auto() {
  local pr=$1 snapshot
  snapshot=$(gh pr view "$pr" --repo "$gh" --json autoMergeRequest) || {
    echo "could not confirm auto-merge is off; run gh pr merge $pr --disable-auto"; return 1;
  }
  if ! python3 -c 'import json,sys;sys.exit(bool(json.load(sys.stdin)["autoMergeRequest"]))' <<< "$snapshot"; then
    gh pr merge "$pr" --repo "$gh" --disable-auto >/dev/null 2>&1
    snapshot=$(gh pr view "$pr" --repo "$gh" --json autoMergeRequest) || snapshot=
    if ! python3 -c 'import json,sys;sys.exit(bool(json.load(sys.stdin)["autoMergeRequest"]))' <<< "$snapshot" 2>/dev/null; then
      echo "could not confirm auto-merge is off; run gh pr merge $pr --disable-auto"; return 1
    fi
  fi
}
