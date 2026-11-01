#!/usr/bin/env bash
# sid-merge [--check] [--bot] <pr>: merge a PR only when it is really ready, then remove its worktree and branch.
# Ready means: open and not a draft; the body has "## Proof" and "## Review" sections with content; no open PR bot
# threads; with --bot, the PR bot finished on the head commit (for risky PRs, after commenting '@codex review');
# and the gate passed on this head merged with the latest
# default branch (it reruns the gate if the default branch moved). --check stops before merging.
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
field() { gh pr view "$pr" --repo "$gh" --json "$1" -q ".$1"; }
[ "$(field state)" = OPEN ] || { echo "#$pr is not open"; exit 1; }
[ "$(field isDraft)" = false ] || { echo "#$pr is a draft"; exit 1; }
body=$(field body); title=$(field title); head=$(field headRefOid); branch=$(field headRefName); base=$(field baseRefName)
python3 -c '
import re,sys
missing=[n for n in ("Proof","Review") if not re.search(r"^## %s[^\n]*\n+(?!## )\S"%n, sys.argv[1], re.M)]
if missing: sys.exit("PR body needs content under: "+", ".join("## "+n for n in missing))
' "$body" || exit 1
if [ "$need_bot" = true ]; then
  read -r sha status < <(python3 "$here/bot_review.py" state "$gh" "$pr" "$bot" 2>/dev/null || echo "- -")
  [ "$sha" = "$head" ] || { echo "bot has not reviewed ${head:0:8} yet (last: ${sha:0:8} $status); comment '@codex review' if it stays quiet"; exit 7; }
  [ "$status" = completed ] || { echo "bot status on ${head:0:8}: $status"; exit 7; }
fi
open=$(python3 "$here/bot_review.py" open "$gh" "$pr" "$bot") || { echo "could not read review threads"; exit 7; }
[ -z "$open" ] || { echo "open bot findings:"; echo "$open"; exit 6; }
for attempt in 1 2 3; do
  git fetch -q origin "$base" || exit 1
  main=$(git rev-parse "origin/$base")
  if [ "$(cat "$common/sid-gate/$head" 2>/dev/null)" != "$main" ]; then
    "$here/sid-gate.sh" "$branch"; rc=$?; [ "$rc" = 0 ] || exit "$rc"
    continue
  fi
  if [ "$check" = true ]; then echo "ready: #$pr ${head:0:8}"; exit 0; fi
  trailers=$(git log -1 --format='%(trailers:only,unfold)' "$head")
  message=$body; [ -z "$trailers" ] || message=$(printf '%s\n\n%s' "$body" "$trailers")
  gh pr merge "$pr" --repo "$gh" --squash --subject "$title (#$pr)" --body "$message" --match-head-commit "$head" >/dev/null || { echo "merge refused; retrying if $base moved"; sleep 5; continue; }
  echo "merged #$pr: $(gh pr view "$pr" --repo "$gh" --json mergeCommit -q .mergeCommit.oid)"
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{w=$2} $0=="branch "b{print w}')
  if [ -n "$wt" ]; then git worktree remove "$wt" || echo "kept $wt: it has uncommitted or untracked files"; fi
  git branch -qD "$branch" 2>/dev/null
  git push -q origin --delete "$branch" 2>/dev/null
  exit 0
done
echo "could not merge: $base kept moving, or the merge was refused"; exit 1
