#!/usr/bin/env bash
# Offline integration tests: actual git worktrees, bare origin and process groups.
set -eu
CM=${CM_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)/cm.sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export COUNCIL_HOME=$T/state SIDSTACK_MODELS=$T/models.md
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export REAL_GIT=$(command -v git)
mkdir "$T/bin"
export PATH=$T/bin:$PATH
cat > "$T/models.md" <<'MODELS'
- implementer: codex / fake-coder / high
- hardest tasks: codex / fake-hard / xhigh
- review panel: opencode / fake/panel-a / high; opencode / fake/panel-b / medium (notes)
- reviewer: codex / fake-reviewer / low (gate)
MODELS
cat > "$T/bin/codex" <<'FAKE'
#!/usr/bin/env bash
set -eu
out=''
if [ -n "${FAKE_PID_FILE:-}" ]; then
  [ "$(cat "$FAKE_PID_FILE")" = "$PPID" ] || exit 3
fi
while [ $# -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; shift 2; else shift; fi
done
cat >/dev/null
if [ "${FAKE_SLEEP:-0}" = 1 ]; then sleep 300; fi
printf '%s\n' "${FAKE_OUTPUT-VERDICT: APPROVE}" > "$out"
exit "${FAKE_RC:-0}"
FAKE
cat > "$T/bin/opencode" <<'FAKE'
#!/usr/bin/env bash
if [[ "$*" = *fake/panel-b* ]] && [ -n "${FAKE_DISSENT:-}" ]; then
  echo 'VERDICT: CHANGES'
else
  printf '%s\n' "${FAKE_OUTPUT-VERDICT: APPROVE}"
fi
exit "${FAKE_RC:-0}"
FAKE
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = 'pr list' ]; then echo 1
elif [ "${1:-} ${2:-}" = 'pr view' ]; then echo 'test change'
elif [ "${1:-} ${2:-}" = 'pr merge' ]; then
  if [ -n "${FAKE_MERGE_CALLS:-}" ]; then
    echo started >> "$FAKE_MERGE_CALLS"
    sleep 3
    echo merged >> "$FAKE_MERGE_CALLS"
  fi
  exit 0
else echo 'https://example.test/pull/1'; fi
FAKE
cat > "$T/bin/git" <<'FAKE'
#!/usr/bin/env bash
if [ "${FAKE_STAGE_EDIT:-}" = 1 ] && [ -z "${GIT_INDEX_FILE:-}" ] && [[ " $* " = *' add -A '* ]]; then
  echo stage-race >> "$2/file"
fi
if [ "${FAKE_MOVE_HEAD:-}" = 1 ] && [[ " $* " = *' push -q '* ]]; then
  moved=$(echo local-head-race | "$REAL_GIT" -C "$2" commit-tree 'HEAD^{tree}' -p HEAD)
  "$REAL_GIT" -C "$2" update-ref HEAD "$moved"
fi
"$REAL_GIT" "$@"; rc=$?
if [ "${FAKE_FIRST_PUSH:-}" = 1 ] && [[ " $* " = *' ls-remote --exit-code '* ]]; then
  "$REAL_GIT" --git-dir="$TEST_ORIGIN" update-ref "$TEST_BRANCH" "$TEST_BASE"
