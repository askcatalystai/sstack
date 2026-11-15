#!/usr/bin/env bash
# sid-gate-recover --pause | --after-reboot: repair corrupt state without trusting it.
set -eu
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
source "$here/sid-gate-lib.sh"
gate_repo
case "${1:-}" in
  --pause)
    python3 "$here/gate_lease.py" pause "$gate"
    echo 'Admission paused. Stop cached runners and the health timer, then reboot before repair.'
    ;;
  --after-reboot)
    exec 9>"$gate/lock"; flock 9
    python3 "$here/gate_lease.py" repair "$gate" "$repo"
    echo 'Corrupt state quarantined, abandoned checkouts reclaimed, admission resumed.'
    ;;
  *) echo 'usage: sid-gate-recover --pause | --after-reboot' >&2; exit 1;;
esac
