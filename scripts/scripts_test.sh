#!/usr/bin/env bash
# Real runs against a throwaway repo: a failed gate clears its pass, and API failures stop a merge.
set -u
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; fail=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$t/origin.git"; git clone -q "$t/origin.git" "$t/repo" 2>/dev/null; cd "$t/repo" || exit 1
git checkout -q -b main; mkdir .sidstack; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm one; git push -q origin main; git remote set-head origin main
git checkout -q -b work; echo x > x; git add -A; git commit -qm two; git push -q origin work; head=$(git rev-parse HEAD); stamp=.git/sid-gate/$head
"$here/sid-gate.sh" work >/dev/null; ok "a passing gate stamps the head" "$?" 0; [ -f "$stamp" ]; ok "stamp exists" "$?" 0
git checkout -q main; printf 'exit 1\n' > .sidstack/gate.sh; git add -A; git commit -qm bad; git push -q origin main; git checkout -q work
"$here/sid-gate.sh" work >/dev/null; ok "a failing gate fails" "$?" 1; [ ! -f "$stamp" ]; ok "a failing rerun clears the old pass" "$?" 0
mkdir "$t/bin"; printf '#!/bin/sh\ncase "$1 $2" in "repo view") echo o/r;; *) exit 1;; esac\n' > "$t/bin/gh"; chmod +x "$t/bin/gh"
out=$(PATH="$t/bin:$PATH" "$here/sid-merge.sh" 5 2>&1); rc=$?; ok "an API failure stops the merge" "$rc" 1; case "$out" in *"could not read"*) ok "and says why" 0 0;; *) ok "and says why" 1 0;; esac
exit $fail
