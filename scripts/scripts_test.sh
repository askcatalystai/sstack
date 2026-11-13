#!/usr/bin/env bash
# Real runs against a throwaway repo, with a fake gh: a stale pass never counts, and a merge only follows a fresh read.
set -u
# Do not inherit the harness service identity; systemd cases opt in with fakes.
unset INVOCATION_ID
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
mkdir "$t/bin"
# Every systemd interaction is stubbed, including on hosts with a working manager.
printf '#!/usr/bin/env bash\nexit 1\n' > "$t/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$t/bin/systemd-run"
chmod +x "$t/bin/systemctl" "$t/bin/systemd-run"
cat > "$t/bin/gh" <<'F'
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
elif args[:2] == ['pr', 'view']:
    if (p/'api-down').exists(): sys.exit(1)
    pr = args[2]; d = json.loads(data(pr).read_text()); d.setdefault('autoMergeRequest', None)
    fields = args[args.index('--json')+1]
    if fields == 'autoMergeRequest' and (p/'auto-read-down').exists(): sys.exit(1)
    if fields == 'mergeCommit':
        print((p/f'merge-oid-{pr}').read_text().strip()); sys.exit()
    if (p/f'post-api-down-{pr}').exists() and d['state'] == 'MERGED': sys.exit(1)
    if (p/'retargeted').exists() and 'baseRefName' in fields and 'mergeable' not in fields:
        d['baseRefName'] = 'parent'
    print(json.dumps(d))
elif args[:2] == ['pr', 'merge']:
    pr = args[2]; d = json.loads(data(pr).read_text()); d.setdefault('autoMergeRequest', None)
    if '--disable-auto' in args:
        if (p/'disable-fails').exists(): sys.exit(1)
        d['autoMergeRequest'] = None; data(pr).write_text(json.dumps(d))
        (p/f'auto-disabled-{pr}').touch(); sys.exit(0)
    if d['headRefOid'] != args[args.index('--match-head-commit')+1]: sys.exit(1)
    if (p/'refuse-merge').exists():
        if (p/'arm-on-refuse').exists():
            d['autoMergeRequest'] = dict(enabledAt='now'); data(pr).write_text(json.dumps(d))
        sys.exit(1)
    if (p/f'queue-only-{pr}').exists():
        d['autoMergeRequest'] = dict(enabledAt='now'); data(pr).write_text(json.dumps(d)); sys.exit(0)
    drift = p/f'drift-on-merge-{pr}'
    if drift.exists():
        subprocess.run(['git', '--git-dir='+str(p/'origin.git'), 'update-ref', 'refs/heads/main', drift.read_text().strip()], check=True)
        drift.unlink()
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
    if (p/f'same-tree-drift-{pr}').exists():
        main = git('commit-tree', main+'^{tree}', '-p', main, '-m', 'outside empty push')
        subprocess.run(['git', 'push', '-q', 'origin', main+':refs/heads/main'], check=True)
    # Model server settings, independent of the client's hostile config.
    tree = subprocess.check_output(['git', '-c', 'merge.renames=true', '-c', 'merge.directoryRenames=conflict', '-c', 'merge.renameLimit=0', 'merge-tree', '--write-tree', main, d['headRefOid']], env=dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null'), text=True).splitlines()[0]
    if (p/f'wrong-tree-{pr}').exists(): tree = git('rev-parse', main+'^{tree}')
    subject = args[args.index('--subject')+1]; body = args[args.index('--body')+1]
    oid = git('commit-tree', tree, '-p', main, '-m', subject+'\n\n'+body)
    subprocess.run(['git', 'push', '-q', 'origin', oid+':refs/heads/main'], check=True)
    (p/f'merge-oid-{pr}').write_text(oid)
    with (p/'merge-calls').open('a') as f: f.write(pr+'\n')
    with (p/'merge-args').open('a') as f: f.write(' '.join(args)+'\n')
    (p/f'message-{pr}').write_text(subject+'\n\n'+body)
    d['state'] = 'MERGED'; d['mergeCommit'] = dict(oid=oid)
    if (p/f'unconfirmed-{pr}').exists():
        d.update(json.loads((p/f'unconfirmed-{pr}').read_text()))
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
pr '[]'; pr '[]'; touch "$t/api-down"; merge; ok "an API failure stops the merge" "$?" 1; grep -q "could not read" "$t/out"; ok "and says why" "$?" 0; rm "$t/api-down"
rm -f "$stamp"; pr '[]'; git checkout -q main; printf 'cat "$T/after-gate" > "$T/pr.json"\n' > .sidstack/gate.sh; git add -A; git commit -qm flip; git push -q origin main; git checkout -q work
pr '[{"name":"ci","conclusion":"FAILURE"}]'; cp "$t/pr.json" "$t/after-gate"; pr '[]'; merge; ok "CI going red during the gate stops the merge" "$?" 1; ok "no merge happened" "$(merges)" 0
git checkout -q main; printf 'exit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm ok; git push -q origin main; git checkout -q work; rm -f "$stamp"; pr '[]'; merge --check; ok "a clean PR is ready without a gate" "$?" 0; ok "--check never merges" "$(merges)" 0
"$here/sid-gate.sh" work >/dev/null; hash=$(sed -n 2p "$stamp" | sed 's/.*sha256 //'); [ -n "$hash" ] && [ "$(cut -d' ' -f1 < <(sha256sum ".git/sid-gate/logs/$head.$(git rev-parse origin/main).log"))" = "$hash" ]; ok "the kept log matches the recorded hash" "$?" 0
git checkout -q main; printf 'touch "$T/gate-ran"\n' > .sidstack/gate.sh; git add -A; git commit -qm count; git push -q origin main; git checkout -q work; "$here/sid-gate.sh" work >/dev/null; rm -f "$t/gate-ran"; sed -i 2d "$stamp"; pr '[]'; merge --check; ok "--check ignores gate stamps" "$?" 0; [ -f "$t/gate-ran" ]; ok "--check did not run the gate" "$?" 1
pr '[]'
git push -q origin "$head~1:refs/heads/parent"; pr '[]'; sed -i 's/"baseRefName":"main"/"baseRefName":"parent"/' "$t/pr.json"
merge --check; ok "a stacked PR passes --check" "$?" 0; grep -q "ready, but stacked on parent" "$t/out"; ok "and says it is stacked" "$?" 0
merge; ok "a stacked PR doesn't merge" "$?" 1; grep -q "land that first" "$t/out"; ok "and says what to do" "$?" 0; ok "no merge happened" "$(merges)" 0
pr '[]'
touch "$t/retargeted"; merge; ok "a retarget just before merging stops it" "$?" 1; grep -q "base changed" "$t/out"; ok "for that reason" "$?" 0; ok "no merge happened" "$(merges)" 0; rm "$t/retargeted"
cp "$t/pr.json" "$t/clean.json"; sed -i 's/"mergeable":"MERGEABLE"/"mergeable":"UNKNOWN"/' "$t/pr.json"; ( sleep 2; cp "$t/clean.json" "$t/pr.json" ) &
merge; ok "a new PR's UNKNOWN mergeability is waited out, and a clean PR merges" "$?" 0; ok "exactly once" "$(merges)" 1; wait
grep -q "^Gate-Passed: train .*, main .* + #5, lane full, log sha256 " "$t/merge-args"; ok "the squash message carries the gate record" "$?" 0
grep -q "^Gate-Passed: " "$t/out"; ok "and the merge prints it" "$?" 0
# Each train case has its own real origin. Inspect commits and outcomes, not implementation text.
export PATH="$t/bin:$PATH"
setup_train() {
  export T=$t/$1; mkdir -p "$T"
  git init -q --bare -b main "$T/origin.git"; git clone -q "$T/origin.git" "$T/repo" 2>/dev/null
  cd "$T/repo" || exit 1; mkdir .sidstack
  cat > .sidstack/gate.sh <<'G'
# Tests are files named test-*: "fail" always fails, "flaky" fails on its first run only.
run_tests() {
  local name bad=0
  for name in "$@"; do
    [ -f "$name" ] || continue
    case "$(cat "$name")" in
      fail) echo "$name" >> "$SID_FAILURES_OUT"; bad=1;;
      flaky) [ -f "$T/ran-$name" ] || { touch "$T/ran-$name"; echo "$name" >> "$SID_FAILURES_OUT"; bad=1; };;
    esac
  done
  return "$bad"
}
if [ -n "${SID_RERUN:-}" ]; then
  echo rerun >> "$T/reruns"; run_tests $(cat "$SID_RERUN"); exit