fi
exit "$rc"
FAKE
chmod +x "$T/bin/"*
git init -q --bare --initial-branch=main "$T/origin.git"
git init -q --initial-branch=main "$T/repo"
git -C "$T/repo" config user.email test@example.test
git -C "$T/repo" config user.name Test
printf '## Phase 1 — Tests\n### [ ] PR 1 — test (S)\nChange file.\n' > "$T/repo/PLAN.md"
echo base > "$T/repo/file"
git -C "$T/repo" add .
git -C "$T/repo" commit -qm base
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" push -q -u origin main
bash "$CM" init "$T/repo/PLAN.md" --gh test/repo --gate true --bot-review '' >/dev/null
S=$(bash "$CM" path)
export COUNCIL_STATE=$S
# Model settings refresh existing plans; explicit init flags pin them.
cp "$T/models.md" "$T/models.saved"
sed -i 's/fake-coder/fresh-coder/; s/fake-reviewer/fresh-reviewer/' "$T/models.md"
bash "$CM" path >/dev/null
python3 - "$S/config.json" <<'PYCODE'
import json,sys
c=json.load(open(sys.argv[1])); assert c['implementer']=='fresh-coder' and c['reviewer']=='fresh-reviewer'
assert c['reviewPanel'][1]['model']=='fake/panel-b'
PYCODE
bash "$CM" init "$T/repo/PLAN.md" --gh test/repo --gate true --bot-review '' --reviewer pinned-reviewer >/dev/null
cp "$T/models.saved" "$T/models.md"
bash "$CM" path >/dev/null
python3 - "$S/config.json" <<'PYCODE'
import json,sys
c=json.load(open(sys.argv[1])); assert c['modelsPinned'] and c['reviewer']=='pinned-reviewer'
PYCODE
bash "$CM" init "$T/repo/PLAN.md" --gh test/repo --gate true --bot-review '' >/dev/null
python3 - "$(dirname "$CM")/models.py" "$T/models.md" <<'PYCODE'
import json,subprocess,sys,tempfile
parser,source=sys.argv[1:]; text=open(source).read()
for original,replacement,role in [
    ('codex / fake-coder / high','broken','implementer'),
    ('opencode / fake/panel-a / high; opencode / fake/panel-b / medium (notes)','opencode / fake/panel-a / high','review panel'),
    ('opencode / fake/panel-b / medium (notes)','broken','review panel')]:
    with tempfile.NamedTemporaryFile(mode='w') as f:
        f.write(text.replace(original,replacement)); f.flush()
        p=subprocess.run(['python3',parser,f.name],capture_output=True,text=True)
        assert p.returncode and role in p.stderr
with tempfile.NamedTemporaryFile(mode='w') as f:
    f.write(text.replace('fake/panel-a / high;', 'fake/panel-a / high (first note);'))
    f.flush(); models=json.loads(subprocess.check_output(['python3',parser,f.name]))
    assert len(models['review panel'])==2
PYCODE
echo 'ok: model parsing, per-entry notes, refresh and explicit pinning'
# Fresh implementations clear review evidence, but preserve branch ownership.
echo owned > "$S/state/pr1.remote"
for file in state/pr1.approval state/pr1.verified runs/pr1.proof; do echo stale > "$S/$file"; done
bash "$CM" new 1 >/dev/null
for file in state/pr1.approval state/pr1.verified runs/pr1.proof; do [ ! -e "$S/$file" ]; done
for file in state/pr1.approval state/pr1.verified runs/pr1.proof; do echo stale > "$S/$file"; done
bash "$CM" implement 1 >/dev/null
for file in state/pr1.approval state/pr1.verified runs/pr1.proof; do [ ! -e "$S/$file" ]; done
[ "$(cat "$S/state/pr1.remote")" = owned ]
rm "$S/state/pr1.remote"
echo 'ok: new and implement clear evidence and preserve branch ownership'
# Direct runner defaults match jobs.py, and its worker publishes its PID first.
mkdir -p "$T/home/.local/state/council"
ln -s "$S" "$T/home/.local/state/council/current"
echo prompt > "$T/prompt"
env -u COUNCIL_STATE HOME="$T/home" FAKE_PID_FILE="$S/runs/default-job.pid" bash "$(dirname "$CM")/dashboard/run-job.sh" default-job 1 review codex fake low "$T/repo" "$S/runs/default.out" "$S/runs/default.log" -- "$T/prompt"
[ ! -e "$S/runs/default-job.pid" ]
FAKE_SLEEP=1 bash "$(dirname "$CM")/dashboard/run-job.sh" parent-term 1 review codex fake low "$T/repo" "$S/runs/term.out" "$S/runs/term.log" -- "$T/prompt" &
parent=$!
for ((i=0; i<200; i++)); do
  [ -f "$S/runs/parent-term.pid" ] && break
  sleep .02
