#!/usr/bin/env bash
# Sstack ships by PR, so refuse a direct push to main, except a change to models.md alone (/setup-sidstack does that).
# git push --no-verify bypasses this.
while read -r _ local_sha remote_ref remote_sha; do
  [ "$remote_ref" = refs/heads/main ] || continue
  files=$(git diff --no-renames --name-only "$remote_sha" "$local_sha" 2>/dev/null) || files=
  [ "$files" = models.md ] && continue
  echo "sstack ships by PR: push a branch and use sid-merge.sh (see README)" >&2
  exit 1
done
exit 0
