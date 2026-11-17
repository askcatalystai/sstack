#!/usr/bin/env bash
# Real runs against a throwaway repo, with a fake gh: a stale pass never counts, and a merge only follows a fresh read.
set -u
# Do not inherit the harness service identity; systemd cases opt in with fakes.
unset INVOCATION_ID
export SID_KANZO_URL=http://127.0.0.1:1/mcp
# Git routing inherited from a caller must never redirect fixture gates/locks.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
export SID_GATE_LEASE_SECONDS=1
here=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT; fail=0
ok() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (want $3, got $2)"; fail=1; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
fixture_repo() {
  local root; root=$(pwd -P)
  [[ $root == "$t/"* ]] && [ "$(git rev-parse --path-format=absolute --git-common-dir)" = "$root/.git" ] || {
    echo 'refusing a non-fixture Git common directory and gate locks' >&2; exit 1;
  }
}
git init -q --bare -b main "$t/origin.git"; git clone -q "$t/origin.git" "$t/repo" 2>/dev/null; cd "$t/repo" || exit 1
fixture_repo
git checkout -q -b main; mkdir .sidstack; printf ': > "$SID_FAILURE_IDENTITIES_OUT"\nexit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm one; git push -q origin main; git remote set-head origin main
git checkout -q -b work; echo x > x; git add -A; git commit -qm two; git push -q origin work; head=$(git rev-parse HEAD); stamp=.git/sid-gate/work.pass
"$here/sid-gate.sh" work >/dev/null; ok "a passing gate records the head" "$?" 0; [ -f "$stamp" ]; ok "pass exists" "$?" 0; [ -f .git/sid-gate/work.log ]; ok "plain gate retains its latest log path" "$?" 0
"$here/sid-gate.sh" missing-branch >/dev/null 2>&1; ok "a failed fetch fails" "$?" 1
git checkout -q main; printf ': > "$SID_FAILURE_IDENTITIES_OUT"\nexit 1\n' > .sidstack/gate.sh; git add -A; git commit -qm bad; git push -q origin main; git checkout -q work
"$here/sid-gate.sh" work >/dev/null; ok "a failing gate fails" "$?" 1; [ ! -f "$stamp" ]; ok "a failing rerun clears the old pass" "$?" 0
git checkout -q main; printf ': > "$SID_FAILURE_IDENTITIES_OUT"\nexit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm good; git push -q origin main; git checkout -q work
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
    pr = args[2]; d = json.loads(data(pr).read_text()); d.setdefault('autoMergeRequest', None); d.setdefault('number', int(pr))
    fields = args[args.index('--json')+1]
    if fields == 'autoMergeRequest' and (p/'auto-read-down').exists(): sys.exit(1)
    if fields == 'mergeCommit':
        print((p/f'merge-oid-{pr}').read_text().strip()); sys.exit()
    if (p/f'post-api-down-{pr}').exists() and d['state'] == 'MERGED': sys.exit(1)
    if (p/'retargeted').exists() and 'baseRefName' in fields and 'mergeable' not in fields:
        d['baseRefName'] = 'parent'
    print(json.dumps(d))
elif args[:2] == ['pr', 'list']:
    rows = [json.loads(f.read_text()) | {'number': int(f.stem.split('-')[1])} for f in p.glob('pr-*.json')]
    if '--base' in args: rows = [d for d in rows if d['baseRefName'] == args[args.index('--base')+1] and d['state'] == 'OPEN']
    if '--base' in args and (p/'stuck-retarget').exists(): rows = [json.loads(data('12').read_text())]
    if '--head' in args: rows = [d for d in rows if d['headRefName'] == args[args.index('--head')+1]]
    print(json.dumps(rows))
elif args[:2] == ['pr', 'edit']:
    d = json.loads(data(args[2]).read_text()); d['baseRefName'] = args[args.index('--base')+1]; data(args[2]).write_text(json.dumps(d))
    if (p/'stuck-retarget').exists():
        with (p/'retarget-edits').open('a') as out: out.write(args[2]+'\n')
elif args[:2] == ['pr', 'close']:
    pr=args[2]
    if (p/'close-fails').exists(): sys.exit(1)
    d=json.loads(data(pr).read_text()); d['state']='CLOSED'
    if (p/'advance-close').exists():
        oid=(p/'advance-close').read_text().strip(); (p/'advance-close').unlink()
        subprocess.run([os.environ['SID_TEST_REAL_GIT'],'push','-q','origin',oid+':refs/heads/'+d['headRefName']],check=True)
        d['headRefOid']=oid
    data(pr).write_text(json.dumps(d))
    (p/f'close-comment-{pr}').write_text(args[args.index('--comment')+1])
elif args[:2] == ['pr', 'reopen']:
    d=json.loads(data(args[2]).read_text()); d['state']='OPEN'; data(args[2]).write_text(json.dumps(d))
elif args[:2] == ['pr', 'merge']:
    # This API must never land a train commit again.
    if '--disable-auto' not in args:
        (p/'unsafe-merge-api').touch()
    sys.exit(1)
else:
    sys.exit(1)
F
export SID_TEST_REAL_GIT=$(command -v git)
cat > "$t/bin/git" <<'F'
#!/usr/bin/env python3
import os, re, signal, subprocess, sys
from pathlib import Path
real=os.environ['SID_TEST_REAL_GIT']; args=sys.argv[1:]; p=Path(os.environ['T'])
if args and args[0]=='push' and any(a.startswith('--force-with-lease=refs/heads/main:') for a in args):
    oid=args[-1].split(':')[0]
    message=subprocess.check_output([real,'show','-s','--format=%B',oid],text=True)
    pr=re.search(r'^Sid-Train-PR: #(\d+) ',message,re.M)[1]
    flip=p/f'red-on-refuse-{pr}'
    if flip.exists():
        import json
        flip.unlink(); f=p/f'pr-{pr}.json'; d=json.loads(f.read_text()); d['statusCheckRollup']=[dict(name='ci',conclusion='FAILURE')]; f.write_text(json.dumps(d)); sys.exit(1)
    count=p/f'refuse-count-{pr}'
    if count.exists() and int(count.read_text()):
        count.write_text(str(int(count.read_text())-1)); sys.exit(1)
    if (p/'refuse-merge').exists(): sys.exit(1)
    drift=p/f'drift-on-merge-{pr}'
    if drift.exists():
        subprocess.run([real,'--git-dir='+str(p/'origin.git'),'update-ref','refs/heads/main',drift.read_text().strip()],check=True)
        drift.unlink()
        (p/'stale-candidate').write_text(oid)
    rc=subprocess.run([real,*args]).returncode
    if rc: sys.exit(rc)
    (p/f'merge-oid-{pr}').write_text(oid)
    with (p/'merge-calls').open('a') as f: f.write(pr+'\n')
    (p/f'message-{pr}').write_text(message)
    with (p/'merge-args').open('a') as f: f.write(message)
    if (p/'crash-after-merge').exists():
        (p/'crash-after-merge').unlink(); os.kill(os.getppid(),signal.SIGKILL)
    sys.exit(0)
if args and args[0]=='push' and args[-1]==':refs/heads/work11' and (p/'advance-cleanup').exists():
    import json
    oid=(p/'advance-cleanup').read_text().strip(); (p/'advance-cleanup').unlink()
    subprocess.run([real,'push','-q','origin',oid+':refs/heads/work11'],check=True)
    f=p/'pr-11.json'; d=json.loads(f.read_text()); d['headRefOid']=oid; f.write_text(json.dumps(d))