done
worker=$(cat "$S/runs/parent-term.pid")
kill -TERM "$parent"
wait "$parent" || true
if kill -0 "$worker" 2>/dev/null; then echo 'FAIL: parent TERM left worker alive'; exit 1; fi
[ ! -e "$S/runs/parent-term.pid" ]
echo 'ok: runner defaults, synchronous worker PID, parent TERM and PID cleanup'
W=$T/repo-wt/repo-plan-1
# Derive worktree from the config rather than assuming the slug casing.
W=$(python3 - "$S/config.json" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); print(c['worktrees']+'/'+c['slug']+'-1')
PY
)
echo change >> "$W/file"
echo 'implemented file' > "$S/runs/pr1.report"
echo 'fix: test' > "$S/runs/pr1.title"
echo 'test body' > "$S/runs/pr1.body"
expect() {
  local expected=$1; shift
  local rc=0
  bash "$CM" "$@" > "$T/output" 2>&1 || rc=$?
  if [ "$rc" != "$expected" ]; then cat "$T/output"; echo "FAIL: $* returned $rc, expected $expected"; exit 1; fi
}
no_approval() { [ ! -e "$S/state/pr1.approval" ]; }
# Orchestrator approval covers all panel/gate findings after a single fix pass.
echo 'no findings yet' > "$T/ledger.md"
expect 12 approve 1 "$T/ledger.md"
export FAKE_OUTPUT=$'VERDICT: CHANGES\nS1 [SHOULD] file:1 panel bug\nS2 blocker: file:2 panel bug'
expect 0 review 1 1 panel
expect 12 approve 1 "$T/ledger.md"
export FAKE_OUTPUT=$'VERDICT: CHANGES\nS2 [should] file:1 gate bug'
expect 0 review 1 2 gate
read -r gate_hash gate_round gate_verdict < "$S/state/pr1.gate"
[ "$gate_round $gate_verdict" = '2 CHANGES' ]
expect 0 implement 1
[ "$(cat "$S/state/pr1.gate")" = "$gate_hash 2 CHANGES" ]
echo sol-fixed >> "$W/file"
cat > "$T/ledger.md" <<'LEDGER'
pr1-rev1-0-fake-panel-a:S1 fixed: checked panel bug regression
pr1-rev1-0-fake-panel-a:S2 declined: outside the requested behavior
pr1-rev1-1-fake-panel-b:S1 fixed: checked panel bug regression
pr1-rev1-1-fake-panel-b:S2 declined: outside the requested behavior
LEDGER
expect 12 approve 1 "$T/ledger.md"
grep -q 'pr1-rev2:S2' "$T/output"
# Empty evidence is not a resolution.
echo 'pr1-rev2:S2 fixed: ' >> "$T/ledger.md"
expect 12 approve 1 "$T/ledger.md"
echo 'pr1-rev2:S2 fixed: local regression passed after Sol edit' >> "$T/ledger.md"
expect 0 approve 1 "$T/ledger.md"
read -r approved reviewer round < "$S/state/pr1.approval"
[ "$reviewer $round" = 'orchestrator 2' ]
[ "$approved" != "$gate_hash" ]
[ "$(cat "$S/state/pr1.approval.ledger")" = "$(sha256sum "$T/ledger.md" | cut -d' ' -f1)" ]
# Verification is still required: reaching exit 10 proves approval passed.
expect 10 ship 1
echo edited >> "$T/ledger.md"
expect 8 ship 1
grep -q 'resolution ledger changed or missing' "$S/state/pr1"
expect 0 stop 1
expect 1 approve 1 "$T/ledger.md"
no_approval
expect 0 new 1
[ ! -e "$S/state/pr1.gate" ]
[ ! -e "$S/state/pr1.reviews.json" ]
[ ! -e "$S/state/pr1.approval.ledger" ]
expect 12 approve 1 "$T/ledger.md"
# A later panel invalidates a prior gate, even if the code did not move.
export FAKE_OUTPUT='VERDICT: APPROVE'
expect 0 review 1 1 gate
expect 0 review 1 2 panel
expect 12 approve 1 "$T/ledger.md"
expect 0 new 1
echo 'ok: orchestrator approval requires a gate and full ledger, survives implement, binds ledger hash and respects stop/new/panel order'
export FAKE_OUTPUT='VERDICT: CHANGES'
expect 0 review 1 1 gate
no_approval
[ "$(cat "$S/state/pr1")" = 'changes round 1' ]
echo 'ok a: CHANGES is not approval'
export FAKE_OUTPUT=$'VERDICT: APPROVE\nS1 [should] file:1 bug'
expect 0 review 1 2 gate
no_approval
echo 'ok b: should finding blocks approval'
for FAKE_OUTPUT in $'VERDICT: APPROVE\nS1 [Blocker] file:1 bug' $'VERDICT: APPROVE\nS1 blocker: file:1 bug'; do
  export FAKE_OUTPUT
  expect 0 review 1 2 gate
  no_approval
