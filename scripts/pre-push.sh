#!/usr/bin/env bash
# Sstack ships by PR, so refuse a direct push to main, except a change to models.md or rules.md alone
# (/setup-sidstack and the nightly-rules skill do that).
# git push --no-verify bypasses this.
while read -r _ local_sha remote_ref remote_sha; do
  [ "$remote_ref" = refs/heads/main ] || continue
  files=$(git diff --no-renames --name-only "$remote_sha" "$local_sha" 2>/dev/null) || files=
  [ -n "$files" ] && ! printf '%s\n' "$files" | grep -qvxE 'models\.md|rules\.md' && continue
  echo "sstack ships by PR: push a branch and use sid-merge.sh (see README)" >&2
  exit 1
done
exit 0
