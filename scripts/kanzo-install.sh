#!/usr/bin/env bash
# Build kanzo/ and install it as the board, unless this source is already installed.
# Backs up the board first, because a new build can migrate the database, then restarts the service.
set -eu
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
tree=$(git -C "$root" rev-parse HEAD:kanzo)
bin=$HOME/.local/bin/kanzo
stamp=$HOME/.local/share/sidstack-kanzo.installed
data=${KANZO_HOME:-$HOME/kanzo}
if [ -x "$bin" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$tree" ]; then echo "kanzo: up to date"; exit 0; fi
target=$HOME/.cache/sidstack-kanzo
(cd "$root/kanzo" && CARGO_TARGET_DIR=$target cargo build --release --locked -q)
if [ -f "$data/kanzo.db" ]; then
  backup=$data/kanzo.db.before-${tree:0:8}.bak
  sqlite3 "$data/kanzo.db" ".backup '$backup'"
  [ "$(sqlite3 -readonly "$backup" 'pragma integrity_check')" = ok ] || { echo "kanzo: backup failed, not installing" >&2; exit 1; }
  echo "kanzo: backed up the board to $backup"
fi
mkdir -p "$(dirname "$bin")"
# Rename over the old binary, because the running board keeps it busy.
install -m 755 "$target/release/kanzo" "$bin.new"
mv -f "$bin.new" "$bin"
mkdir -p "$(dirname "$stamp")"
printf '%s\n' "$tree" > "$stamp"
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active -q kanzo.service; then
  systemctl --user restart kanzo.service
fi
echo "kanzo: installed $("$bin" --version)"