os.execv(real,[real,*args])
F
chmod +x "$t/bin/git"
chmod +x "$t/bin/gh"; export T=$t SID_TRAIN_INLINE=1
pr() { printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","reviewDecision":"","statusCheckRollup":%s,"headRefOid":"%s","headRefName":"work","baseRefName":"main","title":"t","body":"## Proof\\n%s 3 passed\\n## Review\\nApproved-Head: %s (Astra)\\n## Context\\n"}' "$1" "$head" "$head" "$head" > "$t/pr.json"; }
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
rm -f "$stamp"; pr '[]'; git checkout -q main; printf ': > "$SID_FAILURE_IDENTITIES_OUT"\ncat "$T/after-gate" > "$T/pr.json"\n' > .sidstack/gate.sh; git add -A; git commit -qm flip; git push -q origin main; git checkout -q work
pr '[{"name":"ci","conclusion":"FAILURE"}]'; cp "$t/pr.json" "$t/after-gate"; pr '[]'; merge; ok "CI going red during the gate stops the merge" "$?" 1; ok "no merge happened" "$(merges)" 0
git checkout -q main; printf ': > "$SID_FAILURE_IDENTITIES_OUT"\nexit 0\n' > .sidstack/gate.sh; git add -A; git commit -qm ok; git push -q origin main; git checkout -q work; rm -f "$stamp"; pr '[]'; merge --check; ok "a clean PR is ready without a gate" "$?" 0; ok "--check never merges" "$(merges)" 0
"$here/sid-gate.sh" work >/dev/null; hash=$(sed -n 2p "$stamp" | sed 's/.*sha256 //'); [ -n "$hash" ] && [ "$(cut -d' ' -f1 < <(sha256sum ".git/sid-gate/logs/$head.$(git rev-parse origin/main).log"))" = "$hash" ]; ok "the kept log matches the recorded hash" "$?" 0
git checkout -q main; printf ': > "$SID_FAILURE_IDENTITIES_OUT"\ntouch "$T/gate-ran"\n' > .sidstack/gate.sh; git add -A; git commit -qm count; git push -q origin main; git checkout -q work; "$here/sid-gate.sh" work >/dev/null; rm -f "$t/gate-ran"; sed -i 2d "$stamp"; pr '[]'; merge --check; ok "--check ignores gate stamps" "$?" 0; [ -f "$t/gate-ran" ]; ok "--check did not run the gate" "$?" 1
pr '[]'
git push -q origin "$head~1:refs/heads/parent"; pr '[]'; sed -i 's/"baseRefName":"main"/"baseRefName":"parent"/' "$t/pr.json"
merge --check; ok "a stacked PR reports blocked readiness" "$?" 1; grep -q "blocked dependency" "$t/out"; ok "and says it is stacked" "$?" 0
merge; ok "a stacked PR doesn't merge" "$?" 1; grep -q "must land on main first" "$t/out"; ok "and says what to do" "$?" 0; ok "no merge happened" "$(merges)" 0
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
  cd "$T/repo" || exit 1; fixture_repo; mkdir .sidstack
  cat > .sidstack/gate.sh <<'G'
# Retry receipts can be coarse while comparison identities are per-case.
[ -f "$T/no-identities" ] || : > "$SID_FAILURE_IDENTITIES_OUT"
comparison_failure() {
  [ ! -f "$SID_FAILURE_IDENTITIES_OUT" ] || printf '%s\n' "$1" >> "$SID_FAILURE_IDENTITIES_OUT"
}
run_tests() {
  local name identity case_name bad=0
  local native_rows=${SID_EXECUTION_RECEIPTS_OUT:-$T/unused}.rows
  [ -z "${SID_EXECUTION_RECEIPTS_OUT:-}" ] || : > "$native_rows"
  for identity in "$@"; do
    name=${identity%%::*}
    [ -f "$name" ] || continue
    local status=passed executed=1 skipped=0
    case "$(cat "$name")" in
      fail) echo "$name" >> "$SID_FAILURES_OUT"; comparison_failure "$name"; bad=1; status=failed;;
      casefail) echo "$name" >> "$SID_FAILURES_OUT"; comparison_failure "$name::old%20case"; bad=1; status=failed;;
      skip) status=skipped; executed=0; skipped=1;;
      opaque-flaky) [ -f "$T/ran-$name" ] || { touch "$T/ran-$name"; echo "$name" >> "$SID_FAILURES_OUT"; comparison_failure "$name"; bad=1; };;
      flaky) [ -f "$T/ran-$name" ] || { touch "$T/ran-$name"; echo "$name" >> "$SID_FAILURES_OUT"; comparison_failure "$name::flaky-case"; bad=1; };;
    esac
    if [ -n "${SID_EXECUTION_RECEIPTS_OUT:-}" ]; then
      case_name='old case'
      case "$(cat "$name")" in wrongcase) case_name='different case';; flaky) case_name='flaky-case';; esac
      printf '{"file":"%s/%s","name":"%s","state":"%s"}\n' "$PWD" "$name" "$case_name" "$status" >> "$native_rows"
    fi
  done
  if [ -n "${SID_EXECUTION_RECEIPTS_OUT:-}" ] && [ ! -f "$T/no-receipts" ]; then
    python3 - "$native_rows" <<'E'
import json,os,sys
from pathlib import Path
from urllib.parse import quote
rows=[json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
requested=set(Path(os.environ['SID_RERUN']).read_text().splitlines())
receipts=[]
for row in rows:
 file=str(Path(row['file']).relative_to(Path.cwd()))
 identity=file+'::'+quote(row['name'],safe="-_.!~*'()")
 receipts.append(dict(identity=identity,scope='case',status=row['state'],executed=int(row['state']!='skipped'),skipped=int(row['state']=='skipped')))
for file in sorted({str(Path(row['file']).relative_to(Path.cwd())) for row in rows} & requested):
 tests=[r for r in rows if str(Path(r['file']).relative_to(Path.cwd()))==file]
 passed=all(r['state']=='passed' for r in tests)
 receipts.append(dict(identity=file,scope='file',status='passed' if passed else 'skipped',executed=sum(r['state']!='skipped' for r in tests),skipped=sum(r['state']=='skipped' for r in tests)))
mode=Path(os.environ['T'])/'bad-receipt'
mode=mode.read_text().strip() if mode.exists() else ''
if mode=='zero':
 for row in receipts: row['executed']=0
elif mode=='scope':
 for row in receipts: row['scope']='file' if row['scope']=='case' else 'case'
elif mode=='duplicate': receipts += receipts[:1]
elif mode=='incomplete':
 for row in receipts: row['status']='incomplete'
output=Path(os.environ['SID_EXECUTION_RECEIPTS_OUT'])
output.write_text('not-json\n' if mode=='malformed' else ''.join(json.dumps(row)+'\n' for row in receipts))
E
  fi
  return "$bad"
}
if [ -n "${SID_RERUN:-}" ]; then
  if [ -f "$T/vacuous-retry" ]; then
    : > "$SID_FAILURE_IDENTITIES_OUT"; : > "$SID_FAILURES_OUT"; exit 0
  fi
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
  if [ -f "$T/cancel-worker" ]; then
    python3 -c 'import os,signal,time; from pathlib import Path; p=Path(os.environ["T"]); signal.signal(signal.SIGTERM, lambda *_: (time.sleep(.2), (p/"worker-stopped").touch(), exit(0))); (p/"child-ready").touch(); signal.pause()' &
    while [ ! -f "$T/child-ready" ]; do sleep .05; done
  fi
  echo $$ > "$T/gate-pid"
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
json.dump(dict(state='OPEN', isDraft=False, mergeable='MERGEABLE', reviewDecision='', statusCheckRollup=[], number=int(n), headRefOid=h, headRefName='work'+n, baseRefName='main', title='change '+n, body=f'## Proof\n{h} 3 passed\n## Review\nApproved-Head: {h} (Astra)\n## Context\n'), open(p, 'w'))
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
ok "each member has its own gate" "$(count_gates)" 2
ok "each gate sees its own diff against current main" "$(tr '\n' '|' < "$T/gate-diffs")" 'a |b |'

ok "first member merged" "$(code 11)" 0; ok "second member merged" "$(code 12)" 0
for n in 11 12; do
  tree=$(git rev-parse "$(cat "$T/merge-oid-$n")^{tree}")
  grep -qx "$tree" "$T/gated-trees"; ok "landed prefix #$n was gated" "$?" 0
done
ok "merges follow queue order" "$(tr '\n' ' ' < "$T/merge-calls")" '11 12 '
for n in 11 12; do
  grep -Eq "^Gate-Passed: train [0-9]+, main [a-f0-9]{8} \+ #${n}, lane fast, log sha256 [a-f0-9]{64}$" "$T/message-$n"
  ok "#$n squash carries both members and the reported lane" "$?" 0
  grep -q '^Agent: writer' "$T/message-$n"; ok "#$n preserves branch trailers" "$?" 0
