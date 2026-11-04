#!/usr/bin/env bash
# Report upstream changes without modifying installed checkouts.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d) || exit 0
trap 'rm -rf "$scratch"' EXIT
report() {
  local name=$1 url=$2 base=$3 dir=$scratch/$1
  if ! git clone -q --filter=blob:none "$url" "$dir"; then
    echo "$name: fetch failed"; return
  fi
  if ! git -C "$dir" cat-file -e "$base^{commit}"; then
    echo "$name: recorded commit unavailable ($base)"; return
  fi
  if [ "$name" = pstack ]; then
    echo "pstack: used in place, not copied ($base -> HEAD)"
    git -C "$dir" diff --stat "$base" HEAD -- pstack
    return
  fi
  for skill in full-send full-stop council file-pr babysit-pr takeover modernize leaving-pr-comments sol-loop; do
    echo "$name/$skill (sol-loop is review-loop locally):"
    if git -C "$dir" diff --quiet "$base" HEAD -- "skills/$skill/SKILL.md" "skills/$skill/plan"; then
      echo '  unchanged'
    else
      echo '  changed'
      git -C "$dir" diff --stat "$base" HEAD -- "skills/$skill/SKILL.md" "skills/$skill/plan"
    fi
  done
}
kanzo() {
  local dir=$scratch/kanzo patch=$scratch/kanzo.patch latest
  if ! git clone -q https://github.com/emanuele-em/kanzo "$dir"; then echo "kanzo: fetch failed"; return; fi
  latest=$(git -C "$dir" tag --sort=-v:refname | head -n 1)
  echo "kanzo: based on v0.2.1, latest ${latest:-no tags}"
  # Our changes are whatever kanzo/ holds beyond the upstream tag it was copied from.
  git --git-dir="$dir/.git" --work-tree="$root/kanzo" diff --no-ext-diff --binary --src-prefix=a/ --dst-prefix=b/ v0.2.1 > "$patch"
  if git -C "$dir" checkout -q --detach "$latest" 2>/dev/null && git -C "$dir" apply --check "$patch"; then
    echo "kanzo: our changes apply to $latest"
  else
    echo "kanzo: our changes do not apply to $latest"
  fi
}
report tstack https://github.com/t3dotgg/tstack 1085050
report pstack https://github.com/cursor/plugins 4dd1d05
kanzo
exit 0
