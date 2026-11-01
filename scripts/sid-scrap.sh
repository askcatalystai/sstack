#!/usr/bin/env bash
# sid-scrap <pr|branch> <reason>: scrap unmerged work. Closes the PR with the reason, deletes the branch, removes the worktree.
# sid-scrap --revert <pr> <reason>: undo a merged PR. Opens a revert PR, which ships like any other.
# Run it from the repo. It refuses the default branch, and it won't remove a worktree outside T3's or <repo>-wt.
set -u
revert=false; [ "${1:-}" = --revert ] && { revert=true; shift; }
target=${1:?usage: sid-scrap [--revert] <pr|branch> <reason>}; reason=${2:?give a reason, it goes on the PR}
common=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1; repo=$(dirname "$common"); cd "$repo" || exit 1
gh=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1
base=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name) || exit 1
if [ "$revert" = true ]; then
  commit=$(gh pr view "$target" --repo "$gh" --json mergeCommit -q .mergeCommit.oid) && [ -n "$commit" ] || { echo "#$target isn't merged"; exit 1; }
  title=$(gh pr view "$target" --repo "$gh" --json title -q .title)
  branch=revert-$target; wt=$repo-wt/$branch
  git fetch -q origin "$base" && git worktree add -q -b "$branch" "$wt" "origin/$base" || exit 1
  git -C "$wt" revert --no-edit "$commit" || { echo "conflicts: resolve in $wt"; exit 3; }
  git -C "$wt" push -q -u origin "$branch" || exit 1
  gh pr create --repo "$gh" --base "$base" --head "$branch" --title "revert: $title" --body "Reverts #$target. $reason"
  exit
fi
if [[ $target =~ ^[0-9]+$ ]]; then
  [ "$(gh pr view "$target" --repo "$gh" --json state -q .state)" = OPEN ] || { echo "#$target isn't open; use --revert for merged work"; exit 1; }
  branch=$(gh pr view "$target" --repo "$gh" --json headRefName -q .headRefName); pr=$target
else
  branch=$target; pr=$(gh pr list --repo "$gh" --head "$branch" --state open --json number -q '.[0].number')
fi
[ "$branch" != "$base" ] || { echo "refusing to scrap $base"; exit 1; }
[ -z "$pr" ] || gh pr close "$pr" --repo "$gh" --comment "Scrapped: $reason" >/dev/null || exit 1
wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{sub(/^worktree /,"");w=$0} $0=="branch "b{print w}')
if [ -n "$wt" ]; then
  case "$wt" in "$HOME"/.t3/worktrees/*|"$repo"-wt/*) git worktree remove --force "$wt" || exit 1;; *) echo "kept $wt: outside the worktree folders";; esac
fi
git branch -qD "$branch" 2>/dev/null
git ls-remote --exit-code origin "refs/heads/$branch" >/dev/null && git push -q origin --delete "$branch"
echo "scrapped $branch${pr:+ (#$pr)}: $reason"
