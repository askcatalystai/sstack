#!/usr/bin/env bash
# Real runs against a throwaway repo, with a fake gh: a stale pass never counts, and a merge only follows a fresh read.
set -u
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; fail=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$t/origin.git"; git clone -q "$t/origin.git" "$t/repo" 2>/dev/null; cd "$t/repo" || exit 1
git checkout -q -b main; mkdir .sidstack; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm one; git push -q origin main; git remote set-head origin main
git checkout -q -b work; echo x > x; git add -A; git commit -qm two; git push -q origin work; head=$(git rev-parse HEAD); stamp=.git/sid-gate/work.pass
"$here/sid-gate.sh" work >/dev/null; ok "a passing gate records the head" "$?" 0; [ -f "$stamp" ]; ok "pass exists" "$?" 0
"$here/sid-gate.sh" missing-branch >/dev/null 2>&1; ok "a failed fetch fails" "$?" 1
git checkout -q main; printf 'exit 1\n' > .sidstack/gate.sh; git add -A; git commit -qm bad; git push -q origin main; git checkout -q work
"$here/sid-gate.sh" work >/dev/null; ok "a failing gate fails" "$?" 1; [ ! -f "$stamp" ]; ok "a failing rerun clears the old pass" "$?" 0
git checkout -q main; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm good; git push -q origin main; git checkout -q work
"$here/sid-gate.sh" work >/dev/null; origin_url=$(git remote get-url origin); git remote set-url origin "$t/gone.git"
"$here/sid-gate.sh" work >/dev/null 2>&1; ok "a gate that can't reach origin fails" "$?" 1; [ ! -f "$stamp" ]; ok "and clears the old pass too" "$?" 0; git remote set-url origin "$origin_url"
mkdir "$t/bin"; cat > "$t/bin/gh" <<'F'
#!/usr/bin/env bash
# Fake gh. pr view reads from $T/pr.json until the gate script flips it through $T/after-gate.
case "$1 $2" in
  "repo view") echo o/r;;
  "pr diff") ;;
  "pr comment") echo "$*" >> "$T/comments";;
  "pr merge") echo merged >> "$T/merge-calls"; printf '%s\n' "$*" >> "$T/merge-args";;
  "pr view") case "$*" in *mergeCommit*) echo sha;; *) [ -f "$T/api-down" ] && exit 1; cat "$T/pr.json";; esac;;
  "api graphql") echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}';;
  *) exit 1;;
