#!/usr/bin/env bash
# Real runs against a throwaway repo, with a fake gh: a stale pass never counts, and a merge only follows a fresh read.
set -u
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; fail=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$t/origin.git"; git clone -q "$t/origin.git" "$t/repo" 2>/dev/null; cd "$t/repo" || exit 1
git checkout -q -b main; mkdir .sidstack; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm one; git push -q origin main; git remote set-head origin main
git checkout -q -b work; echo x > x; git add -A; git commit -qm two; git push -q origin work; head=$(git rev-parse HEAD); stamp=.git/sid-gate/work.pass
"$here/sid-gate.sh" work >/dev/null; ok "a passing gate records the head" "$?" 0; [ -f "$stamp" ]; ok "pass exists" "$?" 0; [ -f .git/sid-gate/work.log ]; ok "plain gate retains its latest log path" "$?" 0
"$here/sid-gate.sh" missing-branch >/dev/null 2>&1; ok "a failed fetch fails" "$?" 1
git checkout -q main; printf 'exit 1\n' > .sidstack/gate.sh; git add -A; git commit -qm bad; git push -q origin main; git checkout -q work
"$here/sid-gate.sh" work >/dev/null; ok "a failing gate fails" "$?" 1; [ ! -f "$stamp" ]; ok "a failing rerun clears the old pass" "$?" 0
git checkout -q main; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm good; git push -q origin main; git checkout -q work
"$here/sid-gate.sh" work >/dev/null; origin_url=$(git remote get-url origin); git remote set-url origin "$t/gone.git"
"$here/sid-gate.sh" work >/dev/null 2>&1; ok "a gate that can't reach origin fails" "$?" 1; [ ! -f "$stamp" ]; ok "and clears the old pass too" "$?" 0; git remote set-url origin "$origin_url"
mkdir "$t/bin"; cat > "$t/bin/gh" <<'F'
#!/usr/bin/env python3
import json, os, signal, subprocess, sys
from pathlib import Path
p = Path(os.environ['T']); args = sys.argv[1:]
def git(*args):
    return subprocess.check_output(['git', *args], text=True).strip()
def data(pr):
    f = p/f'pr-{pr}.json'
    return f if f.exists() else p/'pr.json'
if args[:2] == ['repo', 'view']:
    print('o/r')
elif args[:2] == ['api', '--paginate']:
    if (p/'files-down').exists(): sys.exit(1)
    if (p/'too-many-files').exists(): print('file\n' * 3000, end='')
    elif (p/'files').exists(): print((p/'files').read_text())
elif args[:2] == ['api', 'graphql']:
    if (p/'threads-down').exists(): sys.exit(1)
    nodes = []
    if (p/'open-thread').exists():
        nodes = [dict(id='thread', isResolved=False, comments=dict(nodes=[dict(author=dict(login='chatgpt-codex-connector'), path='x', line=1, originalLine=1, body='P1 fix this')]))]
    print(json.dumps(dict(data=dict(repository=dict(pullRequest=dict(reviewThreads=dict(pageInfo=dict(hasNextPage=False, endCursor=None), nodes=nodes)))))))
elif args[:2] == ['pr', 'comment']:
    with (p/'comments').open('a') as f: f.write(' '.join(args)+'\n')
elif args[:2] == ['pr', 'view']:
    if (p/'api-down').exists(): sys.exit(1)
    pr = args[2]; d = json.loads(data(pr).read_text())
    fields = args[args.index('--json')+1]
    if fields == 'mergeCommit':
        print((p/f'merge-oid-{pr}').read_text().strip()); sys.exit()
    if 'comments' in fields:
        d['comments'] = []
        if (p/'bot-completed').exists():
            state = dict(code_review=dict(commit_sha=d['headRefOid'], status='completed'))
            d['comments'] = [dict(author=dict(login='chatgpt-codex-connector'), body='codex-review-state:v1 '+json.dumps(state)+' -->')]
    if (p/'retargeted').exists() and 'baseRefName' in fields and 'mergeable' not in fields:
        d['baseRefName'] = 'parent'
    print(json.dumps(d))