done
[ ! -d "$T/worker" ]; ok "merged member worktree is removed" "$?" 0
git show-ref --verify --quiet refs/heads/work11; ok "merged member local branch is removed" "$?" 1
git ls-remote --exit-code origin refs/heads/work11 >/dev/null; ok "merged member remote branch is removed" "$?" 2
ok "mode SID_LANE reaches each gate" "$(sort -u "$T/lane-input")" full
sha=$(git rev-parse origin/main); ok "matching merged tree records health" "$(head -n 1 "$health/$sha")" 'pass fast'
log=$(sed -n 2p "$health/$sha"); digest=$(sha256sum "$log" | cut -d' ' -f1)
grep -q "log sha256 $digest$" "$T/message-12"; ok "train trailer authenticates kept gate log" "$?" 0
"$here/sid-health.sh" > "$T/health-out"; ok "fast health is checked in full" "$(count_gates)" 3
# The gate reports what it actually ran; stop overriding the health lane here.
rm "$T/reported-lane"; "$here/sid-health.sh" > "$T/health-out"; ok "health with no lane reports full" "$(head -n 1 "$health/$sha")" 'pass full'
before=$(count_gates); "$here/sid-health.sh" > "$T/health-out"; ok "full passing health skips" "$(count_gates)" "$before"
python3 - "$q/state.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); sys.exit(not (s['phase'] == 'idle' and s['members'] == [] and len(s['main']) == 40))
PY
ok "drained runner publishes idle" "$?" 0
ok "batch history records a merged train" "$(sort -u "$q/history.tsv" | cut -f6 | sort -u)" merged
setup_train split
add_pr 11 good; add_pr 12 bad; queue_pr 11; queue_pr 12; run_train
ok "failure cannot bypass a prefix gate" "$(count_gates)" 2
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
p['body'] = f'## Proof\n{sys.argv[2]} 3 passed\n## Review\nApproved-Head: {sys.argv[2]} (Astra)\n## Context\n'
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
setup_train required-context
# The PR predates the policy: its tree has no required-checks file.
add_pr 11 a
git checkout -q main; printf 'Harness\n' > .sidstack/required-checks
git add -A; git commit -qm policy; git push -q origin main
queue_pr 11; ok "missing default-branch required check refuses enqueue" "$?" 1
[ ! -f "$q/queue/11.req" ]; ok "missing check leaves no request" "$?" 0
python3 - "$T/pr-11.json" <<'PYTEST'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d['statusCheckRollup'] = [dict(name='Harness', conclusion='SUCCESS')]
open(p, 'w').write(json.dumps(d))
PYTEST
queue_pr 11; ok "successful required check allows enqueue" "$?" 0
run_train; ok "required-check policy survives the PR tree without it" "$(code 11)" 0
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
# Cancel a real worker, including a hard-killed wrapper; recover its durable request on restart.
for cancellation in TERM KILL; do
  setup_train "worker-$cancellation"
  add_pr 11 a; touch "$T/block-train" "$T/cancel-worker"
  "$here/sid-gate.sh" work11 > "$T/plain-out" 2>&1 & gp=$!
  for ((j=0; j<200; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
  [ -f "$T/train-started" ]; ok "plain gate $cancellation reached worker" "$?" 0
  kill -"$cancellation" "$gp"; wait "$gp" 2>/dev/null || true
  timeout 10 flock .git/sid-gate/lock true
  ok "plain gate $cancellation releases lock after cleanup" "$?" 0
  [ ! -f .git/sid-gate/work11.pass ]; ok "cancelled plain gate has no pass" "$?" 0
  old_worker=$(cat "$T/gate-pid")
  [ ! -e "/proc/$old_worker/stat" ] || [ "$(awk '{print $3}' "/proc/$old_worker/stat")" = Z ]
  ok "plain gate $cancellation stops its worker" "$?" 0
  [ -f "$T/worker-stopped" ]; ok "plain gate $cancellation lets descendants finish cleanup" "$?" 0
  rm -f "$T/cancel-worker" "$T/child-ready" "$T/worker-stopped"
  rm -f "$T/train-started"
  queue_pr 11
  "$here/sid-train.sh" > "$T/worker-out" 2>&1 & rp=$!
  for ((j=0; j<200; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
  [ -f "$T/train-started" ]; ok "worker $cancellation reached gate" "$?" 0
  kill -"$cancellation" "$rp"; wait "$rp" 2>/dev/null || true
  # A new train can acquire both locks only after the old command group stops.
  rm -f "$T/block-train"
  timeout 20 "$here/sid-train.sh" > "$T/restarted-out" 2>&1
  ok "worker $cancellation restart drains request" "$?" 0
  ok "worker $cancellation durable request merges" "$(code 11)" 0
  [ ! -e "$q/active/11" ]; ok "worker $cancellation clears active claim" "$?" 0
  flock -n .git/sid-gate/lock true; ok "worker $cancellation releases gate lock" "$?" 0
done
# A dead supervisor/runner must not unlock a surviving gate body.
for casualty in worker group holder all; do
  setup_train "killed-$casualty"
  add_pr 11 a; queue_pr 11; touch "$T/block-train" "$T/cancel-worker"
  setsid "$here/sid-train.sh" > "$T/worker-out" 2>&1 & rp=$!
  for ((j=0; j<200; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
  [ -f "$T/train-started" ]; ok "$casualty kill reached body" "$?" 0
  body=$(cat "$T/gate-pid")
  helper=$(awk '{print $4}' "/proc/$body/stat")
  holder=$(python3 -c 'import json; print(json.load(open(".git/sid-gate/lease.json"))["holder"][0])')
  if [ "$casualty" = group ]; then kill -KILL -- "-$rp"
  elif [ "$casualty" = all ]; then kill -KILL "$holder"; kill -KILL -- "-$rp"
  elif [ "$casualty" = holder ]; then kill -KILL "$holder"
  else kill -KILL "$helper"; fi
  wait "$rp" 2>/dev/null || true
  if [ "$casualty" != holder ]; then
    kill -0 "$body"; ok "$casualty kill leaves body alive" "$?" 0
  fi
  if [ "$casualty" != holder ] && [ "$casualty" != all ]; then
    flock -n .git/sid-gate/lock true
    ok "$casualty kill keeps lock while body lives" "$?" 1
  fi
  [ ! -f "$q/result/11" ]; ok "$casualty kill never accepts an unconfirmed gate" "$?" 0
  # No manual process cleanup: the lease holder or next runner must reclaim it.
  timeout 10 bash -c 'source "$1/sid-gate-lib.sh"; gate_repo; exec 9>"$gate/lock"; gate_lock' bash "$here"
  ok "$casualty kill releases lock only after body cleanup" "$?" 0
  [ -f "$T/worker-stopped" ]; ok "$casualty kill allows descendant cleanup" "$?" 0
  rm -f "$T/block-train" "$T/cancel-worker" "$T/child-ready" "$T/worker-stopped"
  timeout 20 "$here/sid-train.sh" > "$T/restarted-out" 2>&1
  ok "$casualty kill restart drains durable queue" "$?" 0
  ok "$casualty kill restarted request merges" "$(code 11)" 0
done
# Recovery must ignore unrelated non-dumpable processes and drain even an
# orphaned setsid descendant whose environment is unreadable.
setup_train nondumpable-recovery
mkdir -p "$q"
cat > "$T/nondump.py" <<'PYTEST'
import ctypes, os, signal, sys
from pathlib import Path
os.setsid()
# A production-like process name must not turn the unrelated sentinel into a target.
assert ctypes.CDLL(None).prctl(15, b'sid-train.sh', 0, 0, 0) == 0
assert ctypes.CDLL(None).prctl(4, 0, 0, 0, 0) == 0
if len(sys.argv) > 2:
    signal.signal(signal.SIGTERM, lambda *_: Path(sys.argv[2]).touch())
else:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()))
while True:
    signal.pause()
PYTEST
cat > "$T/body.sh" <<'BODY'
echo $$ > "$T/body-pid"
python3 "$T/nondump.py" "$T/descendant-pid" &
while :; do sleep 1; done
BODY
setsid bash -c '
  exec 12>.git/sid-gate/lock; flock 12
  exec env SID_GATE_LOCK_FD=12 python3 "$1/gate_worker.py" "$$" --lease-v2 bash "$T/body.sh"
' bash "$here" > "$T/nondump-out" 2>&1 & wp=$!
for ((j=0; j<200; j++)); do
  [ -f "$T/descendant-pid" ] && break
  sleep .05
done
[ -f "$T/descendant-pid" ]; ok "non-dumpable real descendant started" "$?" 0
python3 "$T/nondump.py" "$T/unrelated-pid" "$T/unrelated-signaled" & unrelated=$!
for ((j=0; j<200; j++)); do [ -f "$T/unrelated-pid" ] && break; sleep .05; done
descendant=$(cat "$T/descendant-pid")
python3 - "$descendant" "$unrelated" <<'PYTEST'
import sys
from pathlib import Path
for pid in sys.argv[1:]:
    try:
        Path('/proc', pid, 'environ').read_bytes()
    except PermissionError:
        continue
    raise AssertionError('fixture environment is readable')
PYTEST
ok "both same-uid non-dumpable environments deny access" "$?" 0
python3 - "$descendant" "$unrelated" <<'PYTEST'
import json, os, sys
from pathlib import Path
record = json.loads(Path('.git/sid-gate/lease.json').read_text())
group = Path(record['cgroup'])
members = {int(pid) for procs in group.rglob('cgroup.procs') for pid in procs.read_text().split()}
root = int(Path(os.environ['T'], 'body-pid').read_text())
assert {root, int(sys.argv[1])} <= members
assert int(sys.argv[2]) not in members
for member in members:
    pid, seen = member, set()
    while pid != root:
        assert pid > 1 and pid not in seen, ('non-fixture cgroup member', member)
        seen.add(pid)
        try:
            pid = int(Path('/proc', str(pid), 'stat').read_bytes().rsplit(b') ', 1)[1].split()[1])
        except FileNotFoundError:
            break  # A short-lived fixture sleep can exit during the snapshot.
PYTEST
ok "cleanup cgroup contains only fixture descendants, never the unrelated train sentinel" "$?" 0
holder=$(python3 -c 'import json; print(json.load(open(".git/sid-gate/lease.json"))["holder"][0])')
kill -KILL "$holder"; kill -KILL -- "-$wp"; wait "$wp" 2>/dev/null || true
timeout 10 bash -c 'source "$1/sid-gate-lib.sh"; gate_repo; exec 9>"$gate/lock"; gate_lock' bash "$here" > "$T/recovery-out" 2>&1
ok "non-dumpable unrelated process does not break crash recovery" "$?" 0
[ ! -e "/proc/$descendant/stat" ] || [ "$(awk '{print $3}' "/proc/$descendant/stat")" = Z ]
ok "crash recovery kills orphaned non-dumpable setsid descendant" "$?" 0
[ ! -e "$T/unrelated-signaled" ] && kill -0 "$unrelated"; ok "crash recovery never signals unrelated non-dumpable process" "$?" 0
kill -KILL "$unrelated" "$descendant" 2>/dev/null || true
wait "$unrelated" 2>/dev/null || true
kill -KILL -- "-$(cat "$T/body-pid")" 2>/dev/null || true
# A setsid escaper is reclaimed and cannot inherit any lock. Use a
# nonstandard gate fd to prove the caller contract.
setup_train setsid-escape
mkdir -p "$q"
cat > "$T/escape.py" <<'PYTEST'
import ctypes, os, signal, sys
from pathlib import Path
os.setsid()
assert ctypes.CDLL(None).prctl(15, b"gate-\xff", 0, 0, 0) == 0
Path(sys.argv[1], "escaped-lock-env").write_text(os.environ.get('SID_GATE_LOCK_FD', ''))
locks = []
for fd in Path('/proc/self/fd').iterdir():
    try:
        target = os.readlink(fd)
        if target.endswith(('/lock', '/runner.lock', '/queue.lock')):
            locks.append(target)
    except FileNotFoundError:
        pass
Path(sys.argv[1], "escaped-locks").write_text('\n'.join(locks))
Path(sys.argv[1], "escaped-pid").write_text(str(os.getpid()))
signal.pause()
PYTEST
cat > "$T/body.sh" <<'BODY'
python3 "$T/escape.py" "$T" &
while [ ! -f "$T/escaped-pid" ]; do sleep .05; done
BODY
( exec 7>"$q/runner.lock" 8>"$q/queue.lock" 12>.git/sid-gate/lock
  flock 7; flock 8; flock 12
  exec env SID_GATE_LOCK_FD=12 python3 "$here/gate_worker.py" "$$" --lease-v2 bash "$T/body.sh"
) > "$T/escape-out" 2>&1 & wp=$!
for ((j=0; j<200; j++)); do [ -f "$T/escaped-pid" ] && break; sleep .05; done
[ -f "$T/escaped-pid" ]; ok "setsid descendant starts with non-UTF8 comm" "$?" 0
[ ! -s "$T/escaped-lock-env" ]; ok "body environment does not advertise the closed gate fd" "$?" 0
[ ! -s "$T/escaped-locks" ]; ok "body and setsid descendant inherit no gate, runner or queue locks" "$?" 0
wait "$wp"; ok "non-UTF8 proc names do not break cleanup" "$?" 0
escaped=$(cat "$T/escaped-pid")
[ ! -e "/proc/$escaped/stat" ] || [ "$(awk '{print $3}' "/proc/$escaped/stat")" = Z ]
ok "setsid descendant is stopped without operator cleanup" "$?" 0
flock -n "$q/runner.lock" true; ok "escaper does not retain runner lock" "$?" 0
flock -n "$q/queue.lock" true; ok "escaper does not retain queue lock" "$?" 0
flock -n .git/sid-gate/lock true; ok "escaper cannot retain gate lock" "$?" 0
timeout 10 flock .git/sid-gate/lock true; ok "gate lock releases after escaper exits" "$?" 0
# An open but unrelated lock must never authorize lease writes or a body.
( exec 12>"$T/unrelated-lock"; flock 12
  exec env SID_GATE_LOCK_FD=12 python3 "$here/gate_worker.py" "$$" --lease-v2 bash -c 'touch "$T/wrong-fd-body"'
) > "$T/wrong-fd-out" 2>&1
ok "worker refuses an open fd for the wrong lock inode" "$?" 143
[ ! -e "$T/wrong-fd-body" ]; ok "wrong fd never starts a body" "$?" 0
[ ! -e "$T/lease.json" ]; ok "wrong fd never creates lease state beside an unrelated file" "$?" 0
# Inject an unreadable /proc entry after leader exit: keep the lock and the
# unreaped leader until observation recovers, without ever signalling a reused ID.
setup_train proc-error
mkdir -p .git/sid-gate
cat > "$T/proc-error.py" <<'PYTEST'
import os, runpy, sys
from pathlib import Path
root, worker, owner = sys.argv[1:]
root = Path(root)
sys.path.insert(0, str(Path(worker).parent))
read = Path.read_bytes
killpg = os.killpg
def read_stat(path, *args, **kwargs):
    if str(path) == "/proc/1/stat" and (root/"deny-proc").exists():
        (root/"proc-error-seen").touch()
        raise PermissionError("injected unreadable /proc")
    return read(path, *args, **kwargs)
def send(pgid, sig):
    # ECHILD here would prove the supervisor had already reaped its leader.
    os.waitid(os.P_PID, pgid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    (root/"unreaped-signal").touch()
    return killpg(pgid, sig)
Path.read_bytes = read_stat
os.killpg = send
sys.argv = [worker, owner, "--lease-v2", "bash", "-c", "exit 0"]
runpy.run_path(worker, run_name="__main__")
PYTEST
touch "$T/deny-proc"
( exec 9>.git/sid-gate/lock; flock 9; exec env SID_GATE_LOCK_FD=9 python3 "$T/proc-error.py" "$T" "$here/gate_worker.py" "$$" ) > "$T/proc-out" 2>&1 & wp=$!
for ((j=0; j<200; j++)); do [ -f "$T/proc-error-seen" ] && break; sleep .05; done
[ -f "$T/proc-error-seen" ]; ok "unreadable proc scenario reached cleanup" "$?" 0
flock -n .git/sid-gate/lock true; ok "unknown proc state retains lock" "$?" 1
kill -0 "$wp"; ok "unknown proc state keeps supervisor alive" "$?" 0
rm "$T/deny-proc"; wait "$wp"; ok "proc recovery completes cleanup" "$?" 0
[ -f "$T/unreaped-signal" ]; ok "group signals happen before leader reap" "$?" 0
flock -n .git/sid-gate/lock true; ok "proc recovery releases lock" "$?" 0
# Simulated reused PID/start identity must not signal the unrelated live process.
setup_train reused-identity
mkdir -p .git/sid-gate
add_pr 11 a
sleep 60 & unrelated=$!
python3 - "$unrelated" <<'PYTEST'
import json, sys, time
from pathlib import Path
who = [int(sys.argv[1]), "999999999999", Path('/proc/sys/kernel/random/boot_id').read_text().strip()]
Path('.git/sid-gate/lease.json').write_text(json.dumps(dict(owner=who, supervisor=who,
    boot=who[2], expires=time.clock_gettime(time.CLOCK_BOOTTIME)+.2, attempt='retired-attempt')))
PYTEST
timeout 10 "$here/sid-gate.sh" work11 > "$T/out" 2>&1
ok "restart rejects reused PID identity and gates safely" "$?" 0
kill -0 "$unrelated"; ok "stale PID and PGID cannot kill unrelated process" "$?" 0
kill "$unrelated"; wait "$unrelated" 2>/dev/null || true
# A stale writer remains confined to the abandoned attempt's index and files.
setup_train fenced-tree
add_pr 11 a; touch "$T/block-train"
"$here/sid-gate.sh" work11 > "$T/out" 2>&1 & gp=$!
for ((j=0; j<200; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
body=$(cat "$T/gate-pid")
old_verify=$(readlink "/proc/$body/cwd")
kill -KILL "$gp"; wait "$gp" 2>/dev/null || true
rm "$T/block-train"
# Mutate the abandoned index before recovery; it must not reach the next gate.
echo stale > "$old_verify/stale"; git -C "$old_verify" add stale
timeout 10 "$here/sid-gate.sh" work11 > "$T/restarted-out" 2>&1
ok "new verification completes while abandoned cwd is being changed" "$?" 0
[ -f .git/sid-gate/work11.pass ]; ok "fenced replacement records only confirmed pass" "$?" 0
[ ! -d "$old_verify" ]; ok "recovery reclaims the abandoned mutable tree" "$?" 0
ok "replacement hashes the expected tree despite stale index writes" "$(tail -n 1 "$T/gated-trees")" "$(git rev-parse 'work11^{tree}')"
# Cached pre-lease shell functions load the newly installed worker. They must
# recover the inherited lease and refuse the old shared-checkout protocol.
setup_train mixed-version
add_pr 11 a; touch "$T/block-train"
# Frozen pre-lease library from sstack #19, with only its worker path relocated.
cp "$here/fixtures/gate-lib-pre-lease.sh" "$T/old-lib.sh"
cat > "$T/old-waiter.sh" <<'OLD'
source "$T/old-lib.sh"
gate_worker=$1/gate_worker.py
gate_repo
exec 9>"$gate/lock"
flock 9
touch "$T/old-acquired"
gate_tree "$(git rev-parse origin/main)" "$(git rev-parse 'work11^{tree}')" "$T/old-log" old
OLD
setsid "$here/sid-gate.sh" work11 > "$T/first-out" 2>&1 & gp=$!
for ((j=0; j<200; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
body=$(cat "$T/gate-pid"); helper=$(awk '{print $4}' "/proc/$body/stat")
holder=$(python3 -c 'import json; print(json.load(open(".git/sid-gate/lease.json"))["holder"][0])')
bash "$T/old-waiter.sh" "$here" > "$T/old-out" 2>&1 & old=$!
kill -KILL "$holder"; kill -KILL -- "-$gp"; wait "$gp" 2>/dev/null || true
wait "$old"; ok "cached old library fails closed with new worker" "$?" 143
[ -f "$T/old-acquired" ]; ok "real old waiter acquired the released inherited flock" "$?" 0
[ ! -e "/proc/$body/stat" ] || [ "$(awk '{print $3}' "/proc/$body/stat")" = Z ]
ok "old waiter reconciles the abandoned workload before refusing" "$?" 0
ok "mixed rollout never starts a second body" "$(count_gates)" 1
[ ! -f .git/sid-gate/work11.pass ]; ok "mixed rollout never records an unconfirmed pass" "$?" 0
rm "$T/block-train"
"$here/sid-gate.sh" work11 > "$T/restarted-out" 2>&1
ok "fresh library gates after rejecting cached caller" "$?" 0
# Startup crashes must leave neither an untracked cgroup nor a gate body.
# Faults bracket real mkdir and lease publication; recovery uses real admission.
for boundary in publish before-mkdir after-mkdir; do
  setup_train "startup-$boundary"
  mkdir -p "$q"
  cat > "$T/crash-startup.py" <<'PYTEST'
import os, runpy, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gate_lease
worker = str(Path(sys.argv[1], 'gate_worker.py'))
boundary = sys.argv[2]
observed = Path(os.environ['T'], 'startup-cgroup')
mkdir = Path.mkdir

def fail_mkdir(path, *args, **kwargs):
    if path.name.startswith('sid-gate-'):
        observed.write_text(str(path))
        if boundary == 'before-mkdir':
            os._exit(143)
        mkdir(path, *args, **kwargs)
        os._exit(143)
    return mkdir(path, *args, **kwargs)

def fail_write(path, record):
    observed.write_text(record['cgroup'])
    raise OSError('injected lease publication failure')

if boundary == 'publish':
    gate_lease.write = fail_write
else:
    Path.mkdir = fail_mkdir
sys.argv = [worker, str(os.getpid()), '--lease-v2',
            'bash', '-c', 'touch "$T/startup-body"']
runpy.run_path(worker, run_name='__main__')
PYTEST
  ( exec 12>.git/sid-gate/lock; flock 12
    exec env SID_GATE_LOCK_FD=12 python3 "$T/crash-startup.py" "$here" "$boundary"
  ) > "$T/startup-out" 2>&1
  ok "startup $boundary fails closed" "$?" 143
  [ ! -e "$T/startup-body" ]; ok "startup $boundary never executes workload" "$?" 0
  timeout 10 bash -c 'source "$1/sid-gate-lib.sh"; gate_repo; exec 9>"$gate/lock"; gate_lock' bash "$here" > "$T/startup-recovery-out" 2>&1
  ok "startup $boundary recovery admits next runner" "$?" 0
  [ ! -d "$(cat "$T/startup-cgroup")" ]; ok "startup $boundary leaves no cgroup directory" "$?" 0
  [ ! -f .git/sid-gate/lease.json ]; ok "startup $boundary recovery retires lease" "$?" 0
  # Also clean the known empty fixture directory when exercising the broken code.
  rmdir "$(cat "$T/startup-cgroup")" 2>/dev/null || true
done
# Repeated cancellation and recovery leave neither checkouts nor registrations.
setup_train bounded-checkouts
add_pr 11 a
for cycle in 1 2 3; do
  touch "$T/block-train"; rm -f "$T/train-started"
  "$here/sid-gate.sh" work11 > "$T/out" 2>&1 & gp=$!
  for ((j=0; j<200; j++)); do [ -f "$T/train-started" ] && break; sleep .05; done
  [ -f "$T/train-started" ]; ok "crash cycle $cycle reaches its registered checkout" "$?" 0
  body=$(cat "$T/gate-pid"); old_verify=$(readlink "/proc/$body/cwd")
  kill -KILL "$gp"; wait "$gp" 2>/dev/null || true
  rm "$T/block-train"
  "$here/sid-gate.sh" work11 > "$T/recovered-out" 2>&1
  ok "crash cycle $cycle recovers" "$?" 0
  [ ! -d "$old_verify" ]; ok "crash cycle $cycle reclaims checkout data" "$?" 0
  ok "crash cycle $cycle keeps worktree registrations bounded" "$(git worktree list --porcelain | rg -c '^worktree ')" 1
  ok "crash cycle $cycle retires ownership manifests" "$(find .git/sid-gate/attempts -name '*.json' | wc -l)" 0
done
# Setup can fail before a body exists: its checkout still must be reclaimed.
( source "$here/sid-gate-lib.sh"; gate_repo; exec 9>"$gate/lock"; gate_lock
  gate_tree "$(git rev-parse origin/main)" missing-tree "$T/setup-out" invalid ) > "$T/setup-error" 2>&1
ok "invalid setup fails" "$?" 1
ok "setup failure leaves no registered attempt checkout" "$(git worktree list --porcelain | rg -c '^worktree ')" 1
# A reboot fixture injects only the boot ID read, keeping the real processes,
# flock, manifests, Git worktrees and repair entry point intact.
"$here/sid-gate-recover.sh" --pause > "$T/pause-out"
printf '{broken' > .git/sid-gate/lease.json
"$here/sid-gate-recover.sh" --after-reboot > "$T/repair-out" 2>&1
ok "corrupt-state repair refuses same-boot workload assumptions" "$?" 1
"$here/sid-gate.sh" work11 > "$T/paused-out" 2>&1
ok "paused admission rejects new gates" "$?" 1
[ "$(cat .git/sid-gate/lease.json)" = '{broken' ]; ok "failed repair preserves corrupt evidence" "$?" 0
# Create an abandoned registered checkout as if the host stopped during setup.
python3 - "$here" <<'PYTEST'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import gate_lease as lease
# Prepare without parsing the deliberately corrupt admission state.
manifest = Path('.git/sid-gate/attempts/' + 'a'*32 + '.json')
checkout = str(Path.cwd()) + '-wt/verify-' + 'a'*32
lease.write(manifest, dict(owner=lease.identity(__import__('os').getpid()), checkout=checkout))
lease.subprocess.run(['git', 'worktree', 'add', '-q', '--detach', checkout, 'HEAD'], check=True)
PYTEST
cat > "$T/reboot.py" <<'PYTEST'
import runpy, sys
from pathlib import Path
read = Path.read_text
def boot(path, *args, **kwargs):
    if str(path) == '/proc/sys/kernel/random/boot_id':
        return 'fixture-next-boot'
    return read(path, *args, **kwargs)
Path.read_text = boot
sys.argv = [sys.argv[1], *sys.argv[2:]]
runpy.run_path(sys.argv[0], run_name='__main__')
PYTEST
repo_dir=$(pwd); gate_dir="$repo_dir/.git/sid-gate"
( exec 9>.git/sid-gate/lock; flock 9
  python3 "$T/reboot.py" "$here/gate_lease.py" repair "$gate_dir" "$repo_dir" ) > "$T/reboot-out" 2>&1
ok "post-reboot repair quarantines corrupt state and reclaims checkout" "$?" 0
ok "reboot recovery leaves only the main checkout" "$(git worktree list --porcelain | rg -c '^worktree ')" 1
ok "corrupt state is quarantined once" "$(find .git/sid-gate -name 'lease.corrupt-*' | wc -l)" 1
[ ! -e .git/sid-gate/admission-paused ]; ok "successful repair resumes admission" "$?" 0
"$here/sid-gate.sh" work11 > "$T/repaired-gate" 2>&1
ok "fresh gate runs after corrupt-state repair" "$?" 0
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
before=$(count_gates); "$here/sid-health.sh" > "$T/out"; ok "failed full health is checked again" "$(count_gates)" "$((before+1))"
setup_train invalid-candidate
add_pr 11 bad; queue_pr 11; run_train; ok "empty failure identities never earn main-red forgiveness" "$(code 11)" 1
grep -q "candidate identity evidence" "$q/result/11"; ok "infrastructure result explains missing comparison proof" "$?" 0
queue_pr 11; ok "unproven infrastructure failure requires an explicit retry" "$?" 1
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
ok "temporary merge refusals do not add gates beyond one per PR" "$(count_gates)" 2
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
ok "compatible dependent squashes each get a gate" "$(count_gates)" 2
ok "both compatible dependent members merge" "$(code 11) $(code 12)" '0 0'
ok "dependent final squash matches the gated tree" "$(git rev-parse 'origin/main^{tree}')" "$(tail -n 1 "$T/gated-trees")"
# A main move inside the push, after every client precheck, rejects the old commit.
setup_train atomic-main-move
add_pr 11 a; queue_pr 11
expected=$(git rev-parse origin/main)
git checkout -q -b outside origin/main; echo outside > outside; git add -A; git commit -qm outside; git push -q origin outside
git rev-parse HEAD > "$T/drift-on-merge-11"; git checkout -q main
run_train
ok "atomic main race regates before landing" "$(count_gates)" 2
ok "regated PR lands once" "$(cat "$T/merge-calls")" 11
stale=$(cat "$T/stale-candidate")
git merge-base --is-ancestor "$stale" origin/main; ok "rejected ungated candidate never reaches main" "$?" 1
landed=$(cat "$T/merge-oid-11")
grep -qx "$(git rev-parse "$landed^{tree}")" "$T/gated-trees"; ok "atomic landing uses a gated tree" "$?" 0
[ ! -f "$T/unsafe-merge-api" ]; ok "no server squash API can substitute a newer main tree" "$?" 0
# A failed PR close leaves a recoverable receipt; retry never gates or lands twice.
setup_train close-recovery
add_pr 11 a; queue_pr 11; touch "$T/close-fails"
run_train; ok "close failure preserves pending recovery" "$?" 1
[ -f "$q/queue/11.req" ]; ok "close failure retains request" "$?" 0
timeout 5 "$here/sid-merge.sh" 11 > "$T/close-wait-out" 2>&1
ok "close pending returns to waiting caller without hanging" "$?" 1
ok "close pending publishes a terminal result" "$(code 11)" 1
rm "$T/close-fails"; run_train
ok "receipt recovers already landed commit" "$(code 11)" 0
ok "close recovery does not regate" "$(count_gates)" 1
ok "close recovery never pushes twice" "$(cat "$T/merge-calls")" 11
grep -q "$(cat "$T/merge-oid-11")" "$T/close-comment-11"; ok "closed PR names landing commit" "$?" 0
# Board/Kanzo consume validated receipts before classifying CLOSED PRs as scrapped.
python3 - "$here" "$T" <<'P'
import importlib.util,json,subprocess,sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]); spec=importlib.util.spec_from_file_location('board',Path(sys.argv[1])/'sid-board.py'); board=importlib.util.module_from_spec(spec); spec.loader.exec_module(board)
p=Path(sys.argv[2]); pr=json.loads((p/'pr-11.json').read_text()); assert pr['state']=='CLOSED'
def command(*args,**kw):
    if args[:3]==('gh','pr','list'): return json.dumps([pr])
    if args[:2]==('gh','api'): return '[]'
    return subprocess.check_output(args,**{k:v for k,v in kw.items() if k=='cwd'},text=True).strip()
board.command=command
repo=board.gather_github(str(p/'repo'),{'nameWithOwner':'o/r','defaultBranchRef':{'name':'main'}},[])
assert repo['prs'][0]['state']=='MERGED' and repo['prs'][0]['live']
card=dict(key='process#600',title='Work',status='review',tags=['pr-11'],comments=[],repo=str(p/'repo'))
actions,*_=board.reconcile(dict(cards=[card],projects=['process'],repos={str(p/'repo'):repo},threads=[]),{},2000000000)
assert any(a['kind']=='update' and a['fields'].get('status')=='done' for a in actions), actions
assert any(a['kind']=='comment' and 'Gate-Passed:' in a['body'] for a in actions), actions
P
ok "closed CAS PR is merged and done on Kanzo with gate proof" "$?" 0
# Only failures the change causes fail it: failed tests run again, then on main alone.
# Legacy requests cannot bypass declared dependencies after a failed parent.
for kind in stacked declared; do
  setup_train "dependency-$kind"
  add_pr 11 bad; add_pr 12 b
  python3 - "$T/pr-12.json" "$kind" <<'P'
import json,sys
p,kind=sys.argv[1:]; d=json.load(open(p))
if kind == 'stacked': d['baseRefName']='work11'
else: d['body'] += 'Depends-on: #11\n'
json.dump(d,open(p,'w'))
P
  queue_pr 12; ok "$kind blocks admission without parent" "$?" 1
  grep -q 'blocked dependency' "$T/out"; ok "$kind explains blocked dependency" "$?" 0
  queue_pr 11
  # Simulate a request queued by the old batching train, then drain its failed split.
  python3 - "$q/queue/12.req" "$T/pr-12.json" <<'P'
import json,sys,time
json.dump(dict(head=json.load(open(sys.argv[2]))['headRefOid'], queued=time.time_ns()),open(sys.argv[1],'w'))
P
  run_train
  ok "$kind failed parent never permits child gate across split" "$(count_gates)" 1
  [ ! -f "$T/merge-calls" ]; ok "$kind neither dependency nor dependent lands" "$?" 0
  # Repair parent, land it, and observe retarget + fresh child gate.
  git checkout -q work11; git rm -q bad; echo fixed > fixed; git add -A; git commit -qm repair; git push -q origin work11; record_pr 11; git checkout -q main
  queue_pr 11; run_train
  queue_pr 12; ok "$kind child admits after parent lands" "$?" 0
  run_train; ok "$kind child gets fresh gate and lands" "$(code 12)" 0
  ok "$kind parent and child each gated after repair" "$(count_gates)" 3
done
setup_train flaky
add_pr 11 test-a flaky; queue_pr 11; run_train
ok "a test that passes when run again doesn't fail the PR" "$(code 11)" 0
grep -q 'tests passed over: 1 flaky$' "$T/message-11"; ok "and the squash says a flaky test was passed over" "$?" 0
ok "running failed tests again is not another gate" "$(count_gates)" 1
setup_train known-failure
echo casefail > test-old; git add -A; git commit -qm red; git push -q origin main
add_pr 11 a; queue_pr 11; run_train
ok "main-red test blocks the unrelated PR" "$(code 11)" 4
[ -f "$health/main-red" ]; ok "main-red tests are durable" "$?" 0
queue_pr 11; ok "red main refuses unrelated admission" "$?" 4
grep -q "sid-health.sh --wait" "$T/out"; ok "red admission names audited stale-identity recovery" "$?" 0
for outcome in delete skip no-receipts wrong-case zero scope duplicate malformed incomplete; do
  case "$outcome" in delete) n=13;; skip) n=14;; no-receipts) n=15;; wrong-case) n=16;; zero) n=17;; scope) n=18;; duplicate) n=19;; malformed) n=20;; incomplete) n=21;; esac
  add_pr "$n" other
  git checkout -q work$n
  if [ "$outcome" = delete ]; then git rm -q test-old
  elif [ "$outcome" = skip ]; then echo skip > test-old
  elif [ "$outcome" = wrong-case ]; then echo wrongcase > test-old
  else echo fixed > test-old; fi
  git add -A; git commit -qm "claimed fix $outcome"; git push -q origin work$n; record_pr "$n"; git checkout -q main
  python3 - "$T/pr-$n.json" "$health/main-red" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['body'] += json.load(open(sys.argv[2]))['card']+' fix main\n'; json.dump(d,open(p,'w'))
