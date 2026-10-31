#!/usr/bin/env bash
# Report upstream changes without modifying installed checkouts.
set -u
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
report tstack https://github.com/t3dotgg/tstack 1085050
report pstack https://github.com/cursor/plugins 4dd1d05
exit 0