fi
echo gate >> "$T/gates"
git write-tree >> "$T/gated-trees"
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
run_tests $(ls | grep '^test-')
G
  git add -A; git commit -qm initial; git push -q origin main; git remote set-head origin main
  q=.git/sid-gate/train; health=.git/sid-gate/health
}
add_pr() {
  local n=$1 file=$2 value=${3:-x}
  git checkout -q -B "work$n" origin/main; echo "$value" > "$file"; git add -A
  git commit -qm "change $n" -m 'Agent: writer'; git push -q origin "work$n"
  record_pr "$n"
  git checkout -q main
}
record_pr() {
  local n=$1 h; h=$(git rev-parse HEAD)
  python3 - "$T/pr-$n.json" "$n" "$h" <<'PY'
import json, sys
p, n, h = sys.argv[1:]
json.dump(dict(state='OPEN', isDraft=False, mergeable='MERGEABLE', reviewDecision='', statusCheckRollup=[], headRefOid=h, headRefName='work'+n, baseRefName='main', title='change '+n, body=f'## Proof\n{h} 3 passed\n## Review\nAstra approved.\n'), open(p, 'w'))
PY
}
queue_pr() { "$here/sid-merge.sh" --no-wait "$1" > "$T/out" 2>&1; }
run_train() { "$here/sid-train.sh" > "$T/runner-out" 2>&1; }
count_gates() { if [ -f "$T/gates" ]; then wc -l < "$T/gates" | tr -d ' '; else echo 0; fi; }
code() { head -n 1 "$q/result/$1"; }
# Rename/edit merges must have server semantics even with operator overrides.
setup_train armed-readiness
add_pr 11 a
python3 - "$T/pr-11.json" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['autoMergeRequest']={'enabledAt':'now'}; json.dump(d,open(p,'w'))
P
queue_pr 11; ok "readiness refuses prearmed auto-merge" "$?" 1
grep -q 'gh pr merge 11 --disable-auto' "$T/out"; ok "readiness names exact disarm command" "$?" 0
for refusal in queued refused read; do
  setup_train "armed-$refusal"; add_pr 11 a; queue_pr 11
  if [ "$refusal" != refused ]; then touch "$T/queue-only-11"
  else touch "$T/refuse-merge" "$T/arm-on-refuse"; fi
  if [ "$refusal" = read ]; then touch "$T/auto-read-down"; else touch "$T/disable-fails"; fi
  run_train
  ok "$refusal armed merge returns failure" "$(code 11)" 1
  grep -q 'gh pr merge 11 --disable-auto' "$q/result/11"; ok "$refusal failed disarm names exact command" "$?" 0
done
setup_train pinned-renames
seq 1 100 > old; git add old; git commit -qm base; git push -q origin main
base=$(git rev-parse HEAD)
git checkout -q -b work11; git mv old renamed; git commit -qm rename; git push -q origin work11
record_pr 11; git checkout -q main
sed -i '50s/.*/main edit/' old; git add old; git commit -qm edit; git push -q origin main
# Also force the caller's command-scope config to disagree with the server.
git config merge.renames false
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=merge.renames GIT_CONFIG_VALUE_0=false "$here/sid-gate.sh" work11 > "$T/out" 2>&1
ok "plain gate detects rename despite operator config" "$?" 0
queue_pr 11; run_train
ok "train merges rename with pinned server settings" "$(code 11)" 0
git show origin/main:renamed | grep -q 'main edit'; ok "pinned rename preserves main edit in renamed file" "$?" 0
# A global default custom driver must not turn a content conflict into a pass.
setup_train pinned-driver
printf 'base\n' > content; git add content; git commit -qm base; git push -q origin main
add_pr 11 content branch
printf 'main\n' > content; git add content; git commit -qm main; git push -q origin main
printf '[merge]\n default = ignore\n[merge "ignore"]\n driver = true\n' > "$T/gitconfig"
GIT_CONFIG_GLOBAL="$T/gitconfig" "$here/sid-gate.sh" work11 > "$T/out" 2>&1
ok "plain gate rejects conflict hidden by global merge driver" "$?" 3
queue_pr 11; GIT_CONFIG_GLOBAL="$T/gitconfig" run_train
ok "train rejects conflict hidden by global merge driver" "$(code 11)" 3
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
setup_train health-red
"$here/sid-health.sh" > "$T/out"; ok "missing health runs gate" "$(count_gates)" 1
touch "$T/always-fail"; sha=$(git rev-parse origin/main); rm "$health/$sha"; "$here/sid-health.sh" > "$T/out"
ok "failing health exits 1" "$?" 1; ok "failing full health recorded" "$(head -n 1 "$health/$sha")" 'fail full'
before=$(count_gates); "$here/sid-health.sh" > "$T/out"; ok "known full failure skips" "$(count_gates)" "$before"
add_pr 11 bad; queue_pr 11; run_train; ok "known red main makes single failure exit 4" "$(code 11)" 4
grep -Fq "main is red at ${sha:0:8}, see $(sed -n 2p "$health/$sha")" "$q/result/11"; ok "red result names health log" "$?" 0
queue_pr 11; ok "a red main doesn't use up the commit's retry" "$?" 0
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
# Dependent PRs must have the same squash semantics in the gate and on live main.
setup_train dependent-squash
add_pr 11 bad
git checkout -q -b work12 work11; git rm -q bad; echo y > y; git add -A; git commit -qm 'drop bad, add y'; git push -q origin work12
record_pr 12; git checkout -q main
queue_pr 11; queue_pr 12; run_train
ok "dependent deletion cannot hide a failing earlier member" "$(code 11)" 1
ok "independently safe dependent member merges" "$(code 12)" 0
ok "only the safe squash lands" "$(cat "$T/merge-calls")" 12
git cat-file -e origin/main:bad 2>/dev/null; ok "ungated bad file never reaches main" "$?" 128
ok "landed safe tree was gated" "$(grep -c "^$(git rev-parse 'origin/main^{tree}')$" "$T/gated-trees")" 1
setup_train dependent-pass
add_pr 11 a
git checkout -q -b work12 work11; git rm -q a; echo b > b; git add -A; git commit -qm 'drop a, add b'; git push -q origin work12
record_pr 12; git checkout -q main
queue_pr 11; queue_pr 12; run_train
ok "compatible dependent squashes share one gate" "$(count_gates)" 1
ok "both compatible dependent members merge" "$(code 11) $(code 12)" '0 0'
ok "dependent final squash matches the gated tree" "$(git rev-parse 'origin/main^{tree}')" "$(cat "$T/gated-trees")"
# A successful CLI exit can mean queued, or an unconfirmed completion.
for outcome in queued state head commit fetch api; do
  setup_train "unconfirmed-$outcome"
  add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
  git worktree add -q "$T/worker" work11
  case "$outcome" in
    queued) touch "$T/queue-only-11";;
    state) echo '{"state":"OPEN"}' > "$T/unconfirmed-11";;
    head) echo '{"headRefOid":"0000000000000000000000000000000000000000"}' > "$T/unconfirmed-11";;
    commit) echo '{"mergeCommit":null}' > "$T/unconfirmed-11";;
    fetch) echo '{"mergeCommit":{"oid":"ffffffffffffffffffffffffffffffffffffffff"}}' > "$T/unconfirmed-11";;
    api) touch "$T/post-api-down-11";;
  esac
  run_train
  expected_rc=1; expected_message='the merge did not complete; nothing was cleaned up'
  if [ "$outcome" = fetch ]; then
    expected_rc=5; expected_message='merged #11 as .*but the landed tree could not be verified'
    sha=$(cat "$T/merge-oid-11")
    grep -q '^pass full$' "$health/$sha"; ok "$outcome uncertain landing checks actual main" "$?" 0
  fi
  if [ "$outcome" = api ]; then
    expected_message='gh pr merge 11 --disable-auto'
  fi
  if [ "$outcome" = queued ]; then
    [ -f "$T/auto-disabled-11" ]; ok "queued auto-merge is disabled before refusal" "$?" 0
  fi
  ok "$outcome completion reports verification outcome" "$(code 11)" "$expected_rc"
  grep -q "$expected_message" "$q/result/11"; ok "$outcome completion explains retained work" "$?" 0
  [ -d "$T/worker" ]; ok "$outcome completion retains worktree" "$?" 0
  git show-ref --verify --quiet refs/heads/work11; ok "$outcome completion retains local branch" "$?" 0
  git ls-remote --exit-code origin refs/heads/work11 >/dev/null; ok "$outcome completion retains remote branch" "$?" 0
  ok "$outcome completion rebuilds remaining member" "$(count_gates)" "$((expected_rc == 5 ? 3 : 2))"
  ok "$outcome completion permits freshly gated remaining member" "$(code 12)" 0