P
  case "$outcome" in no-receipts) touch "$T/no-receipts";; zero|scope|duplicate|malformed|incomplete) echo "$outcome" > "$T/bad-receipt";; esac
  queue_pr "$n"; run_train
  ok "$outcome cannot clear red main" "$(code "$n")" 4
  [ -f "$health/main-red" ]; ok "$outcome retains the red block" "$?" 0
  [ ! -f "$T/merge-calls" ]; ok "$outcome fix never lands" "$?" 0
  rm -f "$T/no-receipts" "$T/bad-receipt"
done
add_pr 12 test-old fixed
python3 - "$T/pr-12.json" "$health/main-red" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); red=json.load(open(sys.argv[2])); d['body'] += red['card']+' fix main\n'; json.dump(d,open(p,'w'))
P
queue_pr 12; ok "named main fix may queue" "$?" 0
run_train; ok "named fix passes with unified encoded-case execution receipt" "$(code 12)" 0
[ ! -f "$health/main-red" ]; ok "green landed main clears red" "$?" 0
setup_train opaque-red-receipts
echo fail > test-old.test.ts; git add -A; git commit -qm red; git push -q origin main
add_pr 11 a; queue_pr 11; run_train
[ -f "$health/main-red" ]; ok "opaque baseline still records main-red" "$?" 0
python3 - "$health/main-red" <<'P'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); r=json.loads(p.read_text()); r['tests'].append('test-old.test.ts::old%20case'); p.write_text(json.dumps(r))
P
for value in skip scope fixed; do
  case "$value" in skip) n=12; content=skip;; scope) n=13; content=fixed; echo scope > "$T/bad-receipt";; fixed) n=14; content=fixed;; esac
  add_pr "$n" test-old.test.ts "$content"
  python3 - "$T/pr-$n.json" "$health/main-red" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['body'] += json.load(open(sys.argv[2]))['card']+' fix main\n'; json.dump(d,open(p,'w'))
