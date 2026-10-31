#!/usr/bin/env bash
# Offline integration tests: actual git worktrees, bare origin and process groups.
set -eu
CM=$(cd "$(dirname "$0")/.." && pwd)/cm.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export COUNCIL_HOME=$T/state SIDSTACK_MODELS=$T/models.md
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
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
printf '%s\n' "${FAKE_OUTPUT-VERDICT: APPROVE}"
exit "${FAKE_RC:-0}"
FAKE
cat > "$T/bin/gh" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = 'pr list' ]; then echo 1
elif [ "${1:-} ${2:-}" = 'pr view' ]; then echo 'test change'
elif [ "${1:-} ${2:-}" = 'pr merge' ]; then exit 0
else echo 'https://example.test/pull/1'; fi
FAKE
chmod +x "$T/bin/"*
git init -q --bare --initial-branch=main "$T/origin.git"
git init -q --initial-branch=main "$T/repo"
git -C "$T/repo" config user.email test@example.test
git -C "$T/repo" config user.name Test
printf '## Phase 1\n### [ ] PR 1 — test (S)\nChange file.\n' > "$T/repo/PLAN.md"
echo base > "$T/repo/file"
git -C "$T/repo" add .
git -C "$T/repo" commit -qm base
git -C "$T/repo" remote add origin "$T/origin.git"
git -C "$T/repo" push -q -u origin main
bash "$CM" init "$T/repo/PLAN.md" --gh test/repo --gate true --bot-review '' >/dev/null
S=$(bash "$CM" path)
export COUNCIL_STATE=$S
bash "$CM" new 1 >/dev/null
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
export FAKE_OUTPUT='VERDICT: CHANGES'
expect 0 review 1 1 gate
no_approval
[ "$(cat "$S/state/pr1")" = 'changes round 1' ]
echo 'ok a: CHANGES is not approval'
export FAKE_OUTPUT=$'VERDICT: APPROVE\nS1 [should] file:1 bug'
expect 0 review 1 2 gate
no_approval
echo 'ok b: should finding blocks approval'
export FAKE_OUTPUT='VERDICT: APPROVE'
expect 0 review 1 3 panel
no_approval
expect 8 ship 1
python3 - "$S/dashboard/jobs.json" <<'PY'
import json,sys
jobs=json.load(open(sys.argv[1]))['jobs']
panel=[j for j in jobs if j['provider']=='opencode']
assert len(panel)==2 and all(j['status']=='done' and j['pid']>1 for j in panel)
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
expect 9 gate merge 1 moved "$base"
echo 'ok g: merge rejects moved head'
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
echo 'ok h: stop kills running process group and clears approval'
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
expect 0 review 1 10 gate
# Preserve the branch after its first push to test lease protection on a retry.
python3 - "$S/config.json" <<'PYCODE'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['gate']='false'; json.dump(c,open(p,'w'))
PYCODE
expect 1 ship 1
old=$(cat "$S/runs/pr1.head")
branch=council/repo-plan-1
moved=$(echo concurrent | git -C "$W" commit-tree 'HEAD^{tree}' -p HEAD)
git -C "$W" push -q origin "$moved:refs/heads/$branch"
expect 0 review 1 12 gate
expect 0 verify 1
expect 1 ship 1
[ "$(cat "$S/state/pr1")" = 'needs-attention: push lease refused' ]
[ "$(git --git-dir="$T/origin.git" rev-parse "refs/heads/$branch")" = "$moved" ]
git --git-dir="$T/origin.git" update-ref "refs/heads/$branch" "$old"
python3 - "$S/config.json" <<'PYCODE'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); c['gate']='true'; json.dump(c,open(p,'w'))
PYCODE
echo 'ok extra: push lease preserves a concurrent remote update'
expect 0 ship 1
[ "$(cat "$S/state/pr1")" = 'merged #1' ]
[ "$(cat "$S/runs/pr1.head")" = "$(git --git-dir="$T/origin.git" rev-parse 'refs/heads/council/repo-plan-1')" ]
echo 'ok extra: verdict, untracked hash, proof binding and complete local ship'
echo 'All plan-runner tests passed.'