done
# The server can move main after the caller's final base check, or land an unexpected tree.
for mismatch in parent tree; do
  setup_train "landed-$mismatch"
  add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
  expected=$(git rev-parse origin/main)
  if [ "$mismatch" = parent ]; then
    git checkout -q -b outside origin/main; echo outside > outside; git add -A; git commit -qm outside; git push -q origin outside
    git rev-parse HEAD > "$T/drift-on-merge-11"; git checkout -q main
  else touch "$T/wrong-tree-11"; fi
  run_train
  ok "$mismatch mismatch after landing exits 5" "$(code 11)" 5
  oid=$(cat "$T/merge-oid-11"); parent=$(git rev-parse "$oid^1")
  grep -Fq "merged #11 as $oid, but main now holds a tree no gate tested (landed on ${parent:0:8}, gated ${expected:0:8})" "$q/result/11"
  ok "$mismatch mismatch identifies the actual and gated bases" "$?" 0
  ok "$mismatch mismatch regates the remaining member" "$(code 12)" 0
  # Health checks the unexpected landing before the remainder is rebuilt.
  sha=$oid
  [ -f "$health/$sha" ] && grep -q '^pass full$' "$health/$sha" && grep -q "/health-$sha.log$" "$health/$sha"
  ok "$mismatch mismatch starts detached full health on real main" "$?" 0
  ok "$mismatch mismatch requires a fresh train and health gate" "$(count_gates)" 3
done
# A landing the train can't vouch for is reported, including after a crash.
setup_train landed-after-prefix
add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12; touch "$T/same-tree-drift-12"
run_train
ok "checked prefix still reports success before later drift" "$(code 11)" 0
ok "second-member parent drift reports exit 5" "$(code 12)" 5
sha=$(cat "$T/merge-oid-12")
grep -q "/health-$sha.log$" "$health/$sha"; ok "stopped train preserves actual health evidence" "$?" 0
ok "second-member drift checks main without another train" "$(count_gates)" 2
setup_train recovered-unsafe-merge
add_pr 11 a; queue_pr 11; touch "$T/same-tree-drift-11" "$T/crash-after-merge"
run_train; run_train
ok "crash recovery checks the original gated base" "$(code 11)" 5
sha=$(cat "$T/merge-oid-11")
grep -q "/health-$sha.log$" "$health/$sha"; ok "unsafe recovered merge starts full health" "$?" 0
ok "unsafe recovery never merges twice" "$(cat "$T/merge-calls")" 11
# Only failures the change causes fail it: failed tests run again, then on main alone.
setup_train flaky
add_pr 11 test-a flaky; queue_pr 11; run_train
ok "a test that passes when run again doesn't fail the PR" "$(code 11)" 0
grep -q 'tests passed over: .*flaky' "$T/message-11"; ok "and the squash says a flaky test was passed over" "$?" 0
ok "running failed tests again is not another gate" "$(count_gates)" 1
setup_train known-failure
echo fail > test-old; git add -A; git commit -qm red; git push -q origin main
add_pr 11 a; queue_pr 11; run_train
ok "a test already failing on main doesn't fail the PR" "$(code 11)" 0
grep -q 'tests passed over: .*already failing' "$T/message-11"; ok "and the squash says so" "$?" 0
[ ! -f "$health/$(git rev-parse origin/main)" ]; ok "and that main isn't recorded as healthy" "$?" 0
"$here/sid-health.sh" > "$T/out" 2>&1; ok "main's own failing test still makes health red" "$?" 1
setup_train new-failure
echo fail > test-old; git add -A; git commit -qm red; git push -q origin main
add_pr 11 test-new fail; queue_pr 11; run_train
ok "a test the PR breaks fails it, even on a red main" "$(code 11)" 1
grep -q '^test-new$' "$q/result/11"; ok "the result names the test the PR broke" "$?" 0
grep -q '^test-old$' "$q/result/11"; ok "and leaves out main's own failure" "$?" 1
setup_train new-test-file
add_pr 11 test-new fail; queue_pr 11; run_train
ok "a failing test the PR adds can't pass as missing on main" "$(code 11)" 1
setup_train unreported
add_pr 11 test-a fail
sed -i 's|^run_tests \$(ls.*|run_tests $(ls \| grep "^test-") \|\| { : > "$SID_FAILURES_OUT"; exit 1; }|' .sidstack/gate.sh; git add -A; git commit -qm quiet; git push -q origin main
git checkout -q work11; git rebase -q main; git push -qf origin work11; record_pr 11; git checkout -q main
queue_pr 11; run_train
ok "a failure the gate doesn't itemise fails the PR" "$(code 11)" 1
[ ! -f "$T/reruns" ]; ok "and nothing is run again" "$?" 0
# A commit the gate failed goes back once, and only when asked.
setup_train retry
add_pr 11 bad; queue_pr 11; run_train; ok "a failing commit fails" "$(code 11)" 1
queue_pr 11; ok "the same commit isn't queued again by itself" "$?" 1
grep -q -- "--retry 11" "$T/out" && grep -q "sid-gate/logs/train-" "$T/out"; ok "the refusal names the log and the retry" "$?" 0
"$here/sid-merge.sh" --check 11 > "$T/out" 2>&1; ok "--check reports it as not ready too" "$?" 1
"$here/sid-merge.sh" --retry --no-wait 11 > "$T/out" 2>&1; ok "--retry queues it once" "$?" 0
run_train; ok "the retry gates again" "$(count_gates)" 2
"$here/sid-merge.sh" --retry --no-wait 11 > "$T/out" 2>&1; ok "a second failure of the commit ends the retries" "$?" 1
grep -q "failed the gate twice" "$T/out"; ok "and says to fix it" "$?" 0
git checkout -q work11; git rm -q bad; echo fixed > a; git add -A; git commit -qm fix; git push -q origin work11; record_pr 11; git checkout -q main
queue_pr 11; ok "a new commit queues without --retry" "$?" 0
run_train; ok "and merges" "$(code 11)" 0
setup_train invalid-mode
add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
printf 'lane=broken\n' > .git/sid-gate/mode
run_train; ok "broken mode fails the runner" "$?" 1
for n in 11 12; do
  ok "broken mode terminates member #$n" "$(code "$n")" 1
  grep -q 'invalid stored mode: lane=broken' "$q/result/$n" && grep -q 'fix it with sid-mode.sh set' "$q/result/$n"
  ok "broken mode explains error and repair for #$n" "$?" 0
  [ ! -f "$q/queue/$n.req" ]; ok "broken mode removes request #$n" "$?" 0