P
  queue_pr "$n"; run_train
  if [ "$value" = fixed ]; then expected=0; else expected=4; fi
  ok "opaque $value requires a clean whole-file execution receipt" "$(code "$n")" "$expected"
  rm -f "$T/bad-receipt"
done
[ ! -f "$health/main-red" ]; ok "whole-file and case receipts together clear mixed main-red" "$?" 0
setup_train new-failure
echo casefail > test-old; git add -A; git commit -qm red; git push -q origin main
add_pr 11 test-new fail; queue_pr 11; run_train
ok "a test the PR breaks fails it, even on a red main" "$(code 11)" 1
grep -q '^test-new$' "$q/result/11"; ok "the result names the test the PR broke" "$?" 0
grep -q '^test-old::old%20case$' "$q/result/11"; ok "and leaves out main's own failure" "$?" 1
# #1010 keeps retry receipts separate from exact comparison identities.
for protocol in opaque opaque-package different-case same-case mixed-opaque missing-sidecar missing-main missing-retry empty-sidecar infrastructure infrastructure-populated unsupported-green; do
  setup_train "failure-identity-$protocol"
  cat > .sidstack/gate.sh <<'G'
  if [ -z "${SID_RERUN:-}" ]; then echo gate >> "$T/gates"; fi
  # These failures persist on retry: no identity is being recovered.
  [ -z "${SID_EXECUTION_RECEIPTS_OUT:-}" ] || : > "$SID_EXECUTION_RECEIPTS_OUT"
  value=$(cat test-shared)
  stage=${SID_FAILURE_IDENTITIES_OUT##*.log.}; stage=${stage%.identities}
  if [ ! -f "$T/no-identities" ] && ! { [ -f "$T/no-main-identities" ] && [ "$stage" = main ]; } &&
      ! { [ -f "$T/no-retry-identities" ] && [ "$stage" = retry ]; }; then
    : > "$SID_FAILURE_IDENTITIES_OUT"
  fi
  [ ! -f "$T/unsupported-green" ] || exit 0
  # All retry receipts deliberately remain whole-file, even for safe known identities.
  echo test-shared >> "$SID_FAILURES_OUT"
  if [ -f "$T/infra-populated" ] && [ "$stage" = candidate ]; then
    echo test-shared::old%20case >> "$SID_FAILURE_IDENTITIES_OUT"; exit 124
  fi
  if [ -f "$T/infra-main" ] && [ "$stage" = main ]; then
    : > "$SID_FAILURE_IDENTITIES_OUT"; exit 124
  fi
  if [ -f "$SID_FAILURE_IDENTITIES_OUT" ] && [ ! -f "$T/empty-identities" ]; then
    case "$value" in
      opaque) echo test-shared >> "$SID_FAILURE_IDENTITIES_OUT";;
      package) echo package:fixture >> "$SID_FAILURE_IDENTITIES_OUT";;
      old) echo 'test-shared::old%20case' >> "$SID_FAILURE_IDENTITIES_OUT";;
      new) echo 'test-shared::new%20case' >> "$SID_FAILURE_IDENTITIES_OUT";;
      mixed) printf 'test-shared::old%%20case\ntest-shared\n' >> "$SID_FAILURE_IDENTITIES_OUT";;
    esac
  fi
  exit 1