done
echo 'ok: mixed-case tagged and bare severities block approval'
export FAKE_OUTPUT='VERDICT: APPROVE' FAKE_DISSENT=1
expect 0 review 1 2 panel
no_approval
[ "$(cat "$S/state/pr1")" = 'changes round 2' ]
unset FAKE_DISSENT
echo 'ok: dissenting panel member blocks the round'
export FAKE_OUTPUT='VERDICT: APPROVE'
sed -i 's@fake/panel-b@fake/panel-a@' "$T/models.md"
expect 0 review 1 3 panel
cp "$T/models.saved" "$T/models.md"
no_approval
expect 8 ship 1
python3 - "$S/dashboard/jobs.json" <<'PY'
import json,sys
jobs=json.load(open(sys.argv[1]))['jobs']
panel=[j for j in jobs if j['provider']=='opencode' and j['id'].startswith('pr1-rev3-')]
assert len(panel)==2 and all(j['status']=='done' and j['pid']>1 for j in panel)
assert len({j['id'] for j in panel})==2 and {j['model'] for j in panel}=={'fake/panel-a'}
PY
echo 'ok c: parallel panel approval cannot ship'
expect 0 review 1 4 gate
[ -s "$S/state/pr1.approval" ]
echo later >> "$W/file"
expect 8 ship 1
[ "$(cat "$S/state/pr1")" = 'needs-attention: no approval for the current change' ]
echo 'ok d: later edit invalidates approval'
expect 0 review 1 5 gate
expect 10 ship 1
echo 'ok e: ship requires verification'
export FAKE_RC=2
expect 1 review 1 6 gate
no_approval
grep -q '^needs-attention:' "$S/state/pr1"
echo 'ok f: failed reviewer cannot approve'
unset FAKE_RC
base=$(cat "$S/runs/pr1.base")
git -C "$W" add file
git -C "$W" commit -qm changed
git -C "$W" push -q origin HEAD:refs/heads/moved
expect 9 gate merge 1 moved "$base" 1
echo 'ok g: merge rejects moved head'
rm -f "$S/state/pr1.approval"
# Move the remote from inside the build, after fetch but before merge.
# The fake gh merge succeeds, so only the ls-remote re-check can catch this.
new_head=$(echo remote-race | git -C "$W" commit-tree 'HEAD^{tree}' -p HEAD)
head=$(git -C "$W" rev-parse HEAD)
git -C "$W" push -q origin "$new_head:refs/heads/race-object"
python3 - "$S/config.json" "$T/origin.git" "$new_head" <<'PYCODE'
import json,shlex,sys
p,origin,head=sys.argv[1:]; c=json.load(open(p))
c['gate']='git --git-dir='+shlex.quote(origin)+' update-ref refs/heads/moved '+head
json.dump(c,open(p,'w'))
PYCODE
expect 8 gate merge 1 moved "$head" 1
no_approval
expect 0 review 1 16 gate
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
echo "$head" > "$S/state/pr1.head"
expect 9 gate merge 1 moved "$head" 1
python3 - "$S/config.json" <<'PYCODE'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['gate']='true'; json.dump(c,open(p,'w'))
PYCODE
echo 'ok: direct gate merge requires approval and rejects a moved remote head'
export FAKE_SLEEP=1
bash "$CM" review 1 7 gate > "$T/sleep.log" 2>&1 &
runner=$!
for ((i=0; i<200; i++)); do
  [ -f "$S/runs/pr1-rev7.pid" ] && python3 - "$S/dashboard/jobs.json" <<'PY' && break