elif args[:2] == ['pr', 'merge']:
    pr = args[2]; d = json.loads(data(pr).read_text())
    if d['headRefOid'] != args[args.index('--match-head-commit')+1]: sys.exit(1)
    if (p/'refuse-merge').exists(): sys.exit(1)
    flip = p/f'red-on-refuse-{pr}'
    if flip.exists():
        flip.unlink(); d['statusCheckRollup'] = [dict(name='ci', conclusion='FAILURE')]
        data(pr).write_text(json.dumps(d)); sys.exit(1)
    refused = p/f'refuse-count-{pr}'
    if refused.exists() and int(refused.read_text()):
        refused.write_text(str(int(refused.read_text())-1)); sys.exit(1)
    main = git('rev-parse', 'refs/remotes/origin/main')
    # The server uses its live base, not a caller's stale tracking ref.
    main = git('ls-remote', 'origin', 'refs/heads/main').split()[0]
    tree = git('merge-tree', '--write-tree', main, d['headRefOid']).splitlines()[0]
    subject = args[args.index('--subject')+1]; body = args[args.index('--body')+1]
    oid = git('commit-tree', tree, '-p', main, '-m', subject+'\n\n'+body)
    subprocess.run(['git', 'push', '-q', 'origin', oid+':refs/heads/main'], check=True)
    (p/f'merge-oid-{pr}').write_text(oid)
    with (p/'merge-calls').open('a') as f: f.write(pr+'\n')
    with (p/'merge-args').open('a') as f: f.write(' '.join(args)+'\n')
    (p/f'message-{pr}').write_text(subject+'\n\n'+body)
    d['state'] = 'MERGED'; d['mergeCommit'] = dict(oid=oid)
    data(pr).write_text(json.dumps(d))
    if (p/'crash-after-merge').exists():
        (p/'crash-after-merge').unlink()
        os.kill(os.getppid(), signal.SIGKILL)
else:
    sys.exit(1)