G
  baseline=old; candidate=old; expected=1
  case "$protocol" in
    opaque) baseline=opaque; candidate=opaque;;
    opaque-package) baseline=package; candidate=package;;
    different-case) candidate=new;;
    same-case) expected=4;;
    mixed-opaque) candidate=mixed;;
    missing-sidecar) touch "$T/no-identities";;
    missing-main) touch "$T/no-main-identities";;
    missing-retry) touch "$T/no-retry-identities";;
    empty-sidecar) touch "$T/empty-identities";;
    infrastructure) touch "$T/infra-main";;
    infrastructure-populated) touch "$T/infra-populated";;
    unsupported-green) touch "$T/no-identities" "$T/unsupported-green";;
  esac
  printf '%s\n' "$baseline" > test-shared
  git add -A; git commit -qm 'main has old red case'; git push -q origin main
  add_pr 11 test-shared "$candidate"; queue_pr 11; run_train
  ok "$protocol comparison follows #1010 identities" "$(code 11)" "$expected"
  [ ! -f "$T/merge-calls" ]; ok "$protocol never lands unverified PR" "$?" 0
  if [ "$protocol" = same-case ]; then
    grep -q '1 known cases failing on main' .git/sid-gate/logs/train-*.log; ok "exact case is known despite whole-file retry receipts" "$?" 0
    python3 - "$health/main-red" <<'P'