import json,sys
sys.exit(not any(j['id']=='pr1-rev7' and j['status']=='running' for j in json.load(open(sys.argv[1]))['jobs']))
PY
  sleep .02
done
pid=$(cat "$S/runs/pr1-rev7.pid")
expect 0 stop 1
wait "$runner" || true
if kill -0 "$pid" 2>/dev/null; then echo 'FAIL: stopped pid remains'; exit 1; fi
no_approval
python3 - "$S/dashboard/jobs.json" <<'PY'
import json,sys
assert next(j for j in json.load(open(sys.argv[1]))['jobs'] if j['id']=='pr1-rev7')['status']=='stopped'
PY
[ ! -e "$S/state/pr1.verified" ]
[ ! -e "$S/runs/pr1-rev7.pid" ]
expect 1 ship 1
grep -q 'stopped; cannot ship' "$T/output"
echo 'ok h: stop kills running process group, clears evidence and blocks ship'
bash "$CM" review 1 11 gate > "$T/stop-job.log" 2>&1 &
runner=$!
for ((i=0; i<200; i++)); do
  [ -f "$S/runs/pr1-rev11.pid" ] && python3 - "$S/dashboard/jobs.json" <<'PYCODE' && break
import json,sys
sys.exit(not any(j['id']=='pr1-rev11' and j['status']=='running' for j in json.load(open(sys.argv[1]))['jobs']))
PYCODE
  sleep .02
done
pid=$(cat "$S/runs/pr1-rev11.pid")
expect 0 stop-job pr1-rev11
wait "$runner" || true
if kill -0 "$pid" 2>/dev/null; then echo 'FAIL: stop-job pid remains'; exit 1; fi
no_approval
echo 'ok extra: stop-job kills its process group'
unset FAKE_SLEEP
# A recycled PID belonging to another process must never be signalled.
setsid sleep 300 &
innocent=$!
python3 - "$S/dashboard/jobs.json" "$S/runs/stale.pid" "$innocent" <<'PYCODE'
import json,sys
p,pidfile,pid=sys.argv[1:]; c=json.load(open(p))
c['jobs'].append({'id':'stale','plan':1,'status':'running','pid':int(pid)})
json.dump(c,open(p,'w')); open(pidfile,'w').write(pid)
PYCODE
expect 0 stop-job stale
kill -0 "$innocent"
kill "$innocent"; wait "$innocent" || true
echo 'ok: stale worker PID does not kill an unrelated process'
# Additional boundary checks: missing/empty verdict, untracked hash, proof and stop-job.
for FAKE_OUTPUT in '' 'no verdict'; do
  export FAKE_OUTPUT
  expect 0 review 1 8 gate
  no_approval