F
chmod +x "$t/bin/gh"; export T=$t SID_TRAIN_INLINE=1
pr() { printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":%s,"headRefOid":"%s","headRefName":"work","baseRefName":"main","title":"t","body":"## Proof\\n%s 3 passed\\n## Review\\nAstra approved.\\n"}' "$1" "$head" "$head" > "$t/pr.json"; }
merge() {
  PATH="$t/bin:$PATH" "$here/sid-merge.sh" --no-wait "$@" 5 >"$t/out" 2>&1; local rc=$?
  if [ "$rc" = 0 ] && [ -f .git/sid-gate/train/queue/5.req ]; then
    PATH="$t/bin:$PATH" "$here/sid-train.sh" >>"$t/out" 2>&1
    rc=$(head -n 1 .git/sid-gate/train/result/5)
    tail -n +2 .git/sid-gate/train/result/5 >>"$t/out"
    rm .git/sid-gate/train/result/5
  fi
  return "$rc"
}
merges() { [ -f "$t/merge-calls" ] && wc -l < "$t/merge-calls" | tr -d ' ' || echo 0; }
verdict() { PATH="$t/bin:$PATH" "$here/sid-verdict.sh" 5 "$head" "$@" >"$t/out" 2>&1; }
pr '[]'; verdict MAYBE composer thread-1 "ran it"; ok "only known results count" "$?" 1
mkdir -p .git/sid-gate; touch .git/sid-gate/verdicts; verdict PASS composer thread-1 "ran it"; ok "a verdict it can't record fails" "$?" 1; [ ! -f "$t/comments" ]; ok "and posts nothing" "$?" 0; rm .git/sid-gate/verdicts
verdict PASS composer thread-1 "ran it"; ok "a verdict is recorded" "$?" 0; grep -q "Verdict: PASS by composer" "$t/comments"; ok "and posted on the PR" "$?" 0
pr '[]'; touch "$t/files-down"; merge; ok "a failed file list stops the merge" "$?" 1; grep -q "could not read #5's files" "$t/out"; ok "and says why" "$?" 0; rm "$t/files-down"
pr '[]'; touch "$t/too-many-files"; merge; ok "a file list at the API's limit stops the merge" "$?" 1; grep -q "too many changed files" "$t/out"; ok "and says why" "$?" 0; rm "$t/too-many-files"
pr '[]'; touch "$t/api-down"; merge; ok "an API failure stops the merge" "$?" 1; grep -q "could not read" "$t/out"; ok "and says why" "$?" 0; rm "$t/api-down"
rm -f "$stamp"; pr '[]'; git checkout -q main; printf 'cat "$T/after-gate" > "$T/pr.json"\n' > .sidstack/gate.sh; git add -A; git commit -qm flip; git push -q origin main; git checkout -q work
pr '[{"name":"ci","conclusion":"FAILURE"}]'; cp "$t/pr.json" "$t/after-gate"; pr '[]'; merge; ok "CI going red during the gate stops the merge" "$?" 1; ok "no merge happened" "$(merges)" 0
git checkout -q main; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm ok; git push -q origin main; git checkout -q work; rm -f "$stamp"; pr '[]'; merge --check; ok "a clean PR is ready without a gate" "$?" 0; ok "--check never merges" "$(merges)" 0
verdicts=.git/sid-gate/verdicts/5.tsv; cp "$verdicts" "$t/good-verdicts"
rm "$verdicts"; merge --check; ok "no verdict blocks" "$?" 8; grep -q "no verdict on patch" "$t/out"; ok "and says what to do" "$?" 0
verdict FAIL composer thread-2 "the page is blank"; merge --check; ok "a failing verdict blocks" "$?" 8; grep -q "the page is blank" "$t/out"; ok "and says why" "$?" 0
verdict PASS+NOTES composer thread-3 "fixed and rerun"; merge --check; ok "a later pass on the patch clears it" "$?" 0
sed 's/\t[0-9a-f]\{40\}\t/\tOTHERPATCH\t/' "$t/good-verdicts" > "$verdicts"; merge --check; ok "a verdict on another patch doesn't count" "$?" 8
git checkout -q main; echo z > z; git add -A; git commit -qm z; git push -q origin main; git checkout -q work; cp "$t/good-verdicts" "$verdicts"; git merge -q --no-edit origin/main; git push -q origin work; head=$(git rev-parse HEAD); pr '[]'; merge --check; ok "merging main keeps the verdict" "$?" 0
git checkout -q -b other; echo q > q; git add -A; git commit -qm other; other=$(git rev-parse HEAD); git checkout -q work; PATH="$t/bin:$PATH" "$here/sid-verdict.sh" 5 "$other" PASS composer thread-4 "tested other code" >"$t/out" 2>&1; ok "a verdict on code that isn't the PR's is refused" "$?" 1; grep -q "verify again" "$t/out"; ok "and says so" "$?" 0
moved=$(git commit-tree "HEAD^{tree}" -p "$(git rev-parse origin/main~2)" -m moved); PATH="$t/bin:$PATH" "$here/sid-verdict.sh" 5 "$moved" PASS composer thread-5 "same tree, other parent" >"$t/out" 2>&1; ok "a tested commit with the PR's tree is accepted" "$?" 0
echo 'a b' > w; git add -A; git commit -qm spaced; git push -q origin work; head=$(git rev-parse HEAD); pr '[]'; verdict PASS composer thread-1 "ran it"; echo 'ab' > w; git add -A; git commit -qm unspaced; git push -q origin work; head=$(git rev-parse HEAD); pr '[]'; merge --check; ok "a whitespace change needs a new verdict" "$?" 8; verdict PASS composer thread-1 "ran it"; ok "and can get one" "$?" 0
"$here/sid-gate.sh" work >/dev/null; hash=$(sed -n 2p "$stamp" | sed 's/.*sha256 //'); [ -n "$hash" ] && [ "$(cut -d' ' -f1 < <(sha256sum ".git/sid-gate/logs/$head.$(git rev-parse origin/main).log"))" = "$hash" ]; ok "the kept log matches the recorded hash" "$?" 0
git checkout -q main; printf 'touch "$T/gate-ran"\n' > .sidstack/gate.sh; git add -A; git commit -qm count; git push -q origin main; git checkout -q work; "$here/sid-gate.sh" work >/dev/null; rm -f "$t/gate-ran"; sed -i 2d "$stamp"; pr '[]'; merge --check; ok "--check ignores gate stamps" "$?" 0; [ -f "$t/gate-ran" ]; ok "--check did not run the gate" "$?" 1
pr '[]'; sed -i 's/ 3 passed/ 8 failed/' "$t/pr.json"; merge --check; ok "a Proof reporting failures doesn't block" "$?" 0; grep -q "^proof-failures: .*8 failed" "$t/out"; ok "and it is shown" "$?" 0; grep -q "needs-bot\|bot has not" "$t/out"; ok "and doesn't require the bot" "$?" 1
pr '[]'
git push -q origin "$head~1:refs/heads/parent"; pr '[]'; sed -i 's/"baseRefName":"main"/"baseRefName":"parent"/' "$t/pr.json"; verdict PASS composer thread-6 "ran the stacked PR"; ok "a stacked PR takes a verdict" "$?" 0
merge --check; ok "a stacked PR passes --check" "$?" 0; grep -q "ready, but stacked on parent" "$t/out"; ok "and says it is stacked" "$?" 0
merge; ok "a stacked PR doesn't merge" "$?" 1; grep -q "land that first" "$t/out"; ok "and says what to do" "$?" 0; ok "no merge happened" "$(merges)" 0
pr '[]'
touch "$t/retargeted"; merge; ok "a retarget just before merging stops it" "$?" 1; grep -q "base changed" "$t/out"; ok "for that reason" "$?" 0; ok "no merge happened" "$(merges)" 0; rm "$t/retargeted"
cp "$t/pr.json" "$t/clean.json"; sed -i 's/"mergeable":"MERGEABLE"/"mergeable":"UNKNOWN"/' "$t/pr.json"; ( sleep 2; cp "$t/clean.json" "$t/pr.json" ) &
merge; ok "a new PR's UNKNOWN mergeability is waited out, and a clean PR merges" "$?" 0; ok "exactly once" "$(merges)" 1; wait
grep -q "^Gate-Passed: train .*, main .* + #5, lane full, log sha256 " "$t/merge-args"; ok "the squash message carries the gate record" "$?" 0
grep -q "^Gate-Passed: " "$t/out"; ok "and the merge prints it" "$?" 0
grep -q "^Verified-By: composer PASS, T3 thread thread-1" "$t/merge-args"; ok "the squash message names the verifier" "$?" 0
# Each train case has its own real origin. Inspect commits and outcomes, not implementation text.
export PATH="$t/bin:$PATH"
setup_train() {
  export T=$t/$1; mkdir -p "$T"
  git init -q --bare -b main "$T/origin.git"; git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  cd "$T/repo" || exit 1; mkdir .sidstack
  cat > .sidstack/gate.sh <<'G'
echo gate >> "$T/gates"
echo "${SID_LANE:-unset}" >> "$T/lane-input"
git diff HEAD --name-only | tr '\n' ' ' >> "$T/gate-diffs"
echo >> "$T/gate-diffs"
[ ! -f "$T/reported-lane" ] || echo "gate: lane $(cat "$T/reported-lane")"
if [ -f "$T/block-health" ] && [ "$SID_LANE" = full ]; then
  touch "$T/health-started"; sleep 30; touch "$T/health-survived"
fi
if [ -f "$T/drift" ]; then
  old=$(git --git-dir="$T/origin.git" rev-parse main)
  if [ -f "$T/drift-once" ]; then
    new=$(cat "$T/drift-once"); rm "$T/drift" "$T/drift-once"
  else
    new=$(git --git-dir="$T/origin.git" commit-tree "$old^{tree}" -p "$old" -m outside-push)
  fi
  git --git-dir="$T/origin.git" update-ref refs/heads/main "$new"
fi
if [ -f "$T/block-train" ]; then
  touch "$T/train-started"
  while [ ! -f "$T/release-train" ]; do sleep .05; done
fi
[ ! -f "$T/flip-ci" ] || cp "$T/red.json" "$T/pr-11.json"
[ ! -f bad ] && [ ! -f "$T/always-fail" ] || { echo failure-sentinel; exit 1; }
G
  git add -A; git commit -qm initial; git push -q origin main; git remote set-head origin main
  q=.git/sid-gate/train; health=.git/sid-gate/health
}
add_pr() {
  local n=$1 file=$2 value=${3:-x}
  git checkout -q -B "work$n" origin/main; echo "$value" > "$file"; git add -A
  git commit -qm "change $n" -m 'Agent: writer'; git push -q origin "work$n"
  local h; h=$(git rev-parse HEAD)
  python3 - "$T/pr-$n.json" "$n" "$h" <<'PY'
import json, sys
p, n, h = sys.argv[1:]
json.dump(dict(state='OPEN', isDraft=False, mergeable='MERGEABLE', reviewDecision='', statusCheckRollup=[], headRefOid=h, headRefName='work'+n, baseRefName='main', title='change '+n, body=f'## Proof\n{h} 3 passed\n## Review\nAstra approved.\n'), open(p, 'w'))
PY
  "$here/sid-verdict.sh" "$n" "$h" PASS composer thread-1 'ran tests' >/dev/null
  git checkout -q main
}
queue_pr() { "$here/sid-merge.sh" --no-wait "$1" > "$T/out" 2>&1; }
run_train() { "$here/sid-train.sh" > "$T/runner-out" 2>&1; }
count_gates() { if [ -f "$T/gates" ]; then wc -l < "$T/gates" | tr -d ' '; else echo 0; fi; }
code() { head -n 1 "$q/result/$1"; }
setup_train batch
add_pr 11 a; add_pr 12 b; echo fast > "$T/reported-lane"; git worktree add -q "$T/worker" work11
"$here/sid-mode.sh" set lane full --note 'operator full test'; queue_pr 11; queue_pr 12; run_train
ok "two members gate once" "$(count_gates)" 1
ok "gate sees union as a diff against HEAD" "$(cat "$T/gate-diffs")" 'a b '

ok "first member merged" "$(code 11)" 0; ok "second member merged" "$(code 12)" 0
ok "merges follow queue order" "$(tr '\n' ' ' < "$T/merge-calls")" '11 12 '
for n in 11 12; do
  grep -Eq '^Gate-Passed: train [0-9]+, main [a-f0-9]{8} \+ #11 #12, lane fast, log sha256 [a-f0-9]{64}$' "$T/message-$n"
  ok "#$n squash carries both members and the reported lane" "$?" 0
  grep -q '^Verified-By: composer PASS, T3 thread thread-1' "$T/message-$n"; ok "#$n preserves verifier" "$?" 0
  grep -q '^Agent: writer' "$T/message-$n"; ok "#$n preserves branch trailers" "$?" 0
done
[ ! -d "$T/worker" ]; ok "merged member worktree is removed" "$?" 0
git show-ref --verify --quiet refs/heads/work11; ok "merged member local branch is removed" "$?" 1
git ls-remote --exit-code origin refs/heads/work11 >/dev/null; ok "merged member remote branch is removed" "$?" 2
ok "mode SID_LANE reaches gate" "$(cat "$T/lane-input")" full
sha=$(git rev-parse origin/main); ok "matching merged tree records health" "$(head -n 1 "$health/$sha")" 'pass fast'
log=$(sed -n 2p "$health/$sha"); digest=$(sha256sum "$log" | cut -d' ' -f1)
grep -q "log sha256 $digest$" "$T/message-11"; ok "train trailer authenticates kept gate log" "$?" 0
"$here/sid-health.sh" > "$T/health-out"; ok "fast health is checked in full" "$(count_gates)" 2
# The gate reports what it actually ran; stop overriding the health lane here.
rm "$T/reported-lane"; "$here/sid-health.sh" > "$T/health-out"; ok "health with no lane reports full" "$(head -n 1 "$health/$sha")" 'pass full'
before=$(count_gates); "$here/sid-health.sh" > "$T/health-out"; ok "full passing health skips" "$(count_gates)" "$before"
python3 - "$q/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); sys.exit(not (s['phase'] == 'idle' and s['members'] == [] and len(s['main']) == 40))
PY
ok "drained runner publishes idle" "$?" 0
ok "batch history records a merged train" "$(cut -f6 "$q/history.tsv")" merged
setup_train split
add_pr 11 good; add_pr 12 bad; queue_pr 11; queue_pr 12; run_train
ok "failed pair splits into two single gates" "$(count_gates)" 3
ok "passing half merges" "$(code 11)" 0; ok "bad half fails" "$(code 12)" 1
ok "bad member never merged" "$(cat "$T/merge-calls")" 11
grep -q failure-sentinel "$q/result/12"; ok "failure includes log tail" "$?" 0
grep -q 'gate FAILED: .*sid-gate/logs/' "$q/result/12"; ok "failure includes kept log" "$?" 0
setup_train conflicts
add_pr 11 shared first; add_pr 12 shared second; queue_pr 11; queue_pr 12; run_train
ok "earlier member of conflicting pair merges" "$(code 11)" 0
ok "conflict deferred until earlier member lands then reported against main" "$(code 12)" 3
grep -q 'conflicts with main: merge origin/main into work12' "$q/result/12"; ok "conflict gives repair instruction" "$?" 0
ok "conflicting member is not gated" "$(count_gates)" 1
setup_train main-conflict
add_pr 11 shared branch; queue_pr 11
git checkout -q main; echo main > shared; git add -A; git commit -qm main; git push -q origin main
run_train; ok "conflict with default exits 3" "$(code 11)" 3; ok "main conflict skips gate" "$(count_gates)" 0
setup_train changed-head
add_pr 11 a; queue_pr 11
git checkout -q work11; echo changed > a; git commit -qam changed; git push -q origin work11; git checkout -q main
run_train; ok "head changed after queueing exits 1" "$(code 11)" 1
[ ! -f "$T/merge-calls" ]; ok "changed head never merges" "$?" 0
# Model a runner dying after GitHub accepted the merge, before it saved the result.
setup_train recovered-merge
add_pr 11 a; queue_pr 11; git worktree add -q "$T/worker" work11
touch "$T/crash-after-merge"; run_train
[ ! -f "$q/result/11" ]; ok "crashed runner left no merge result" "$?" 0
run_train; ok "already merged queued head recovers success" "$(code 11)" 0
grep -Fq "merged #11: $(cat "$T/merge-oid-11")" "$q/result/11"; ok "recovery reports the merge commit" "$?" 0
grep -qi 'already merged' "$q/result/11"; ok "recovery explains it found the PR already merged" "$?" 0
ok "recovery does not merge twice" "$(cat "$T/merge-calls")" 11
ok "recovery does not regate" "$(count_gates)" 1
[ ! -d "$T/worker" ]; ok "recovery removes merged worktree" "$?" 0
git show-ref --verify --quiet refs/heads/work11; ok "recovery removes local branch" "$?" 1
git ls-remote --exit-code origin refs/heads/work11 >/dev/null; ok "recovery removes remote branch" "$?" 2
setup_train merged-other-head
add_pr 11 a; queue_pr 11
python3 - "$T/pr-11.json" <<'PYTHON'
import json, sys
p = json.load(open(sys.argv[1])); p.update(state='MERGED', headRefOid='0'*40, mergeCommit=dict(oid='1'*40))
json.dump(p, open(sys.argv[1], 'w'))
PYTHON
run_train; ok "merged PR with another head still fails" "$(code 11)" 1
git show-ref --verify --quiet refs/heads/work11; ok "other merged head leaves branch alone" "$?" 0
push_fix() {
  git checkout -q work11; echo fixed > a; git commit -qam fix; git push -q origin work11
  local h; h=$(git rev-parse HEAD)
  python3 - "$T/pr-11.json" "$h" <<'PYTHON'
import json, sys
p = json.load(open(sys.argv[1])); p['headRefOid'] = sys.argv[2]
p['body'] = f'## Proof\n{sys.argv[2]} 3 passed\n## Review\nAstra approved.\n'
json.dump(p, open(sys.argv[1], 'w'))
PYTHON
  "$here/sid-verdict.sh" 11 "$h" PASS composer thread-1 'tested fix' >/dev/null
  git checkout -q main
}
setup_train requeued-head
add_pr 11 a; queue_pr 11; push_fix; queue_pr 11
ok "updated unclaimed PR requeues successfully" "$?" 0
run_train; ok "requeued head merges successfully" "$(code 11)" 0
ok "requeued head gates once" "$(count_gates)" 1
ok "requeued head merges once" "$(cat "$T/merge-calls")" 11
ok "merge includes the pushed fix" "$(git show origin/main:a)" fixed
setup_train claimed-head
add_pr 11 a; queue_pr 11; touch "$T/block-train"
"$here/sid-train.sh" > "$T/runner-out" 2>&1 & rp=$!
for ((j=0; j<100; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
[ -f "$T/train-started" ]; ok "claimed head reached gating" "$?" 0
push_fix; queue_pr 11; ok "requeue of claimed head returns" "$?" 0
touch "$T/release-train"; wait "$rp"
ok "claimed request retains original head and refuses changed PR" "$(code 11)" 1
[ ! -f "$T/merge-calls" ]; ok "claimed request never merges an ungated fix" "$?" 0
setup_train drift
add_pr 11 a; queue_pr 11
# Push a real tree change during the gate; the next gate must include it.
git checkout -q -b outside origin/main; echo outside > outside; git add -A; git commit -qm outside; git push -q origin outside
git rev-parse HEAD > "$T/drift-once"; touch "$T/drift"; git checkout -q main
run_train; ok "main drift requires a second gate" "$(count_gates)" 2; ok "regated PR merges" "$(code 11)" 0
git show origin/main:outside > /dev/null; ok "outside push survives merge" "$?" 0
setup_train endless-drift
add_pr 11 a; queue_pr 11; touch "$T/drift"; run_train
ok "main drift retries are bounded" "$(count_gates)" 3; ok "endless drift fails the member" "$(code 11)" 1
[ ! -f "$T/merge-calls" ]; ok "no merge onto untested main" "$?" 0
setup_train check-cancel
add_pr 11 a
"$here/sid-merge.sh" --check 11 > "$T/out"; ok "check passes readiness" "$?" 0
ok "check never gates" "$(count_gates)" 0; [ ! -f "$q/queue/11.req" ]; ok "check never queues" "$?" 0
queue_pr 11; "$here/sid-merge.sh" --cancel 11 > "$T/out"; grep -q 'cancelled #11' "$T/out"; ok "cancel withdraws request" "$?" 0
run_train; ok "cancelled request never gates" "$(count_gates)" 0; [ ! -f "$T/merge-calls" ]; ok "cancelled request never merges" "$?" 0
setup_train bot-mode
add_pr 11 a; echo auth/login.ts > "$T/files"
queue_pr 11; ok "bot auto still requires risky path review" "$?" 7
"$here/sid-mode.sh" set bot off --note 'Sid waived for recovery'; touch "$T/open-thread"; queue_pr 11; ok "bot off waives risky paths and open threads" "$?" 0
run_train; ok "waived PR merges" "$(code 11)" 0
grep -q '^Bot: waived by mode (Sid waived for recovery)' "$T/message-11"; ok "squash carries mode waiver" "$?" 0
setup_train health-red
"$here/sid-health.sh" > "$T/out"; ok "missing health runs gate" "$(count_gates)" 1
touch "$T/always-fail"; sha=$(git rev-parse origin/main); rm "$health/$sha"; "$here/sid-health.sh" > "$T/out"
ok "failing health exits 1" "$?" 1; ok "failing full health recorded" "$(head -n 1 "$health/$sha")" 'fail full'
before=$(count_gates); "$here/sid-health.sh" > "$T/out"; ok "known full failure skips" "$(count_gates)" "$before"
add_pr 11 bad; queue_pr 11; run_train; ok "known red main makes single failure exit 4" "$(code 11)" 4
grep -Fq "main is red at ${sha:0:8}, see $(sed -n 2p "$health/$sha")" "$q/result/11"; ok "red result names health log" "$?" 0
setup_train health-priority
add_pr 11 a; queue_pr 11; "$here/sid-health.sh" > "$T/out"; ok "health skips queued work" "$(count_gates)" 0
"$here/sid-merge.sh" --cancel 11 >/dev/null
( flock 9; "$here/sid-health.sh" > "$T/out" ) 9>.git/sid-gate/lock
ok "health skips a busy gate lock" "$(count_gates)" 0
touch "$T/block-health"; "$here/sid-health.sh" > "$T/out" 2>&1 & hp=$!
for ((j=0; j<100; j++)); do [ -f "$T/health-started" ] && break; sleep .05; done
[ -f "$T/health-started" ]; ok "health gate began" "$?" 0
queue_pr 11; "$here/sid-mode.sh" set lane fast; run_train; wait "$hp" 2>/dev/null
ok "train preempts health and merges" "$(code 11)" 0
[ ! -f "$T/health-survived" ]; ok "preemption kills health's child process group" "$?" 0
setup_train freshness
add_pr 11 a; queue_pr 11
python3 - "$T/pr-11.json" "$T/red.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); p['statusCheckRollup'] = [dict(name='ci', conclusion='FAILURE')]; json.dump(p, open(sys.argv[2], 'w'))
PY
touch "$T/flip-ci"; run_train; ok "CI turning red during gate stops merge" "$(code 11)" 1
[ ! -f "$T/merge-calls" ]; ok "fresh readiness refusal never merges" "$?" 0
setup_train retries
add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
# Refuse the second merge twice to model GitHub's delayed mergeability after the first squash.
echo 2 > "$T/refuse-count-12"; run_train
ok "temporary merge refusals do not regate" "$(count_gates)" 1
ok "second member merges after refused attempts" "$(code 12)" 0
setup_train refused-exhausted
add_pr 11 a; queue_pr 11; echo 4 > "$T/refuse-count-11"; run_train
ok "exhausted merge refusals exit 1" "$(code 11)" 1
[ ! -f "$T/merge-calls" ]; ok "refused member is never reported merged" "$?" 0
ok "refused member retries without another gate" "$(count_gates)" 1
setup_train refused-freshness
add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
touch "$T/red-on-refuse-12"; run_train
ok "CI turning red after a refused attempt stops its retry" "$(code 12)" 1
ok "refused retry never merges the now-red member" "$(cat "$T/merge-calls")" 11
setup_train bot-rules
add_pr 11 a; touch "$T/open-thread"; queue_pr 11; ok "auto bot mode blocks open findings" "$?" 6
rm "$T/open-thread"; touch "$T/threads-down"; queue_pr 11; ok "thread API failure stays fail-closed" "$?" 7
rm "$T/threads-down"; "$here/sid-merge.sh" --bot --no-wait 11 > "$T/out" 2>&1; ok "explicit bot still requires a head review" "$?" 7
touch "$T/bot-completed"; "$here/sid-merge.sh" --bot --no-wait 11 > "$T/out" 2>&1; ok "completed head bot review permits queueing" "$?" 0
run_train; ok "explicit bot member merges" "$(code 11)" 0
setup_train cap
add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
SID_TRAIN_MAX=1 run_train; ok "train member cap is respected" "$(count_gates)" 2
setup_train hook
cat > .sidstack/after-merge.sh <<'G'
#!/usr/bin/env bash
pwd > "$T/hook-pwd"
printf '%s\n' "$PATH" > "$T/hook-path"
git rev-parse HEAD > "$T/hook-head"
echo hook-started
while [ ! -f "$T/release-hook" ]; do sleep .05; done
echo hook-finished
exit 1
G
chmod +x .sidstack/after-merge.sh; git add -A; git commit -qm hook; git push -q origin main
add_pr 11 a; queue_pr 11; run_train
for ((j=0; j<100; j++)); do [ -f "$T/hook-head" ] && break; sleep .05; done
ok "detached hook keeps runner PATH" "$(cat "$T/hook-path")" "$PATH"
ok "hook uses the new main snapshot" "$(cat "$T/hook-head")" "$(git rev-parse origin/main)"
[ -d "$(cat "$T/hook-pwd")" ]; ok "hook has an independent worktree" "$?" 0
[ ! -f "$T/release-hook" ]; ok "train completed while hook was waiting" "$?" 0
echo release > "$T/release-hook"
for ((j=0; j<100; j++)); do [ ! -d "$(cat "$T/hook-pwd")" ] && break; sleep .05; done
grep -q hook-finished "$q/after-merge.log"; ok "hook output is logged" "$?" 0
ok "failing hook does not fail merged member" "$(code 11)" 0
setup_train detached
add_pr 11 a
SID_TRAIN_INLINE=0 "$here/sid-merge.sh" 11 > "$T/out" 2>&1
ok "fallback runner completes waiting caller" "$?" 0
grep -q 'merged #11:' "$T/out"; ok "waiting caller prints result" "$?" 0
[ ! -f "$q/result/11" ]; ok "waiting caller consumes result" "$?" 0
setup_train service
add_pr 11 a
cat > "$t/bin/systemd-run" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/service-args"
# A transient unit starts with the manager's environment, not the caller's PATH.
PATH=/usr/bin:/bin; HOME=/nonexistent
for arg in "$@"; do
  case "$arg" in
    --working-directory=*) cd "${arg#*=}" || exit 1;;
    --setenv=*) export "${arg#*=}";;
  esac
done
printf '%s\n' "$PATH" "$HOME" > "$T/service-env"
exec setsid "${!#}" </dev/null >>"$T/service-log" 2>&1 &
S
chmod +x "$t/bin/systemd-run"
( unset SID_TRAIN_INLINE; "$here/sid-merge.sh" --no-wait 11 > "$T/out" 2>&1 )
ok "service startup queues and returns" "$?" 0
for ((j=0; j<200; j++)); do [ -f "$q/result/11" ] && break; sleep .05; done
ok "service runner outlives enqueue caller" "$(code 11)" 0
ok "service receives caller PATH" "$(sed -n 1p "$T/service-env")" "$PATH"
ok "service receives caller HOME" "$(sed -n 2p "$T/service-env")" "$HOME"
grep -Eq -- '--user --collect --unit=sid-train-[0-9a-f]+ --working-directory=' "$T/service-args"; ok "transient service is named for repo" "$?" 0
rm "$t/bin/systemd-run"
setup_train active-cancel
add_pr 11 a; queue_pr 11; touch "$T/block-train"
"$here/sid-train.sh" > "$T/runner-out" 2>&1 & rp=$!
for ((j=0; j<100; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
[ -f "$T/train-started" ]; ok "train member reached gating" "$?" 0
"$here/sid-merge.sh" --cancel 11 > "$T/out"
grep -q 'has started gating; cannot cancel' "$T/out"; ok "cancel cannot withdraw active member" "$?" 0
touch "$T/release-train"; wait "$rp"; ok "uncancelled active member merges" "$(code 11)" 0
setup_train mode
for pair in 'lane fast' 'bot off' 'coder claude' 'ui sol' 'reviewers none'; do
  read -r key value <<< "$pair"; "$here/sid-mode.sh" set "$key" "$value" --note 'operator test'
  ok "mode $key round-trips" "$("$here/sid-mode.sh" get "$key")" "$value"
done
"$here/sid-mode.sh" > "$T/out"; grep -q 'lane: .*operator test' "$T/out"; ok "mode display includes time and reason" "$?" 0
"$here/sid-mode.sh" set surprise fast >/dev/null 2>&1; ok "mode refuses unknown key" "$?" 1
"$here/sid-mode.sh" set lane turbo >/dev/null 2>&1; ok "mode refuses unknown value" "$?" 1
"$here/sid-mode.sh" get surprise >/dev/null 2>&1; ok "mode get refuses unknown key" "$?" 1
git init -q --bare -b main "$t/hook-origin.git"; git clone -q "$t/hook-origin.git" "$t/hook-repo" 2>/dev/null; cd "$t/hook-repo" || exit 1; git checkout -q -b main; echo a > a; git add -A; git commit -qm a; ln -s "$here/pre-push.sh" .git/hooks/pre-push
git push -q origin main 2>/dev/null; ok "the hook refuses a direct push to main" "$?" 1; git ls-remote --exit-code origin refs/heads/main >/dev/null; ok "and main doesn't move" "$?" 2
git push -q origin HEAD:refs/heads/work 2>/dev/null; ok "a branch still pushes" "$?" 0
git push -q --no-verify origin main 2>/dev/null; ok "--no-verify bypasses it" "$?" 0
echo m > models.md; git add -A; git commit -qm models; git push -q origin main 2>/dev/null; ok "a models.md change alone can push" "$?" 0
echo n > models.md; echo b > b; git add -A; git commit -qm both; git push -q origin main 2>/dev/null; ok "models.md with anything else can't" "$?" 1
git reset -q --hard HEAD~1; echo r > rules.md; git add -A; git commit -qm rules; git push -q origin main 2>/dev/null; ok "a rules.md change alone can push" "$?" 0
echo n > models.md; echo s > rules.md; git add -A; git commit -qm two; git push -q origin main 2>/dev/null; ok "models.md and rules.md together can push" "$?" 0
echo t > rules.md; echo b > b; git add -A; git commit -qm both; git push -q origin main 2>/dev/null; ok "rules.md with anything else can't" "$?" 1
git reset -q --hard HEAD~1; git rm -q models.md; git commit -qm gone; git push -q --no-verify origin main; echo code > code; git add -A; git commit -qm code; git push -q --no-verify origin main; git mv code models.md; git commit -qm renamed; git push -q origin main 2>/dev/null; ok "a rename into models.md can't hide a deleted file" "$?" 1
git reset -q --hard HEAD~1; git push -q origin --delete main 2>/dev/null; ok "deleting main is refused" "$?" 1
exit $fail