import json,sys
assert json.load(open(sys.argv[1]))['tests']==['test-shared::old%20case']
P
    ok "main-red records comparison identity rather than retry filename" "$?" 0
  elif [ "$protocol" = opaque ] || [ "$protocol" = mixed-opaque ]; then
    grep -qx test-shared "$q/result/11"; ok "$protocol component stays new even beside a known case" "$?" 0
  elif [ "$protocol" = opaque-package ]; then
    grep -qx package:fixture "$q/result/11"; ok "opaque package comparison never earns forgiveness" "$?" 0
  elif [ "$protocol" = different-case ]; then
    grep -qx 'test-shared::new%20case' "$q/result/11"; ok "different case in same file remains new" "$?" 0
    [ "$(cat .git/sid-gate/logs/train-*.log.retry.identities)" != "$(cat .git/sid-gate/logs/train-*.log.main.identities)" ]; ok "retry and main sidecars stay distinct" "$?" 0
  fi
done
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
# A reused health log cannot inherit a previous targeted rerun's failure list.
setup_train stale-red-health
echo fixed > test-old; git add -A; git commit -qm healthy; git push -q origin main
sha=$(git rev-parse origin/main)
mkdir -p "$health" .git/sid-gate/logs
printf '{"card":"process#600","tests":["test-old"]}\n' > "$health/main-red"
printf 'test-old\n' > ".git/sid-gate/logs/health-$sha.log.red-again"
printf 'fail full\nold-log\n' > "$health/$sha"
"$here/sid-health.sh" > "$T/out" 2>&1
ok "periodic health revisits red main and clears stale rerun failures" "$?" 0
[ ! -f "$health/main-red" ]; ok "fresh green health clears main-red marker" "$?" 0
printf '{broken' > "$health/main-red"
"$here/sid-health.sh" > "$T/out" 2>&1
ok "corrupt main-red evidence fails health closed" "$?" 1
[ -f "$health/main-red" ]; ok "corrupt evidence never clears the main-red block" "$?" 0
rm "$health/main-red"
add_pr 11 a
python3 - "$T/pr-11.json" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['body'] += 'Depends-on: #12, #13\n'; json.dump(d,open(p,'w'))
P
queue_pr 11; ok "malformed dependency declaration blocks admission" "$?" 1
setup_train dependency-cycles
add_pr 11 a; add_pr 12 b; add_pr 13 c
for cycle in self transitive; do
  python3 - "$T" "$cycle" <<'P'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); edges={11:11} if sys.argv[2]=='self' else {11:12,12:13,13:11}