done
ok "broken mode runs no gate" "$(count_gates)" 0
"$here/sid-mode.sh" set lane full > "$T/out" 2>&1; ok "mode set can repair its broken stored value" "$?" 0
setup_train cap
add_pr 11 a; add_pr 12 b; queue_pr 11; queue_pr 12
SID_TRAIN_MAX=1 run_train; ok "train member cap is respected" "$(count_gates)" 2
setup_train detached
add_pr 11 a
SID_TRAIN_INLINE=0 "$here/sid-merge.sh" 11 > "$T/out" 2>&1
ok "fallback runner completes waiting caller" "$?" 0
grep -q 'merged #11:' "$T/out"; ok "waiting caller prints result" "$?" 0
[ -f "$q/result/11" ]; ok "waiting caller retains result for other waiters" "$?" 0
# Start both callers before publishing a result; neither may consume the other's result.
setup_train duplicate-waiters
add_pr 11 a
for n in 1 2; do timeout --foreground 12 "$here/sid-merge.sh" 11 > "$T/waiter-$n" 2>&1 & eval "wp$n=$!"; done
for ((j=0; j<100; j++)); do grep -q 'train:' "$T/waiter-1" && grep -q 'train:' "$T/waiter-2" && break; sleep .05; done
run_train
wait "$wp1"; ok "first waiter returns merge result" "$?" 0
wait "$wp2"; ok "second waiter returns same merge result" "$?" 0
[ -f "$q/result/11" ]; ok "multiple waiters leave terminal result available" "$?" 0
for terminal in missing cancelled; do
  setup_train "waiter-$terminal"
  add_pr 11 a
  timeout --foreground 8 "$here/sid-merge.sh" 11 > "$T/waiter" 2>&1 & wp=$!
  for ((j=0; j<100; j++)); do grep -q 'train:' "$T/waiter" && break; sleep .05; done
  if [ "$terminal" = missing ]; then rm "$q/queue/11.req"
  else "$here/sid-merge.sh" --cancel 11 > "$T/out"; fi
  wait "$wp"; ok "$terminal request terminates its waiting caller" "$?" 1
  if [ "$terminal" = missing ]; then
    grep -q 'neither a request nor a result' "$T/waiter"
  else grep -q cancelled "$T/waiter" && [ "$(code 11)" = 1 ]; fi
  ok "$terminal request explains the terminal outcome" "$?" 0
done
printf '#!/usr/bin/env bash\n[ "$2" != is-active ]\n' > "$t/bin/systemctl"
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
while [[ $1 == --* ]]; do shift; done
INVOCATION_ID=test exec setsid "$@" </dev/null >>"$T/service-log" 2>&1 &
S
chmod +x "$t/bin/systemd-run"
( unset SID_TRAIN_INLINE; "$here/sid-merge.sh" --no-wait 11 > "$T/out" 2>&1 )
ok "service startup queues and returns" "$?" 0
for ((j=0; j<200; j++)); do [ -f "$q/result/11" ] && break; sleep .05; done
ok "service runner outlives enqueue caller" "$(code 11)" 0
ok "service receives caller PATH" "$(sed -n 1p "$T/service-env")" "$PATH"
ok "service receives caller HOME" "$(sed -n 2p "$T/service-env")" "$HOME"
grep -Eq -- '--user --collect --unit=sid-train-[0-9a-f]+ --working-directory=' "$T/service-args"; ok "transient service is named for repo" "$?" 0
# An active runner, and a usable manager rejecting a unit, must not spawn fallback runners.
cat > "$t/bin/systemctl" <<'S'
#!/usr/bin/env bash
case "$2" in
  is-active) [ -f "$T/unit-active" ];;
  show) [ ! -f "$T/unit-loaded" ] || printf 'LoadState=loaded\nActiveState=activating\n';;
  *) exit 0;;
esac
S
chmod +x "$t/bin/systemctl"
cat > "$t/bin/systemd-run" <<'S'
#!/usr/bin/env bash
echo attempted >> "$T/service-attempts"
echo transient-start-failure >&2
exit 1
S
for manager in active collecting missing unavailable; do
  setup_train "service-$manager"; add_pr 11 a
  [ "$manager" != active ] || touch "$T/unit-active"
  [ "$manager" != collecting ] || touch "$T/unit-loaded"
  if [ "$manager" = unavailable ]; then
    printf '#!/usr/bin/env bash\nexit 1\n' > "$t/bin/systemctl"
  fi
  ( unset SID_TRAIN_INLINE; "$here/sid-merge.sh" --no-wait 11 > "$T/out" 2>&1 )
  if [ "$manager" = unavailable ] || [ "$manager" = missing ]; then
    for ((j=0; j<200; j++)); do [ -f "$q/result/11" ] && break; sleep .05; done
    ok "unusable systemd falls back to detached runner" "$(code 11)" 0
  else
    sleep .2
    [ ! -f "$q/result/11" ]; ok "$manager systemd never spawns detached duplicate" "$?" 0
    [ ! -f "$q/result/11" ]; ok "$manager runner request stays queued" "$?" 0
    if [ "$manager" = active ]; then
      [ ! -f "$T/service-attempts" ]; ok "active unit is not started again" "$?" 0
    fi
  fi
done
# A collected unit left a request; the periodic health pass must rescue it,
# even when main already has a full health record.
cat > "$t/bin/systemctl" <<'S'
#!/usr/bin/env bash
case "$2" in
  is-active) exit 1;;
  show) [ ! -f "$T/unit-loaded" ] || printf 'LoadState=loaded\nActiveState=activating\n';;
  *) exit 0;;
