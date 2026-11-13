#!/usr/bin/env bash
# Link sidstack's skills into every harness, put models.md and rules.md where each harness loads them, and keep pstack linked.
# Idempotent: rerun after any change. A sidstack skill replaces a tstack link of the same name.
set -eu
S=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
P=${PSTACK:-$HOME/.local/share/pstack-src/pstack}

link_skills() { # <dir>
  mkdir -p "$1"
  for skill in "$S"/skills/*/; do
    name=$(basename "$skill"); target="$1/$name"
    if [ -e "$target" ] && [ ! -L "$target" ]; then echo "skip $target (not a link; yours)"; continue; fi
    ln -sfn "${skill%/}" "$target"
  done
  # sol-loop is now review-loop; drop the old tstack link.
  [ -L "$1/sol-loop" ] && rm "$1/sol-loop"
  if [ -d "$P/skills" ]; then for skill in "$P"/skills/*/; do
    target="$1/$(basename "$skill")"; [ -e "$target" ] && [ ! -L "$target" ] && continue
    ln -sfn "${skill%/}" "$target"
  done; fi
}

for dir in "$HOME/.claude/skills" "$HOME/.claude_2/skills" "$HOME/.codex/skills" "$HOME/.config/opencode/skills"; do
  link_skills "$dir"
done
for dir in "$HOME/.claude/rules" "$HOME/.claude_2/rules"; do
  mkdir -p "$dir"; ln -sfn "$S/models.md" "$dir/sidstack-models.md"
  # pstack reads its per-role models from this rule; generate it so models.md stays the one source.
  python3 "$S/scripts/pstack_models.py" "$S/models.md" "$dir/pstack-models.md"
  ln -sfn "$S/rules.md" "$dir/sidstack-rules.md"
done
# Codex and OpenCode read one global AGENTS.md. Sol, Astra and Terra run there, so the operator's rules go in as that file.
for file in "$HOME/.codex/AGENTS.md" "$HOME/.config/opencode/AGENTS.md"; do
  mkdir -p "$(dirname "$file")"
  if [ -e "$file" ] && [ ! -L "$file" ]; then mv "$file" "$file.before-sidstack"; echo "kept your old $file as $file.before-sidstack"; fi
  ln -sfn "$S/rules.md" "$file"
done
for dir in "$HOME/.claude/agents" "$HOME/.claude_2/agents" "$HOME/.config/opencode/agents"; do
  mkdir -p "$dir"; [ -d "$P/agents" ] && for a in "$P"/agents/*.md; do ln -sfn "$a" "$dir/$(basename "$a")"; done
done
# Sstack ships by PR; the hook refuses a direct push to main.
if hooks=$(git -C "$S" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  mkdir -p "$hooks/hooks"; ln -sfn "$S/scripts/pre-push.sh" "$hooks/hooks/pre-push"
fi
# The board is built from kanzo/ here, only when that source has changed.
if command -v cargo >/dev/null 2>&1; then "$S/scripts/kanzo-install.sh" || echo "kanzo: install failed; rerun install.sh"; else echo "skipped kanzo build: no cargo"; fi
# Kanzo card tags refresh on a timer.
if command -v systemctl >/dev/null 2>&1 && command -v kanzo >/dev/null 2>&1; then
  mkdir -p "$HOME/.config/systemd/user"
  cp "$S"/systemd/sid-card.service "$S"/systemd/sid-card.timer "$HOME/.config/systemd/user/"
  systemctl --user daemon-reload && systemctl --user enable --now sid-card.timer >/dev/null 2>&1
fi
echo "sidstack: $(ls "$S/skills" | wc -l) skills linked; pstack: $(ls "$P/skills" 2>/dev/null | wc -l) skills linked; models at ~/.claude/rules/sidstack-models.md"