for n in (11,12,13):
 f=p/f'pr-{n}.json'; d=json.load(f.open()); d['body']=d['body'].split('Depends-on:')[0] + (f'Depends-on: #{edges[n]}\n' if n in edges else ''); f.write_text(json.dumps(d))
P
  queue_pr 11; ok "$cycle cycle blocks admission" "$?" 1
  if [ "$cycle" = self ]; then expected='#11 -> #11'; else expected='#11 -> #12 -> #13 -> #11'; fi
  grep -q -- "$expected" "$T/out"; ok "$cycle reports cycle path" "$?" 0
done
# A branch advance after the close head read cannot be deleted by cleanup.
for race in close cleanup; do
  setup_train "branch-race-$race"
  add_pr 11 a; queue_pr 11
  git checkout -q work11; echo unlanded > unlanded; git add -A; git commit -qm unlanded
  newhead=$(git rev-parse HEAD); git checkout -q main
  printf '%s\n' "$newhead" > "$T/advance-$race"
  run_train
  ok "$race race preserves remote new head" "$(git ls-remote origin refs/heads/work11 | cut -f1)" "$newhead"
  ok "$race race preserves local new head" "$(git rev-parse refs/heads/work11)" "$newhead"
  python3 - "$T/pr-11.json" <<'P'
import json,sys
assert json.load(open(sys.argv[1]))['state']=='OPEN'
P
  ok "$race race leaves new PR work open" "$?" 0
  git cat-file -e origin/main:unlanded 2>/dev/null; ok "$race race never lands new ungated work" "$?" 128
done
# Recovered named cases are counted even when another case still fails.
setup_train partially-flaky
echo casefail > test-old; git add -A; git commit -qm red; git push -q origin main
add_pr 11 test-transient flaky; queue_pr 11; run_train
ok "persistent known case still blocks partially flaky candidate" "$(code 11)" 4
grep -q '1 flaky tests, 0 recovered opaque files, 1 known cases failing on main' .git/sid-gate/logs/train-*.log
ok "partial recovery counts named cases rather than retry files" "$?" 0
# Red-first: success with no selected/executed test cannot forgive a failed case.
setup_train vacuous-retry
add_pr 11 test-a casefail; touch "$T/vacuous-retry"; queue_pr 11; run_train
ok "vacuous retry fails the gate" "$(code 11)" 1
[ ! -f "$T/merge-calls" ]; ok "vacuous retry never lands failed case" "$?" 0
# An opaque file recovery is reported as a file, never as a named test.
setup_train recovered-opaque
add_pr 11 test-a opaque-flaky; queue_pr 11; run_train
ok "opaque retry with whole-file execution proof lands" "$(code 11)" 0
grep -q 'tests passed over: 1 recovered opaque files$' "$T/message-11"
ok "opaque recovery note reports files separately from tests" "$?" 0
# An API that keeps returning children must stop without deleting their base.
setup_train retarget-bounded
add_pr 11 a; add_pr 12 b
python3 - "$T/pr-12.json" <<'P'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['baseRefName']='work11'; json.dump(d,open(p,'w'))
P
touch "$T/stuck-retarget"; queue_pr 11; run_train
ok "parent remains landed when child retarget API will not settle" "$(code 11)" 0
ok "retarget attempts stop at five passes" "$(wc -l < "$T/retarget-edits" | tr -d ' ')" 5
git ls-remote --exit-code origin refs/heads/work11 >/dev/null
ok "retarget limit retains parent remote branch" "$?" 0
grep -q 'retargeting did not settle after 5 passes' "$T/runner-out"
ok "retarget exhaustion explains retained base" "$?" 0
# Exercise the real producer wrapper; only its check workload is substituted.
setup_train native-producer
cp "$here/../.sidstack/gate.sh" .sidstack/gate.sh
mkdir scripts; printf 'exit 0\n' > scripts/check.sh
SID_FAILURE_IDENTITIES_OUT="$T/native.identities" SID_FAILURES_OUT="$T/native.retry" SID_EXECUTION_RECEIPTS_OUT="$T/native.executed" bash .sidstack/gate.sh
ok "real sstack producer succeeds" "$?" 0
[ -f "$T/native.identities" ] && [ ! -s "$T/native.identities" ]; ok "real sstack producer supplies empty success identities" "$?" 0
git add -A; git commit -qm native-producer; git push -q origin main
add_pr 11 a; queue_pr 11; run_train
ok "real sstack gate path is accepted by train protocol" "$(code 11)" 0
# A failed full health check must block even when no diagnosis is possible.
setup_train undiagnosed-health
add_pr 11 a; touch "$T/no-identities" "$T/always-fail"
"$here/sid-health.sh" > "$T/out" 2>&1
ok "undiagnosed main health fails" "$?" 1
[ -f "$health/main-red" ]; ok "undiagnosed health persists admission block" "$?" 0
python3 - "$health/main-red" <<'P'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]); assert p.exists() and json.loads(p.read_text())['card']
P
ok "undiagnosed health links a repair card" "$?" 0
queue_pr 11; ok "undiagnosed health refuses unrelated PR" "$?" 4
rm "$T/no-identities" "$T/always-fail"
echo fast > "$T/reported-lane"
"$here/sid-health.sh" > "$T/fast-out" 2>&1
ok "fast evidence cannot clear undiagnosed full-health block" "$?" 1
[ -f "$health/main-red" ]; ok "incomplete recovery retains admission block" "$?" 0
rm "$T/reported-lane"
"$here/sid-health.sh" > "$T/green-out" 2>&1
ok "periodic health verifies recovered main" "$?" 0
sha=$(git rev-parse origin/main)
ok "recovered health is verified green" "$(head -n 1 "$health/$sha")" 'pass full'
[ ! -f "$health/main-red" ]; ok "verified green clears undiagnosed block" "$?" 0
queue_pr 11; ok "verified green reopens admission" "$?" 0
exit $fail