esac
S
setup_train health-rescue; add_pr 11 a; touch "$T/unit-loaded"
( unset SID_TRAIN_INLINE; "$here/sid-merge.sh" --no-wait 11 > "$T/out" 2>&1 )
[ -f "$q/queue/11.req" ]; ok "transient start failure retains queued request" "$?" 0
rm "$T/unit-loaded"
( flock 7; unset SID_TRAIN_INLINE; "$here/sid-health.sh" > "$T/busy-health-out" 2>&1 ) 7>"$q/runner.lock"
[ ! -f "$q/result/11" ]; ok "health leaves a locked runner in charge" "$?" 0
sha=$(git rev-parse origin/main); printf 'pass full\nold-log\n' > "$health/$sha"
( unset SID_TRAIN_INLINE; "$here/sid-health.sh" > "$T/health-out" 2>&1 )
for ((j=0; j<200; j++)); do [ -f "$q/result/11" ] && break; sleep .05; done
ok "later health drains request after transient failure" "$(code 11)" 0
grep -q transient-start-failure "$q/runner.log"; ok "runner log retains systemd startup failure" "$?" 0
printf '#!/usr/bin/env bash\nexit 1\n' > "$t/bin/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n' > "$t/bin/systemd-run"
setup_train active-cancel
add_pr 11 a; queue_pr 11; touch "$T/block-train"
"$here/sid-train.sh" > "$T/runner-out" 2>&1 & rp=$!
for ((j=0; j<100; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
[ -f "$T/train-started" ]; ok "train member reached gating" "$?" 0
"$here/sid-merge.sh" --cancel 11 > "$T/out"
grep -q 'has started gating; cannot cancel' "$T/out"; ok "cancel cannot withdraw active member" "$?" 0
touch "$T/release-train"; wait "$rp"; ok "uncancelled active member merges" "$(code 11)" 0
setup_train mode
for pair in 'lane fast' 'coder claude' 'ui sol' 'reviewers none'; do
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
# Docker tests assert observable selections and run arguments, independent of shell/Python internals.
mkdir -p "$t/docker-bin"
export DOCKER_TEST_DIR="$t/docker-fixture"
mkdir -p "$DOCKER_TEST_DIR"
cat > "$t/docker-bin/docker" <<'PY'
#!/usr/bin/env python3
import datetime, json, os, sys
from pathlib import Path
p = Path(os.environ['DOCKER_TEST_DIR']); a = sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\n')
def emit(data): print(json.dumps(data))
def container(name, hours, status='exited', labels=None, started_at=None, finished_at=None):
    at = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)).isoformat()
    started_at = started_at if started_at is not None else at
    finished_at = finished_at if finished_at is not None else at
    return dict(Created=at, Id=name, Name='/'+name, Config=dict(Labels=labels or {}), State=dict(Status=status, Running=status=='running', StartedAt=started_at, FinishedAt=finished_at), NetworkSettings=dict(Ports={'5432/tcp':[dict(HostIp='127.0.0.1' if name in ('throw-old', 'new-db') else '0.0.0.0', HostPort='54321')]}), Mounts=[dict(Type='volume', Name='precious_named_volume')])
throw = {'sidstack.throwaway':'1'}; compose = {'com.docker.compose.project':'keep'}
unset = '0001-01-01T00:00:00Z'
cs = [container('plain-old', 25), container('throw-exited', .1, labels=throw),
      container('throw-old', 9, 'running', throw), container('compose-running', 50, 'running', {**throw, **compose}),
      container('compose-exited', 50, labels=compose), container('plain-running', 50, 'running'),
      container('plain-young', 23), container('throw-young', 1, 'running', throw),
      container('plain-unset-finished', 50, finished_at=unset),
      container('throw-unset-started', 3, 'running', throw, started_at=unset)]
if (p/'lifecycle').exists():
    cs += [container('throw-session', 3, 'running', throw)]
    for status in ('created', 'dead'):
        for age in (1, 3):
            cs.append(container(f'{status}-{age}', age, status, throw, started_at=unset))
        for value in (unset, 'unreadable', ''):
            c = container(f'{status}-unknown-{len(cs)}', 50, status, throw)
            c['Created'] = value
            cs.append(c)
        c = container(f'{status}-missing', 50, status, throw)
        del c['Created']
        cs.append(c)
    cs.append(container('compose-created', 50, 'created', {**throw, **compose}))
if a == ['info']:
    sys.exit(1 if (p/'down').exists() else 0)
elif a[0] == 'version': emit(dict(Server=dict(Version='29.9.2', ApiVersion='1.56'), Client=dict(ApiVersion='1.56')))
elif a[:2] == ['system','df']:
    if (p/'df-fail').exists(): sys.exit('cannot read system df')
    emit(dict(Size='bad' if (p/'df-invalid').exists() else '1GB'))
elif a[0] == 'ps': print('\n'.join(c['Id'] for c in cs if '--filter' not in a or c['Config']['Labels'].get('sidstack.throwaway') == '1'))
elif a[0] == 'inspect':
    emit([next((c for c in cs if c['Id']==a[1]), container('new-db', 0, 'running', throw))])
elif a[:2] == ['image','inspect']:
    sys.exit(1 if (p/'missing-image').exists() else 0)
elif a[0] == 'run': print('new-db')
elif a[0] == 'exec': pass
elif a[0] == 'rm':
    if (p/'restart-race').exists() and a[-1] == 'plain-old': sys.exit('container is running')
    if (p/'concurrent-removal').exists() and a[-1] == 'throw-exited': sys.exit('No such container')
elif a[:2] == ['volume','ls']:
    print('anonymous-volume\nanonymous-later\ncompose-project-volume\ncompose-volume' if 'label=com.docker.volume.anonymous' in a else 'anonymous-volume\nprecious_named_volume')
elif a[:2] == ['volume','inspect']:
    labels = {'com.docker.compose.project':'keep'} if a[-1]=='compose-project-volume' else {'com.docker.compose.volume':'keep'} if a[-1]=='compose-volume' else {'com.docker.volume.anonymous':''}
    emit([dict(Name=a[-1], Labels=labels)])
elif a[:2] == ['volume','rm']:
    if (p/'volume-fail').exists() and a[-1]=='anonymous-volume': sys.exit('volume is in use')
elif a[:2] == ['image','ls']: print('dangling-image')
elif a[1:2] == ['prune']:
    if (p/'image-fail').exists() and a[0]=='image': sys.exit('image prune failed')
else: sys.exit('unexpected docker command: '+repr(a))
PY
chmod +x "$t/docker-bin/docker"
export PATH="$t/docker-bin:$PATH"
unset DOCKER_API_VERSION
"$here/sid-docker-clean.sh" > "$t/clean-out"; ok "janitor runs" "$?" 0
python3 - <<'PY'
import json, os
from pathlib import Path
calls = [json.loads(s) for s in (Path(os.environ['DOCKER_TEST_DIR'])/'calls').read_text().splitlines()]
removed = {a[-1]:a[1] for a in calls if a[0]=='rm'}
assert removed == {'throw-exited':'-fv', 'throw-old':'-fv', 'plain-old':'-v'}, removed
assert 'plain-unset-finished' not in removed and 'throw-unset-started' not in removed
assert ['volume','ls','-q','--filter','dangling=true','--filter','label=com.docker.volume.anonymous'] in calls
assert [a[-1] for a in calls if a[:2]==['volume','rm']] == ['anonymous-volume', 'anonymous-later']
assert not any(a[:2]==['volume','prune'] for a in calls)
assert ['image','prune','-f'] in calls
assert ['builder','prune','-f','--filter','until=72h'] in calls
assert not any('precious_named_volume' in a or '--all' in a or '-a' in a for a in calls)
PY
ok "janitor expires exactly eligible containers; preserves Compose, running and recent containers and named volumes" "$?" 0
: > "$DOCKER_TEST_DIR/calls"
"$here/sid-docker-clean.sh" --dry-run > "$t/clean-dry"; ok "janitor dry-run succeeds" "$?" 0
python3 - "$t/clean-dry" <<'PY'
import json, os, sys
from pathlib import Path
calls = [json.loads(s) for s in (Path(os.environ['DOCKER_TEST_DIR'])/'calls').read_text().splitlines()]
assert not any('rm' in a or 'prune' in a for a in calls)
out=Path(sys.argv[1]).read_text()
for name in ['throw-exited','throw-old','plain-old','anonymous-volume','anonymous-later','dangling-image']: assert name in out, name
for name in ['compose-running','compose-exited','plain-running','plain-young','throw-young','plain-unset-finished','throw-unset-started','precious_named_volume','compose-project-volume','compose-volume']: assert name not in out, name
PY
ok "dry-run lists eligible resources without any removal" "$?" 0
touch "$DOCKER_TEST_DIR/lifecycle"; : > "$DOCKER_TEST_DIR/calls"
"$here/sid-docker-clean.sh" > "$t/lifecycle" 2>&1
ok "created/dead and session cleanup succeeds" "$?" 0
python3 - <<'PYTEST'
import json, os
from pathlib import Path
calls=[json.loads(s) for s in (Path(os.environ['DOCKER_TEST_DIR'])/'calls').read_text().splitlines()]
removed={a[-1] for a in calls if a[0]=='rm'}
assert removed == {'throw-exited', 'throw-old', 'plain-old', 'created-3', 'dead-3'}, removed
PYTEST
ok "created/dead expire after 2h using known creation time; running sessions survive 3h and expire at 9h" "$?" 0
rm "$DOCKER_TEST_DIR/lifecycle"
for scenario in restart-race concurrent-removal volume-fail df-fail df-invalid image-fail; do
  touch "$DOCKER_TEST_DIR/$scenario"; : > "$DOCKER_TEST_DIR/calls"
  "$here/sid-docker-clean.sh" > "$t/failure-out" 2>&1
  ok "$scenario returns failure after cleanup" "$?" 1
  python3 - "$t/failure-out" "$scenario" <<'PYTEST'
