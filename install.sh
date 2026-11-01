#!/usr/bin/env bash
# Link sidstack's skills into every harness, put models.md where Claude Code loads rules, and keep pstack linked.
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
done
for dir in "$HOME/.claude/agents" "$HOME/.claude_2/agents" "$HOME/.config/opencode/agents"; do
  mkdir -p "$dir"; [ -d "$P/agents" ] && for a in "$P"/agents/*.md; do ln -sfn "$a" "$dir/$(basename "$a")"; done
done
echo "sidstack: $(ls "$S/skills" | wc -l) skills linked; pstack: $(ls "$P/skills" 2>/dev/null | wc -l) skills linked; models at ~/.claude/rules/sidstack-models.md"