esac
F
chmod +x "$t/bin/gh"; export T=$t
pr() { printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":%s,"headRefOid":"%s","headRefName":"work","baseRefName":"main","title":"t","body":"## Proof\\n%s 3 passed\\n## Review\\nAstra approved.\\n"}' "$1" "$head" "$head" > "$t/pr.json"; }
merge() { PATH="$t/bin:$PATH" "$here/sid-merge.sh" "$@" 5 >"$t/out" 2>&1; }
merges() { [ -f "$t/merge-calls" ] && wc -l < "$t/merge-calls" | tr -d ' ' || echo 0; }
verdict() { PATH="$t/bin:$PATH" "$here/sid-verdict.sh" 5 "$head" "$@" >"$t/out" 2>&1; }
pr '[]'; verdict MAYBE composer thread-1 "ran it"; ok "only known results count" "$?" 1
mkdir -p .git/sid-gate; touch .git/sid-gate/verdicts; verdict PASS composer thread-1 "ran it"; ok "a verdict it can't record fails" "$?" 1; [ ! -f "$t/comments" ]; ok "and posts nothing" "$?" 0; rm .git/sid-gate/verdicts
verdict PASS composer thread-1 "ran it"; ok "a verdict is recorded" "$?" 0; grep -q "Verdict: PASS by composer" "$t/comments"; ok "and posted on the PR" "$?" 0
pr '[]'; touch "$t/api-down"; merge; ok "an API failure stops the merge" "$?" 1; grep -q "could not read" "$t/out"; ok "and says why" "$?" 0; rm "$t/api-down"
rm -f "$stamp"; pr '[]'; git checkout -q main; printf 'cat "$T/after-gate" > "$T/pr.json"\n' > .sidstack/gate.sh; git add -A; git commit -qm flip; git push -q origin main; git checkout -q work
pr '[{"name":"ci","conclusion":"FAILURE"}]'; cp "$t/pr.json" "$t/after-gate"; pr '[]'; merge; ok "CI going red during the gate stops the merge" "$?" 1; ok "no merge happened" "$(merges)" 0
git checkout -q main; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm ok; git push -q origin main; git checkout -q work; rm -f "$stamp"; pr '[]'; merge --check; ok "a clean PR is ready after a fresh gate" "$?" 0; ok "--check never merges" "$(merges)" 0
verdicts=.git/sid-gate/verdicts/5.tsv; cp "$verdicts" "$t/good-verdicts"
rm "$verdicts"; merge --check; ok "no verdict blocks" "$?" 8; grep -q "no verdict on patch" "$t/out"; ok "and says what to do" "$?" 0
verdict FAIL composer thread-2 "the page is blank"; merge --check; ok "a failing verdict blocks" "$?" 8; grep -q "the page is blank" "$t/out"; ok "and says why" "$?" 0
verdict PASS+NOTES composer thread-3 "fixed and rerun"; merge --check; ok "a later pass on the patch clears it" "$?" 0
sed 's/\t[0-9a-f]\{40\}\t/\tOTHERPATCH\t/' "$t/good-verdicts" > "$verdicts"; merge --check; ok "a verdict on another patch doesn't count" "$?" 8
git checkout -q main; echo z > z; git add -A; git commit -qm z; git push -q origin main; git checkout -q work; cp "$t/good-verdicts" "$verdicts"; git merge -q --no-edit origin/main; git push -q origin work; head=$(git rev-parse HEAD); pr '[]'; merge --check; ok "merging main keeps the verdict" "$?" 0
git checkout -q -b other; echo q > q; git add -A; git commit -qm other; other=$(git rev-parse HEAD); git checkout -q work; PATH="$t/bin:$PATH" "$here/sid-verdict.sh" 5 "$other" PASS composer thread-4 "tested other code" >"$t/out" 2>&1; ok "a verdict on code that isn't the PR's is refused" "$?" 1; grep -q "verify again" "$t/out"; ok "and says so" "$?" 0
echo 'a b' > w; git add -A; git commit -qm spaced; git push -q origin work; head=$(git rev-parse HEAD); pr '[]'; verdict PASS composer thread-1 "ran it"; echo 'ab' > w; git add -A; git commit -qm unspaced; git push -q origin work; head=$(git rev-parse HEAD); pr '[]'; merge --check; ok "a whitespace change needs a new verdict" "$?" 8; verdict PASS composer thread-1 "ran it"; ok "and can get one" "$?" 0
"$here/sid-gate.sh" work >/dev/null; hash=$(sed -n 2p "$stamp" | sed 's/.*sha256 //'); [ -n "$hash" ] && [ "$(cut -d' ' -f1 < <(sha256sum ".git/sid-gate/logs/$head.$(git rev-parse origin/main).log"))" = "$hash" ]; ok "the kept log matches the recorded hash" "$?" 0
git checkout -q main; printf 'touch "$T/gate-ran"\n' > .sidstack/gate.sh; git add -A; git commit -qm count; git push -q origin main; git checkout -q work; "$here/sid-gate.sh" work >/dev/null; rm -f "$t/gate-ran"; sed -i 2d "$stamp"; pr '[]'; merge --check; ok "a stamp with no record reruns the gate" "$?" 0; [ -f "$t/gate-ran" ]; ok "and the gate ran" "$?" 0
pr '[]'; sed -i 's/ 3 passed/ 8 failed/' "$t/pr.json"; merge --check; ok "a Proof reporting failures doesn't block" "$?" 0; grep -q "^proof-failures: .*8 failed" "$t/out"; ok "and it is shown" "$?" 0; grep -q "needs-bot\|bot has not" "$t/out"; ok "and doesn't require the bot" "$?" 1
pr '[]'
cp "$t/pr.json" "$t/clean.json"; sed -i 's/"mergeable":"MERGEABLE"/"mergeable":"UNKNOWN"/' "$t/pr.json"; ( sleep 2; cp "$t/clean.json" "$t/pr.json" ) &
merge; ok "a new PR's UNKNOWN mergeability is waited out, and a clean PR merges" "$?" 0; ok "exactly once" "$(merges)" 1; wait
grep -q "^Gate-Passed: main .* + work .*, log sha256 " "$t/merge-args"; ok "the squash message carries the gate record" "$?" 0
grep -q "^Gate-Passed: " "$t/out"; ok "and the merge prints it" "$?" 0
grep -q "^Verified-By: composer PASS, T3 thread thread-1" "$t/merge-args"; ok "the squash message names the verifier" "$?" 0
exit $fail