import json, os, sys
from pathlib import Path
calls=[json.loads(s) for s in (Path(os.environ['DOCKER_TEST_DIR'])/'calls').read_text().splitlines()]
assert [a[-1] for a in calls if a[0]=='rm'] == ['plain-old','throw-exited','throw-old']
assert ['volume','rm','anonymous-volume'] in calls
assert ['volume','rm','anonymous-later'] in calls
assert ['image','prune','-f'] in calls
assert ['builder','prune','-f','--filter','until=72h'] in calls
assert sum(a[:2]==['system','df'] for a in calls)==2
out=Path(sys.argv[1]).read_text()
assert 'sid-docker-clean:' in out, out
if sys.argv[2].startswith('df-'): assert 'space reclaimed unavailable' in out, out
PYTEST
  ok "$scenario reports failure and still attempts later containers, volumes, image/cache cleanup and totals" "$?" 0
  rm "$DOCKER_TEST_DIR/$scenario"
done
touch "$DOCKER_TEST_DIR/down"; : > "$DOCKER_TEST_DIR/calls"
"$here/sid-docker-clean.sh" > "$t/clean-down" 2>&1; ok "Docker down is a successful janitor no-op" "$?" 0
ok "Docker down makes no further calls" "$(wc -l < "$DOCKER_TEST_DIR/calls")" 1
"$here/sid-db.sh" start > "$t/db-down" 2>&1; ok "database helper fails clearly when Docker is down" "$?" 1
rm "$DOCKER_TEST_DIR/down"
: > "$DOCKER_TEST_DIR/calls"
"$here/sid-db.sh" start test-db > "$t/db-url"; ok "database helper starts" "$?" 0
python3 - "$t/db-url" <<'PY'
import json, os, sys
from pathlib import Path
from urllib.parse import urlparse
calls = [json.loads(s) for s in (Path(os.environ['DOCKER_TEST_DIR'])/'calls').read_text().splitlines()]
a = next(a for a in calls if a[0]=='run')
assert '--rm' in a and '--pull=never' in a
assert a[a.index('--tmpfs')+1] == '/var/lib/postgresql/data'
assert 'sidstack.throwaway=1' in a
assert any(s.startswith('sidstack.started-at=') and s.split('=')[1].isdigit() for s in a)
assert a[a.index('-p')+1] == '127.0.0.1::5432'
assert a[-1]=='pgvector/pgvector:pg17'
u=urlparse(Path(sys.argv[1]).read_text().strip())
assert u.scheme=='postgres' and u.hostname=='127.0.0.1' and u.port==54321 and u.password and u.path=='/sid'
assert any(a[0]=='exec' and 'pg_isready' in a for a in calls)
PY
ok "database starts with automatic removal, tmpfs, labels, loopback port, readiness and one URL" "$?" 0
"$here/sid-db.sh" list > "$t/db-list"
python3 - "$t/db-list" <<'PYTEST'
import sys
from pathlib import Path
rows=Path(sys.argv[1]).read_text().splitlines()
assert {r.split()[0] for r in rows} == {'throw-old', 'throw-young', 'throw-unset-started'}
assert all('age=' in r for r in rows)
PYTEST
ok "database list includes only running owned databases with age" "$?" 0
: > "$DOCKER_TEST_DIR/calls"
"$here/sid-db.sh" stop "$(cat "$t/db-url")" > "$t/db-stop"; ok "database stop resolves a local URL" "$?" 0
: > "$DOCKER_TEST_DIR/calls"
"$here/sid-db.sh" stop compose-running > "$t/db-stop" 2>&1; ok "database stop refuses Compose even if labelled throwaway" "$?" 1
"$here/sid-db.sh" stop plain-running > "$t/db-stop" 2>&1; ok "database stop refuses unlabelled containers" "$?" 1
"$here/sid-db.sh" stop throw-old > "$t/db-stop"; ok "database stop accepts owned container name" "$?" 0
python3 - <<'PY'
import json, os
from pathlib import Path
calls = [json.loads(s) for s in (Path(os.environ['DOCKER_TEST_DIR'])/'calls').read_text().splitlines()]
assert [a for a in calls if a[0]=='rm'] == [['rm','-fv','throw-old']]
PY
ok "database stop only removes owned non-Compose container" "$?" 0
touch "$DOCKER_TEST_DIR/missing-image"; : > "$DOCKER_TEST_DIR/calls"
"$here/sid-db.sh" start > "$t/db-missing" 2>&1; ok "missing image fails instead of pulling" "$?" 1
grep -q 'not pulled' "$t/db-missing"; ok "missing image explains the failure" "$?" 0
grep -Eq '"(pull|run)"' "$DOCKER_TEST_DIR/calls"; ok "missing image never pulls or runs" "$?" 1

# MCP reaper: synthetic process identities and signals only; never signal host MCPs.
SID_REAP_MODULE_DIR="$here" python3 - <<'PY'
from dataclasses import replace
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import sqlite3
import sys
import tempfile
import unittest
sys.path.insert(0, os.environ['SID_REAP_MODULE_DIR'])
import sid_mcp_reap as reaper

class ReaperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = Path(self.tmp.name) / 'state.sqlite'
        with sqlite3.connect(self.db) as db:
            db.execute('CREATE TABLE orchestration_v2_projection_threads '
                       '(thread_id TEXT, title TEXT, payload_json TEXT)')
            db.execute('CREATE TABLE orchestration_v2_projection_runs '
                       '(thread_id TEXT, requested_at TEXT, status TEXT, provider_instance_id TEXT)')
        self.now = 1800000000
        self.rows = {}
        self.calls, self.waits, self.output = [], [], []
        self.add(100, 1, ('/opt/codex', 'app-server', '--listen', 'stdio://'))
        self.add(101, 1, ('codex', 'app-server'))

    def add(self, pid, parent, argv, age=7201, pgid=None):
        self.rows[pid] = reaper.Process(pid, parent, pid if pgid is None else pgid,
                                        pid * 10, age, 1024, tuple(argv))

    def thread(self, name, age, running=False, subagent=False, provider='codex', status=None,
               created_by='user'):
        requested = datetime.fromtimestamp(self.now - age, timezone.utc).isoformat()
        payload = {'createdBy': 'agent' if subagent else created_by}
        if subagent:
            payload['lineage'] = {'parentThreadId': 'parent'}
        with sqlite3.connect(self.db) as db:
            db.execute('INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?)',
                       (name, name, json.dumps(payload)))
            db.execute('INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?)',
                       (name, requested, status or ('running' if running else 'completed'), provider))

    def run_reaper(self, dry=False, table=None, send=None):
        def fake_kill(target, sig):
            self.calls.append((target, sig))
            # TERM-resistant processes force the five-second escalation path.
            if sig == signal.SIGKILL:
                self.rows = {pid: p for pid, p in self.rows.items()
                             if not (p.pgid == -target if target < 0 else pid == target)}
        return reaper.reap(self.db, dry, table or (lambda: self.rows.copy()),
                           send or fake_kill, self.waits.append, self.output.append, now=lambda: self.now)

    def test_selection_and_signal_targets(self):
        commands = [('railway', 'mcp', 'proxy'), ('npm', 'exec', 'rea-agents@1', 'mcp'),
                    ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), ('/usr/lib/chatgpt/resources/cua_node/bin/cua_repl',),
                    ('node', str(Path.home() / '.codex/plugins/data/mcp/launch.mjs')), (str(Path.home() / '.cache/codex-runtimes/apps/launch_codex_app_tools_mcp'),)]
        for i, cmd in enumerate(commands, 200):
            self.add(i, 100 if i % 2 else 101, cmd, pgid=100 if i == 200 else i)
        keep = [(300, 100, commands[0], 7200), (301, 100, commands[1], 50),
                (302, 100, ('node', 'ordinary.js'), 9000), (303, 999, commands[0], 9000),
                (304, 200, commands[2], 9000),
                (305, 100, ('codex-code-mode', 'node_repl'), 9000),
                (306, 100, ('node', '/a/not-mcp/launch.mjs'), 9000),
                (307, 100, ('codex', 'app-server', '-c', 'rea-agents'), 9000)]
        for pid, parent, argv, age in keep:
            self.add(pid, parent, argv, age, pgid=100 if pid == 307 else None)
        self.assertEqual(self.run_reaper(), 0)
        targets = {200, -201, -202, -203, -204, -205}
        self.assertEqual(set(self.calls), {(t, signal.SIGTERM) for t in targets} | {(abs(t), signal.SIGKILL) for t in targets})
        self.assertEqual(set(self.rows), {100, 101, *(p[0] for p in keep)})
        self.assertEqual(self.waits, [5])
        self.assertIn('stopped 6 server(s); RSS freed 6144 bytes', self.output[-1])
        self.assertEqual(sum(line.startswith('Stopped pid=') for line in self.output), 6)

    def test_every_run_can_match_a_fresh_server(self):
        for status in ('running', 'waiting', 'completed'):
            with self.subTest(status=status):
                with sqlite3.connect(self.db) as db:
                    db.execute('DELETE FROM orchestration_v2_projection_threads')
                    db.execute('DELETE FROM orchestration_v2_projection_runs')
                self.thread('resumed child', age=20000, subagent=True)
                requested = datetime.fromtimestamp(self.now - 8050, timezone.utc).isoformat()
                with sqlite3.connect(self.db) as db:
                    db.execute('INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?)',
                               ('resumed child', requested, status, 'codex'))
                self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=8000)
                self.calls.clear()
                self.output.clear()
                self.run_reaper()
                self.assertEqual(bool(self.calls), status == 'completed')
                reason = 'subagent resumed child finished' if status == 'completed' else 'running thread'
                self.assertTrue(any('reason=' + reason in line for line in self.output))

    def test_unfinished_thread_matching_later_run_blocks_closer_finished_thread(self):
        self.thread('live child', age=20000, subagent=True, running=True)
        requested = datetime.fromtimestamp(self.now - 8050, timezone.utc).isoformat()
        with sqlite3.connect(self.db) as db:
            db.execute('INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?)',
                       ('live child', requested, 'completed', 'codex'))
        self.thread('closer finished child', age=8020, subagent=True)
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=8000)
        self.run_reaper()
        self.assertEqual(self.calls, [])

    def test_only_user_created_threads_are_operator_threads(self):
        for creator in ('agent', None, 'unknown', 'user'):
            with self.subTest(creator=creator):
                with sqlite3.connect(self.db) as db:
                    db.execute('DELETE FROM orchestration_v2_projection_threads')
                    db.execute('DELETE FROM orchestration_v2_projection_runs')
                self.thread('top level', age=30, created_by=creator)
                self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=20)
                self.calls.clear()
                self.output.clear()
                self.run_reaper()
                self.assertEqual(bool(self.calls), creator != 'user')
                reason = 'operator thread' if creator == 'user' else 'agent thread top level finished'
                self.assertTrue(any('reason=' + reason in line for line in self.output))

    def test_project_lookalikes_and_keyword_arguments_are_kept(self):
        commands = [('/project/node_repl',), ('/project/cua_repl',),
                    ('node', '/project/mcp/launch.mjs'), ('/project/launch_codex_app_tools_mcp',),
                    ('python', '/project/run-diagnostic.py', 'rea-agents'),
                    ('python', '/project/run-diagnostic.py', '/usr/lib/chatgpt/resources/cua_node/bin/node_repl'),
                    ('echo', 'railway', 'mcp', 'proxy'), ('npm', 'exec', 'rea-agents', 'mcp'),
                    ('npm exec rea-agents@1 mcp extra',),
                    ('node', str(Path.home() / '.codex-evil/mcp/launch.mjs'))]
        for pid, command in enumerate(commands, 200):
            self.add(pid, 100, command)
        self.run_reaper()
        self.assertEqual(self.calls, [])
        self.assertTrue(all(pid in self.rows for pid in range(200, 200 + len(commands))))

    def test_relative_launch_paths_and_npm_process_title(self):
        self.add(200, 100, ('node', './mcp/launch.mjs'))
        self.add(201, 100, ('node', './mcp/launch.mjs'))
        self.add(202, 100, ('npm exec rea-agents@6.8.0 mcp',))
        self.add(203, 100, ('node', './mcp/launch.mjs'))
        self.rows[200] = replace(self.rows[200], cwd=str(Path.home() / '.codex/plugins/data'))
        self.rows[201] = replace(self.rows[201], cwd='/project')
        self.rows[203] = replace(self.rows[203], cwd=str(Path.home() / '.cache/codex-runtimes/data'))
        self.run_reaper()
        self.assertEqual({abs(target) for target, _ in self.calls}, {200, 202, 203})
        self.assertIn(201, self.rows)

    def test_orphans_use_the_same_thread_and_age_rules(self):
        for parent in (1, 110):
            with self.subTest(parent=parent):
                self.add(110, 1, ('/usr/lib/systemd/systemd', '--user'))
                self.rows[110] = replace(self.rows[110], uid=os.getuid())
                self.thread('finished orphan child ' + str(parent), age=30, subagent=True)
                self.thread('live orphan child ' + str(parent), age=300, subagent=True, running=True)
                self.thread('orphan operator ' + str(parent), age=600)
                for pid, age in ((200, 20), (201, 290), (202, 590), (203, 8000), (204, 5000)):
                    self.add(pid, parent, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=age)
                self.calls.clear()
                self.run_reaper()
                self.assertEqual({abs(target) for target, _ in self.calls}, {200, 203})
                self.assertTrue(all(pid in self.rows for pid in (201, 202, 204)))

    def test_foreign_systemd_and_changed_orphan_parent_are_kept(self):
        self.add(110, 1, ('/usr/lib/systemd/systemd', '--user'))
        self.rows[110] = replace(self.rows[110], uid=os.getuid() + 1)
        self.add(200, 110, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.run_reaper()
        self.assertEqual(self.calls, [])
        self.add(200, 1, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        initial = self.rows.copy()
        self.rows[200] = replace(self.rows[200], ppid=110)
        snapshots = iter([initial, self.rows])
        self.run_reaper(table=lambda: next(snapshots))
        self.assertEqual(self.calls, [])

    def test_group_children_survive_leader_term(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.add(201, 200, ('worker',), pgid=200)
        def send(target, sig):
            self.calls.append((target, sig))
            self.rows.pop(200 if sig == signal.SIGTERM else 201, None)
        self.assertEqual(self.run_reaper(send=send), 0)
        self.assertEqual(self.calls, [(-200, signal.SIGTERM), (201, signal.SIGKILL)])
        self.assertIn('RSS freed 2048 bytes', self.output[-1])

    def test_dry_run_never_signals_or_waits(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.run_reaper(dry=True)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.waits, [])
        self.assertIn(200, self.rows)
        self.assertTrue(any('Would stop pid=200' in s for s in self.output))

    def test_finished_subagent_stops_even_when_young_and_other_thread_running(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=10)
        self.thread('finished child', age=20, subagent=True)
        self.thread('other active thread', age=500, running=True)
        self.assertEqual(self.run_reaper(), 0)
        self.assertEqual(self.calls, [(-200, signal.SIGTERM), (200, signal.SIGKILL)])
        self.assertTrue(any('reason=subagent finished child finished' in s for s in self.output))

    def test_running_thread_kept(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.thread('active operator', age=7250, running=True)
        self.run_reaper()
        self.assertEqual(self.calls, [])
        self.assertTrue(any('reason=running thread' in s for s in self.output))

    def test_running_subagent_kept_including_later_run(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.thread('active child', age=7250, subagent=True)
        with sqlite3.connect(self.db) as db:
            requested = datetime.fromtimestamp(self.now - 1, timezone.utc).isoformat()
            db.execute('INSERT INTO orchestration_v2_projection_runs VALUES (?, ?, ?, ?)',
                       ('active child', requested, 'running', 'codex'))
        self.run_reaper()
        self.assertEqual(self.calls, [])
        self.assertTrue(any('reason=running thread' in s for s in self.output))

    def test_finished_operator_thread_kept(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.thread('operator', age=7250)
        self.run_reaper()
        self.assertEqual(self.calls, [])
        self.assertTrue(any('reason=operator thread' in s for s in self.output))

    def test_closest_preceding_thread_wins(self):
        for closer_subagent in (True, False):
            with self.subTest(closer_subagent=closer_subagent):
                with sqlite3.connect(self.db) as db:
                    db.execute('DELETE FROM orchestration_v2_projection_threads')
                    db.execute('DELETE FROM orchestration_v2_projection_runs')
                self.thread('earlier', age=130, subagent=not closer_subagent)
                self.thread('closer', age=30, subagent=closer_subagent)
                self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=20)
                self.calls.clear()
                self.output.clear()
                self.run_reaper()
                self.assertEqual(bool(self.calls), closer_subagent)
                reason = 'subagent closer finished' if closer_subagent else 'operator thread'
                self.assertTrue(any('reason=' + reason in s for s in self.output))

    def test_server_before_any_thread_has_no_match(self):
        self.thread('future operator', age=7200, running=True)
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=10800)
        self.run_reaper()
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(any('reason=no thread, 3h old' in s for s in self.output))

    def test_no_match_age_threshold_and_window(self):
        self.thread('too early operator', age=11000)
        for pid, age in ((200, 10800), (201, 7200), (202, 10)):
            self.add(pid, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=age)
        self.run_reaper()
        self.assertEqual(self.calls, [(-200, signal.SIGTERM), (200, signal.SIGKILL)])
        self.assertEqual(sum('reason=no thread, too young' in s for s in self.output), 2)

    def test_match_window_includes_exact_start_and_120_seconds(self):
        self.thread('child', age=200, subagent=True)
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=200)
        self.add(201, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=80)
        self.add(202, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=79)
        self.run_reaper()
        self.assertEqual({abs(target) for target, _ in self.calls}, {200, 201})
        self.assertTrue(any('Keep pid=202' in s for s in self.output))

    def test_other_provider_does_not_match(self):
        self.thread('claude operator', age=7250, running=True, provider='claude')
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.run_reaper()
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(any('reason=no thread,' in s for s in self.output))

    def test_resumed_subagent_is_rechecked_before_signal(self):
        self.thread('resumed child', age=7250, subagent=True)
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        def table():
            with sqlite3.connect(self.db) as db:
                db.execute("UPDATE orchestration_v2_projection_runs SET status='running'")
            return self.rows.copy()
        self.run_reaper(table=table)
        self.assertEqual(self.calls, [])
        self.assertTrue(any('reason=running thread' in s for s in self.output))

    def test_unreadable_database_skips_without_creating_it(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        self.db.unlink()
        self.run_reaper()
        self.assertFalse(self.db.exists())
        self.assertEqual(self.calls, [])
        self.assertTrue(any('cannot be read' in s for s in self.output))
        self.db.write_text('not a sqlite database')
        self.run_reaper()
        self.assertEqual(self.calls, [])

    def test_pid_reuse_and_changed_parent_are_protected(self):
        for change in ({'started': 999}, {'ppid': 1}, {'pgid': 999},
                       {'argv': ('codex-code-mode',)}):
            with self.subTest(change=change):
                self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
                initial = self.rows.copy()
                self.rows[200] = replace(self.rows[200], **change)
                snapshots = iter([initial, self.rows])
                self.run_reaper(table=lambda: next(snapshots))
                self.assertEqual(self.calls, [])

    def test_group_outside_subtree_is_protected(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        for parent, argv in [(1, ('unrelated',)), (100, ('sibling',)),
                             (200, ('codex-code-mode',)), (200, ('codex', 'app-server'))]:
            with self.subTest(parent=parent, argv=argv):
                self.add(201, parent, argv, pgid=200)
                self.run_reaper()
                self.assertEqual(self.calls, [])

    def test_parent_must_start_with_codex_app_server(self):
        for argv in [('node', 'codex', 'app-server'), ('codex-code-mode', 'app-server'),
                     ('codex', 'exec'), ('echo', 'codex app-server')]:
            with self.subTest(argv=argv):
                self.add(100, 1, argv)
                self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
                self.run_reaper()
                self.assertEqual(self.calls, [])

    def test_term_success_does_not_escalate(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        def send(target, sig):
            self.calls.append((target, sig))
            del self.rows[200]
        self.run_reaper(send=send)
        self.assertEqual(self.calls, [(-200, signal.SIGTERM)])

    def test_running_match_blocks_stop_even_if_later_finished_subagent_is_closer(self):
        self.thread('running-sub', age=30, subagent=True, running=True)
        self.thread('finished-sub', age=25, subagent=True)
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=15)
        self.run_reaper()
        self.assertEqual(self.calls, [])
        self.assertTrue(any('reason=running thread' in s for s in self.output))

    def test_unfinished_run_states_keep_the_server(self):
        for status in ('queued', 'preparing', 'starting', 'waiting'):
            with self.subTest(status=status):
                with sqlite3.connect(self.db) as db:
                    db.execute('DELETE FROM orchestration_v2_projection_threads')
                    db.execute('DELETE FROM orchestration_v2_projection_runs')
                self.thread('child', age=30, subagent=True, status=status)
                self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',), age=20)
                self.calls.clear()
                self.output.clear()
                self.run_reaper()
                self.assertEqual(self.calls, [])
                self.assertTrue(any('reason=running thread' in s for s in self.output))

    def test_process_joining_group_during_grace_is_not_killed(self):
        self.add(200, 100, ('/usr/lib/chatgpt/resources/cua_node/bin/node_repl',))
        def send(target, sig):
            self.calls.append((target, sig))
            if sig == signal.SIGTERM:
                self.add(210, 200, ('codex-code-mode',), pgid=200)
            elif target > 0:
                self.rows.pop(target, None)
        self.run_reaper(send=send)
        self.assertEqual(self.calls, [(-200, signal.SIGTERM), (200, signal.SIGKILL)])
        self.assertIn(210, self.rows)

suite = unittest.defaultTestLoader.loadTestsFromTestCase(ReaperTests)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(not result.wasSuccessful())
PY
ok "MCP reaper fixture cases (no host process signals)" "$?" 0
exit $fail