done
export FAKE_OUTPUT='VERDICT: APPROVE'
expect 0 review 1 9 gate
echo untracked > "$W/new-file"
expect 8 ship 1
expect 10 verify 1
echo 'bash tests: 12 passed (real local test run)' > "$S/runs/pr1.proof"
expect 0 verify 1
[ -s "$S/state/pr1.verified" ]
echo edit-after-proof >> "$W/new-file"
expect 10 verify 1
grep -q 'proof is older' "$T/output"
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
expect 0 review 1 13 gate
echo swapped-proof > "$S/runs/pr1.proof"
expect 10 ship 1
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
echo 'ok: old proof after edit and swapped proof after verify are refused'
# Observe must ignore every auxiliary state file when collect() reads the board.
printf '' > "$T/transcript.jsonl"
python3 - "$S/config.json" "$T/transcript.jsonl" "$(dirname "$CM")/dashboard/observe.py" <<'PYCODE'
import importlib.util,json,sys
p,transcript,source=sys.argv[1:]; c=json.load(open(p)); c['transcript']=transcript
json.dump(c,open(p,'w'))
spec=importlib.util.spec_from_file_location('observe',source)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.collect()['total']==1
assert set(m.pipeline_state())=={1}
PYCODE
echo 'ok: board collect ignores approval, verified and lock files'
expect 0 review 1 10 gate
# The plan is excluded, while untracked mode and type changes invalidate approval.
echo plan-edit >> "$W/PLAN.md"
FAKE_STAGE_EDIT=1 expect 8 ship 1
grep -q 'staged change differs' "$T/output"
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
expect 0 review 1 14 gate
chmod +x "$W/new-file"
expect 8 ship 1
chmod -x "$W/new-file"
cp "$W/new-file" "$T/saved-file"
rm "$W/new-file"; ln -s "$T/saved-file" "$W/new-file"
expect 8 ship 1
rm "$W/new-file"; cp "$T/saved-file" "$W/new-file"
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
expect 0 review 1 15 gate
echo 'ok: staged race, file mode, symlink type and plan exclusion'
# A hook's staged edit must not enter an approved commit unnoticed.
before=$(git -C "$W" rev-parse HEAD)
hooks=$T/hooks; mkdir "$hooks"
cat > "$hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
echo hook-edit >> file
git add file
HOOK
chmod +x "$hooks/pre-commit"
git -C "$W" config core.hooksPath "$hooks"
expect 8 ship 1
[ "$(git -C "$W" rev-parse HEAD)" = "$before" ]
grep -q hook-edit "$W/file"
git -C "$W" diff --cached -- file | grep -q hook-edit
grep -q 'committed change differs' "$S/state/pr1"
rm "$hooks/pre-commit"
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
expect 0 review 1 17 gate
echo 'ok: commit hook edit refuses ship and soft reset preserves staged changes'
# A branch appearing after an absent ls-remote must be protected by an empty lease.
export TEST_ORIGIN=$T/origin.git TEST_BRANCH=refs/heads/council/repo-plan-1 TEST_BASE=$(cat "$S/runs/pr1.base")
FAKE_FIRST_PUSH=1 expect 1 ship 1
[ "$(git --git-dir="$T/origin.git" rev-parse "$TEST_BRANCH")" = "$TEST_BASE" ]
git --git-dir="$T/origin.git" update-ref -d "$TEST_BRANCH"
echo 'ok: first push uses an expect-absent lease'
# Preserve the branch after its first push to test lease protection on a retry.
python3 - "$S/config.json" <<'PYCODE'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['gate']='false'; json.dump(c,open(p,'w'))
PYCODE
FAKE_MOVE_HEAD=1 expect 1 ship 1
[ "$(cat "$S/state/pr1.head")" != "$(git -C "$W" rev-parse HEAD)" ]
[ "$(cat "$S/state/pr1.head")" = "$(git --git-dir="$T/origin.git" rev-parse "$TEST_BRANCH")" ]
echo 'ok: push uses the approved commit SHA even when local HEAD moves'
grep -q 'gate check failed' "$S/state/pr1"
echo 'ok: failing gate command prevents ship'
old=$(cat "$S/state/pr1.head")
branch=council/repo-plan-1
moved=$(echo concurrent | git -C "$W" commit-tree 'HEAD^{tree}' -p HEAD)
git -C "$W" push -q origin "$moved:refs/heads/$branch"
expect 0 implement 1
[ "$(cat "$S/state/pr1.remote")" = "$old" ]
expect 0 review 1 12 gate
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
expect 1 ship 1
[ "$(cat "$S/state/pr1")" = 'needs-attention: push lease refused' ]
[ "$(git --git-dir="$T/origin.git" rev-parse "refs/heads/$branch")" = "$moved" ]
# Missing ownership must refuse an already-existing branch until explicit adoption.
rm "$S/state/pr1.remote"
expect 11 ship 1
grep -q 'branch exists on origin and we never pushed it' "$T/output"
[ ! -e "$S/state/pr1.remote" ]
expect 0 adopt 1
[ "$(cat "$S/state/pr1.remote")" = "$moved" ]
python3 - "$S/config.json" <<'PYCODE'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['gate']='true'; json.dump(c,open(p,'w'))
PYCODE
echo 'ok: retry preserves remote ownership, unowned branch refuses ship, adopt allows push'
# Stop while the slow merge command is pending: no merge may finish.
export FAKE_MERGE_CALLS=$T/merge-calls
bash "$CM" ship 1 > "$T/ship-stop.log" 2>&1 &
shipper=$!
for ((i=0; i<1000; i++)); do
  [ -s "$FAKE_MERGE_CALLS" ] && break
  kill -0 "$shipper" 2>/dev/null || { cat "$T/ship-stop.log"; exit 1; }
  sleep .02
