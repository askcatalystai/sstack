#!/usr/bin/env bash
# sid-preview <worktree|main>: serve that code on the local UI at :5173, the only port sign-in works on.
# One at a time: UI checks take turns. "main" refreshes the local-preview checkout to the latest origin/main.
set -u
target=${1:?usage: sid-preview <worktree|main>}
repo=$HOME/openec; preview=$HOME/openec-wt/local-preview
if [ "$target" = main ]; then
  git -C "$preview" fetch -q origin main && git -C "$preview" checkout -q --detach origin/main || exit 1
  target=$preview
  ( cd "$preview/app" && pnpm install --frozen-lockfile --prefer-offline >/dev/null && pnpm --config.verify-deps-before-run=false build:packages >/dev/null ) || exit 1
elif [ "$target" != "$preview" ]; then
  [ -d "$target/app/node_modules" ] || { echo "$target has no dependencies installed"; exit 1; }
  [ -e "$target/app/.env.local" ] || ln -s "$preview/app/.env.local" "$target/app/.env.local"
fi
systemctl --user stop oe-ui 2>/dev/null
systemd-run --user --unit=oe-ui --working-directory="$target/app" --setenv=PATH="$PATH" --setenv=HOME="$HOME" --setenv=PORT=5173 pnpm --config.verify-deps-before-run=false dev:ui >/dev/null || exit 1
for _ in $(seq 1 60); do
  curl -s -o /dev/null --max-time 2 http://localhost:5173/ && { echo "serving $target on http://localhost:5173"; exit 0; }
  sleep 2
done
echo "UI didn't come up: journalctl --user -u oe-ui"; exit 1
