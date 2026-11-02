#!/usr/bin/env bash
# sid-merge [--check] [--bot] <pr>: merge a PR only when it is really ready, then remove its worktree and branch.
# Ready means everything in pr_checks.py: open, mergeable, checks passed, no changes requested, real Proof and Review;
# no open PR bot threads; the PR bot finished on the head commit if it's needed: with --bot, a risky path, or a skipped
# review step (see pr_checks.py; comment '@codex review' to ask it); and the gate passed on this head merged with the latest
# default branch (it reruns the gate if the default branch moved). --check stops before merging.
# The squash commit carries the gate's Gate-Passed record. Proof lines reporting failures print as "proof-failures:" and don't block.
# Exit: 0 merged or ready, 1 not ready, 6 open bot findings, 7 bot not finished on the head, 3 conflicts.
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
check=false; need_bot=false
while [ "${1:-}" = --check ] || [ "${1:-}" = --bot ]; do
  [ "$1" = --check ] && check=true
  [ "$1" = --bot ] && need_bot=true
  shift
done
pr=${1:?usage: sid-merge [--check] <pr>}
bot=${SID_PR_BOT:-chatgpt-codex-connector}
repo=$(git rev-parse --show-toplevel) || exit 1
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir); repo=$(dirname "$common")
cd "$repo" || exit 1
gh=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$tmp/pr.json" "$1"; }
# Read everything fresh, and stop on any failure: an API error must never look like "nothing wrong".
ready() {
  # GitHub answers UNKNOWN until it has worked out mergeability, and a just-pushed head has checks still pending.
  for wait in 0 3 5 10 15 30 30 30; do
    sleep "$wait"
    gh pr view "$pr" --repo "$gh" --json state,isDraft,mergeable,reviewDecision,statusCheckRollup,body,title,headRefOid,headRefName,baseRefName > "$tmp/pr.json" || { echo "could not read #$pr"; exit 1; }
    [ "$(field mergeable)" != UNKNOWN ] && ! python3 -c 'import json,sys;sys.exit(any(not (c.get("conclusion") or c.get("state") not in (None,"PENDING","EXPECTED")) for c in json.load(open(sys.argv[1]))["statusCheckRollup"]) is False)' "$tmp/pr.json" && break
  done
  gh pr diff "$pr" --repo "$gh" --name-only > "$tmp/files" || { echo "could not read #$pr's files"; exit 1; }
  body=$(field body) && title=$(field title) && head=$(field headRefOid) && branch=$(field headRefName) && base=$(field baseRefName) || exit 1
  required=$(python3 "$here/pr_checks.py" "$tmp/pr.json" "$tmp/files") || exit 1
  bot_needed=$need_bot
  if [ -n "$required" ]; then echo "$required"; bot_needed=true; fi
  if [ "$bot_needed" = true ]; then
    read -r sha status < <(python3 "$here/bot_review.py" state "$gh" "$pr" "$bot" 2>/dev/null || echo "- -")
    [ "$sha" = "$head" ] || { echo "bot has not reviewed ${head:0:8} yet (last: ${sha:0:8} $status); comment '@codex review' if it stays quiet"; exit 7; }
    [ "$status" = completed ] || { echo "bot status on ${head:0:8}: $status"; exit 7; }
  fi
  open=$(python3 "$here/bot_review.py" open "$gh" "$pr" "$bot") || { echo "could not read review threads"; exit 7; }
  [ -z "$open" ] || { echo "open bot findings:"; echo "$open"; exit 6; }
}
# The gate can take minutes, so every merge attempt rereads the PR with no gate in between.
for attempt in 1 2 3 4; do
  ready
  git fetch -q origin "$base" || exit 1
  main=$(git rev-parse "origin/$base")
  stamp=$common/sid-gate/${branch//\//_}.pass
  gate_record=$(sed -n 2p "$stamp" 2>/dev/null)
  if [ "$(sed -n 1p "$stamp" 2>/dev/null)" != "$head $main" ] || [ -z "$gate_record" ]; then
    "$here/sid-gate.sh" "$branch"; rc=$?; [ "$rc" = 0 ] || exit "$rc"
    continue
  fi
  if [ "$check" = true ]; then echo "ready: #$pr ${head:0:8}"; exit 0; fi
  # No branch protection on this plan, so narrow the window: main must still be what the gate tested.
  [ "$(git ls-remote origin "refs/heads/$base" | cut -f1)" = "$main" ] || continue
  # Across the branch, because the head can be a merge commit with no trailers of its own.
  trailers=$(git log "origin/$base..$head" --format='%(trailers:only,unfold)' | sed '/^$/d' | sort -u)
  trailers=$(printf '%s\n%s' "$trailers" "$gate_record" | sed '/^$/d')
  message=$(printf '%s\n\n%s' "$body" "$trailers")
  gh pr merge "$pr" --repo "$gh" --squash --subject "$title (#$pr)" --body "$message" --match-head-commit "$head" >/dev/null || { echo "merge refused; retrying if $base moved"; sleep 5; continue; }
  echo "merged #$pr: $(gh pr view "$pr" --repo "$gh" --json mergeCommit -q .mergeCommit.oid)"
  echo "$gate_record"
  rm -f "$stamp"
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} $0=="branch "b{print w}')
  if [ -n "$wt" ]; then git worktree remove "$wt" || echo "kept $wt: it has uncommitted or untracked files"; fi
  git branch -qD "$branch" 2>/dev/null
  git push -q origin --delete "$branch" 2>/dev/null
  exit 0
done
echo "could not merge: $base kept moving, or the merge was refused"; exit 1