done
[ -s "$FAKE_MERGE_CALLS" ]
expect 0 stop 1
rc=0; wait "$shipper" || rc=$?
[ "$rc" = 1 ]
[ "$(cat "$S/state/pr1")" = 'stopped: stopped by the orchestrator' ]
[ "$(cat "$FAKE_MERGE_CALLS")" = started ]
[ "$(cat "$S/state/pr1.remote")" = "$(git --git-dir="$T/origin.git" rev-parse "refs/heads/$branch")" ]
expect 1 gate merge 1 "$branch" "$(cat "$S/state/pr1.head")"
echo 'ok: stop during slow merge cancels merge and preserves stopped state and ownership'
unset FAKE_MERGE_CALLS
expect 0 review 1 18 gate
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
# Direct merge requires verification and the exact shipped head as well as approval.
head=$(cat "$S/state/pr1.head")
mv "$S/state/pr1.verified" "$T/verified"
expect 10 gate merge 1 "$branch" "$head"
mv "$T/verified" "$S/state/pr1.verified"
echo wrong > "$S/state/pr1.head"
expect 9 gate merge 1 "$branch" "$head"
echo "$head" > "$S/state/pr1.head"
echo 'ok: direct gate merge requires verification and matching shipped head'
# Complete shipping also accepts the orchestrator path after a gate asks for fixes.
export FAKE_OUTPUT=$'VERDICT: CHANGES\nS1 [should] file:1 final bug'
expect 0 review 1 19 gate
echo final-fix >> "$W/file"
echo 'pr1-rev19:S1 fixed: final regression verified locally' > "$T/final-ledger.md"
expect 0 approve 1 "$T/final-ledger.md"
echo fresh-proof > "$S/runs/pr1.proof"
expect 0 verify 1
expect 0 ship 1
[ "$(cat "$S/state/pr1")" = 'merged #1' ]
[ "$(cat "$S/state/pr1.head")" = "$(git --git-dir="$T/origin.git" rev-parse 'refs/heads/council/repo-plan-1')" ]
echo 'ok extra: verdict, untracked hash, proof binding and complete local ship'
python3 - "$(dirname "$CM")" <<'PYCODE'
from pathlib import Path
import sys
plan=Path(sys.argv[1])
policy=('Default: two panel rounds (DeepSeek and Muse in parallel, no fixes between) + one gate round (Astra), then Sol fixes once.',
        '"light review": one panel round + gate, then Sol once; "sol loop": Sol only, up to 3 rounds.')
for path in (plan/'cm.sh', plan.parent/'SKILL.md',
             plan.parent.parent/'review-loop/SKILL.md', plan.parent.parent/'sid-mode/SKILL.md'):
    text=path.read_text()
    assert all(line in text for line in policy), path
    assert 'Stop early only if a round returns nothing but nits.' not in text, path
PYCODE
echo 'ok: review instructions agree on default, light review and sol loop rounds'
echo 'All plan-runner tests passed.'
