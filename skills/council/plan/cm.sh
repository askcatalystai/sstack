#!/usr/bin/env bash
# cm.sh: drive a council plan file to merged PRs, one PR item at a time.
#
#   cm.sh init <plan.md> [--repo DIR] [--gh owner/repo] [--title T] [--gate-dir DIR] [--gate "CMDS"]
#                        [--reviewer MODEL] [--implementer MODEL|claude] [--effort LEVEL] [--implementer-effort LEVEL] [--reviewer-effort LEVEL] [--trailer "Co-Authored-By: ..."] [--port N]
#                        [--bot-review LOGIN] [--bot-timeout SECONDS]
#   cm.sh init --adhoc --repo DIR [--gh owner/repo] [--title T] [--gate "CMDS"] [--port N]
#                                      one-off PRs without a plan file (slug <repo>-adhoc); full send / full stop use it
#   cm.sh use <slug>                   make another initialised plan current
#   cm.sh new <n> [task.md]            worktree + branch for PR <n>, from origin/<default>; adhoc plans need task.md
#   cm.sh implement <n> [extra.md...]    Codex implementer (config implementer) writes the change in the worktree
#   cm.sh stop <n> [reason]            mark a PR stopped (not active) and close its running jobs
#   cm.sh adopt <n>                   explicitly take over the current origin branch SHA
#   cm.sh verify <n>                  bind runs/pr<n>.proof to the current change
#   cm.sh stop-job <id>               stop one job process group
#   cm.sh review <n> <round> [all|panel|gate]  read-only review of the uncommitted change (needs runs/pr<n>.report);
#                                      all (default): gate reviewer and every panel member in parallel, one round
#   cm.sh approve <n> <ledger.md>      bind orchestrator resolutions to the fixed change
#   cm.sh ship [--no-merge] <n>        commit, push, gate, open the PR, bot review, gate again, merge, remove the worktree
#                                      (--no-merge stops after a clean bot review with state "ready")
#                                      (needs runs/pr<n>.title and runs/pr<n>.body)
#   cm.sh bot-review <pr> [head-sha]   wait for the GitHub review bot (config botReview) to finish on the head commit;
#                                      exit 0 clean, 6 unresolved findings (printed), 7 failed or timed out
#   cm.sh gate check <ref> | gate merge <pr> <ref> <expected-head> [n]
#   cm.sh status                       one line per PR from the state dir
#   cm.sh dashboard [--transcript F] [--port N] | dashboard stop
#   cm.sh path                         print the state dir (runs/, state/, dashboard/)
#
# With more than one plan, name yours on every call: COUNCIL_PLAN=<slug> cm.sh <command> (slug: printed by init).
# State lives in ~/.local/state/council/<slug>/ (current plan: ~/.local/state/council/current).
# Default: one parallel round (Astra, DeepSeek and Muse at once); the orchestrator takes the final call, Sol fixes once, the orchestrator approves.
# "deep review" (the orchestrator decides, risky areas): a second parallel round on the fixed change. "sol loop": Sol only, up to 3 rounds.
# Exit codes: 8 missing/stale approval, 9 remote head moved, 10 missing/stale verification, 11 unowned branch, 12 incomplete resolution ledger or missing gate round.
# Gate: 0 pass/merged, 1 build failed, 3 conflicts with main, 4 main moved, 5 merge refused, 9 head moved.
set -u
SKILL=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ROOT=${COUNCIL_HOME:-$HOME/.local/state/council}
die() { echo "cm: $*" >&2; exit 1; }

cmd=${1:-}; shift || true

if [ "$cmd" = init ]; then
  adhoc=false
  if [ "${1:-}" = --adhoc ]; then adhoc=true; plan=""; repo=""; shift
  else
    plan=${1:?plan file}; shift
    repo=$(git -C "$(dirname "$(readlink -f "$plan")")" rev-parse --show-toplevel) || die "plan is not in a git repo"
  fi
  models=$(python3 "$SKILL/models.py" "${SIDSTACK_MODELS:-$HOME/.local/share/sidstack/models.md}") || die "cannot read models.md"
  model_field() { python3 -c 'import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]][0][sys.argv[3]])' "$models" "$1" "$2"; }
  # Defaults follow ~/.local/share/sidstack/models.md: Sol implements, Astra reviews, the Codex GitHub bot gates merges.
  gh="" title="" gate_dir="." gate="" reviewer=$(model_field reviewer model) implementer=$(model_field implementer model) effort="" impl_effort="" rev_effort="" trailer="" port=8787 bot="chatgpt-codex-connector" bot_timeout=900 pinned=false
  while [ $# -gt 0 ]; do case $1 in
    --repo) repo=$2; shift 2;; --gh) gh=$2; shift 2;; --title) title=$2; shift 2;;
    --gate-dir) gate_dir=$2; shift 2;; --gate) gate=$2; shift 2;; --reviewer) pinned=true; reviewer=$2; shift 2;; --implementer) pinned=true; implementer=$2; shift 2;;
    --effort) pinned=true; effort=$2; shift 2;; --implementer-effort) pinned=true; impl_effort=$2; shift 2;; --reviewer-effort) pinned=true; rev_effort=$2; shift 2;; --trailer) trailer=$2; shift 2;; --port) port=$2; shift 2;;
    --bot-review) bot=$2; shift 2;; --bot-timeout) bot_timeout=$2; shift 2;;
    *) die "unknown option $1";; esac; done
  impl_effort=${impl_effort:-${effort:-$(model_field implementer effort)}}
  rev_effort=${rev_effort:-${effort:-$(model_field reviewer effort)}}
  [ -n "$gh" ] || gh=$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner) || die "pass --gh owner/repo"
  [ -n "$gate" ] || die "pass --gate with the commands the deploy runs (install, typecheck, builds)"
  if [ "$adhoc" = true ]; then
    [ -n "$repo" ] || die "--adhoc needs --repo DIR"
    repo=$(git -C "$repo" rev-parse --show-toplevel) || die "--repo is not a git repo"
    # A repo path that never exists keeps the plan exclusions harmless; the board reads planFile.
    relplan=.sidstack-adhoc-plan.md; slug=$(basename "$repo")-adhoc
  else
    relplan=$(realpath --relative-to="$repo" "$plan")
    slug=$(basename "$repo")-$(basename "$relplan" .md | tr 'A-Z_ ' 'a-z--')
  fi
  S=$ROOT/$slug; mkdir -p "$S/runs" "$S/state" "$S/dashboard"
  plan_file=""
  if [ "$adhoc" = true ]; then
    plan_file=$S/adhoc-plan.md
    [ -s "$plan_file" ] || printf '# %s one-off PRs\n\n## Phase 1 — One-off\n\n' "${title:-$(basename "$repo")}" > "$plan_file"
  fi
  base=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'); base=${base:-main}
  python3 - "$S/config.json" "$repo" "$gh" "$relplan" "$title" "$base" "$slug" "$gate_dir" "$gate" "$reviewer" "$implementer" "$effort" "$trailer" "$port" "$impl_effort" "$rev_effort" "$bot" "$bot_timeout" "$models" "$pinned" "$plan_file" <<'EOF'
import json,os,sys
out,repo,gh,plan,title,base,slug,gate_dir,gate,reviewer,implementer,effort,trailer,port,impl_effort,rev_effort,bot,bot_timeout,models,pinned,plan_file=sys.argv[1:]
models=json.loads(models)
old=json.load(open(out)) if os.path.exists(out) else {}
json.dump({"repo":repo,"gh":gh,"plan":plan,"title":title or None,"base":base,"slug":slug,
  "worktrees":os.path.join(os.path.dirname(repo),os.path.basename(repo)+"-wt"),"gateDir":gate_dir,"gate":gate,
  "modelsPinned":pinned == "true","reviewerProvider":models["reviewer"][0]["provider"],"implementerProvider":models["implementer"][0]["provider"],"reviewPanel":models["review panel"],"hardestTasks":models["hardest tasks"][0],
  "reviewer":reviewer,"implementer":implementer,"effort":effort,**({"implementerEffort":impl_effort} if impl_effort else {}),**({"reviewerEffort":rev_effort} if rev_effort else {}),"trailer":trailer,"port":int(port),"botReview":bot or None,"botTimeout":int(bot_timeout),"transcript":old.get("transcript"),**({"planFile":plan_file,"adhoc":True} if plan_file else {})},open(out,"w"),indent=1)
EOF
  ln -sfn "$S" "$ROOT/current"
  echo "initialised $slug -> $S"; exit 0
fi

if [ "$cmd" = use ]; then [ -d "$ROOT/${1:?slug}" ] || die "no plan $1"; ln -sfn "$ROOT/$1" "$ROOT/current"; echo "current: $1"; exit 0; fi

# Name the plan on every call when more than one session runs plans: COUNCIL_PLAN=<slug> (or COUNCIL_STATE=<dir>).
# "current" is only the last plan any session initialised.
if [ -n "${COUNCIL_PLAN:-}" ]; then COUNCIL_STATE=$ROOT/$COUNCIL_PLAN; [ -d "$COUNCIL_STATE" ] || die "no plan $COUNCIL_PLAN"; fi
if [ -z "${COUNCIL_STATE:-}" ] && [ "$(find "$ROOT" -mindepth 2 -maxdepth 2 -name config.json 2>/dev/null | wc -l)" -gt 1 ]; then
  echo "cm: several plans exist; using current ($(basename "$(readlink -f "$ROOT/current")")). Set COUNCIL_PLAN=<slug> to be sure." >&2
fi
S=$(readlink -f "${COUNCIL_STATE:-$ROOT/current}") || die "no current plan; run cm.sh init"
[ -f "$S/config.json" ] || die "no current plan; run cm.sh init"
export COUNCIL_STATE=$S
python3 - "$S/config.json" "$SKILL/models.py" "${SIDSTACK_MODELS:-$HOME/.local/share/sidstack/models.md}" <<'EOF' || die "cannot load model settings"
import json, os, subprocess, sys, tempfile
path, parser, source = sys.argv[1:]
c = json.load(open(path))
if not c.get('modelsPinned', False):
    models = json.loads(subprocess.check_output(['python3', parser, source]))
    for role in ('reviewer', 'implementer'):
        m = models[role][0]
        c.update({role: m['model'], role+'Provider': m['provider'], role+'Effort': m['effort']})
    c.update(reviewPanel=models['review panel'], hardestTasks=models['hardest tasks'][0])
    with tempfile.NamedTemporaryFile(mode='w', dir=os.path.dirname(path), delete=False) as f:
        json.dump(c, f, indent=1)
    os.replace(f.name, path)
EOF
conf() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get(sys.argv[2]);print("" if v is None else v)' "$S/config.json" "$1"; }
# Per-role effort; falls back to the shared effort.
effort_for() { e=$(conf "${1}Effort"); echo "${e:-$(conf effort)}"; }
R=$(conf repo) GH=$(conf gh) PLAN=$(conf plan) BASE=$(conf base) SLUG=$(conf slug) WTS=$(conf worktrees)
V=$WTS/verify
wt() { echo "$WTS/$SLUG-$1"; }
br() { echo "council/$SLUG-$1"; }
setst() { echo "$2" > "$S/state/pr$1"; }
job() { python3 "$SKILL/dashboard/jobs.py" upsert "$@"; }

# Hash the snapshot ship stages, including Git modes and addition metadata.
change_hash() {
  python3 "$SKILL/change.py" "$(wt "$1")" "$(cat "$S/runs/pr$1.base")" "$PLAN" "${2:-worktree}" "${3:-HEAD}"
}
clear_evidence() {
  rm -f "$S/state/pr$1.approval" "$S/state/pr$1.approval.ledger" "$S/state/pr$1.approval.ledger.path" "$S/state/pr$1.verified" "$S/runs/pr$1.proof"
}
# Shipping never holds the stop lock while waiting for an external command.
active() {
  [[ $(cat "$S/state/pr$1" 2>/dev/null) != stopped* ]] || { echo "cm: PR $1 is stopped; cannot ship" >&2; exit 1; }
}
shipst() {
  exec 7>"$S/state/pr$1.lock"; flock 7
  active "$1"
  setst "$1" "$2"
  flock -u 7
}
# Cancel a pending merge (and its children) if stop arrives while gh is running.
merge_active() {
  active "$n"
  setsid "$@" &
  local pid=$! rc=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $(cat "$S/state/pr$n" 2>/dev/null) = stopped* ]]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      wait "$pid" || true
      active "$n"
    fi
    sleep .1
  done
  wait "$pid" || rc=$?
  active "$n"
  return "$rc"
}
shipping_evidence() {
  local hash=$1 approved="" reviewer="" round="" verified="" proof=""
  active "$n"
  read -r approved reviewer round 2>/dev/null < "$S/state/pr$n.approval" || true
  if [ "$approved" != "$hash" ] || { [ "$reviewer" != "$(conf reviewer)" ] && [ "$reviewer" != orchestrator ]; }; then
    shipst "$n" "needs-attention: no approval for the current change"; exit 8
  fi
  if [ "$reviewer" = orchestrator ]; then
    local ledger_path ledger_hash
    ledger_path=$(cat "$S/state/pr$n.approval.ledger.path" 2>/dev/null)
    ledger_hash=$(cat "$S/state/pr$n.approval.ledger" 2>/dev/null)
    if [ -z "$ledger_hash" ] || [ "$ledger_hash" != "$(sha256sum -- "$ledger_path" 2>/dev/null | cut -d' ' -f1)" ]; then
      shipst "$n" "needs-attention: resolution ledger changed or missing"; exit 8
    fi
  fi
  read -r verified proof 2>/dev/null < "$S/state/pr$n.verified" || true
  if [ "$verified" != "$hash" ] || [ -z "$proof" ] || [ "$proof" != "$(sha256sum "$S/runs/pr$n.proof" 2>/dev/null | cut -d' ' -f1)" ]; then
    shipst "$n" "needs-attention: no verification for the current change"; exit 10
  fi
}
stop_jobs() {
  python3 - "$S" "$1" "$2" <<'EOF'
import fcntl, json, os, signal, sys, time
from pathlib import Path
s, kind, target = sys.argv[1:]
p = Path(s)/'dashboard/jobs.json'
p.parent.mkdir(parents=True, exist_ok=True)
with open(p, 'a+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.seek(0)
    data = json.loads(f.read() or '{"jobs":[]}')
    groups = []
    for j in data['jobs']:
        if (str(j.get('plan')) if kind == 'plan' else j['id']) != target:
            continue
        for suffix in ('approval', 'verified'):
            (Path(s)/f"state/pr{j['plan']}.{suffix}").unlink(missing_ok=True)
        if j.get('status') != 'running':
            continue
        pidfile = Path(s)/f"runs/{j['id']}.pid"
        pid = int(pidfile.read_text()) if pidfile.exists() else j.get('pid')
        try: command = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        except OSError: command = []
        worker = [b'--worker', j['id'].encode()]
        if pid and pid > 1 and any(command[i:i+2] == worker for i in range(len(command)-1)):
            groups.append((pid, worker))
            try: os.killpg(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        j['status'] = 'stopped'
        j['finishedAt'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    f.seek(0); f.truncate(); json.dump(data, f, indent=1)
# Release the board lock while waiting for runners to reap their children.
if groups:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        alive = []
        for pid, worker in groups:
            try: os.killpg(pid, 0); alive.append((pid, worker))
            except ProcessLookupError: pass
        groups = alive
        if not groups: break
        time.sleep(.1)
    for pid, worker in groups:
        try:
            command = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
            if any(command[i:i+2] == worker for i in range(len(command)-1)):
                os.killpg(pid, signal.SIGKILL)
        except OSError: pass
EOF
}

case $cmd in
path) echo "$S";;

new)
  n=${1:?plan PR number}; task=${2:-}; W=$(wt "$n")
  if [ -n "$task" ]; then
    [ -s "$task" ] || die "task file $task is empty or missing"
    cp -- "$task" "$S/runs/pr$n.task"
    pf=$(conf planFile)
    if [ -n "$pf" ] && ! grep -q "^### \[.\] PR $n " "$pf"; then
      { printf '### [ ] PR %s — %s\n' "$n" "$(head -1 "$task" | sed 's/^#* *//')"; tail -n +2 "$task"; echo; } >> "$pf"
    fi
  elif [ "$(conf adhoc)" = True ]; then die "adhoc PRs need a task file: cm new $n task.md"
  fi
  clear_evidence "$n"
  rm -f "$S/state/pr$n.gate" "$S/state/pr$n.reviews.json"
  git -C "$R" fetch -q origin "$BASE"
  [ -d "$W" ] || git -C "$R" worktree add -q -B "$(br "$n")" "$W" "origin/$BASE" || die "worktree add failed"
  # Reuse the main checkout's installed dependencies.
  (cd "$R" && find . -maxdepth 4 -name node_modules -type d -not -path "*/node_modules/*") | while read -r d; do [ -e "$W/$d" ] || ln -s "$R/$d" "$W/$d"; done
  grep -qx node_modules "$R/.git/info/exclude" 2>/dev/null || echo node_modules >> "$R/.git/info/exclude"
  git -C "$W" rev-parse HEAD > "$S/runs/pr$n.base"
  [ -s "$S/runs/pr$n.task" ] || awk -v n="$n" '$0 ~ "^#+ \\[.\\] PR "n" " {p=1; print; next} p && /^#+ / {exit} p' "$R/$PLAN" > "$S/runs/pr$n.task"
  [ -s "$S/runs/pr$n.task" ] || echo "cm: PR $n is not in $PLAN; write its task to $S/runs/pr$n.task" >&2
  setst "$n" "coding"; impl=$(conf implementer); impl=${impl:-claude}
  [ "$impl" = claude ] && job "pr$n-implement" "$n" implement anthropic claude "$(effort_for implementer)" running "$S/runs/pr$n.report"
  echo "$W ($(cut -c1-8 "$S/runs/pr$n.base"))"; cat "$S/runs/pr$n.task";;

implement)
  n=${1:?plan PR number}; W=$(wt "$n"); P=$S/runs/pr$n-impl.prompt; shift
  [ -d "$W" ] || die "run cm.sh new $n first"
  model=$(conf implementer); provider=$(conf implementerProvider); impl_effort=$(effort_for implementer)
  if [ "${1:-}" = --hardest ]; then
    read -r provider model impl_effort < <(python3 - "$S/config.json" <<'EOF'
import json,sys
m=json.load(open(sys.argv[1]))['hardestTasks']
print(m['provider'], m['model'], m['effort'])
EOF
)
    shift
  fi
  [ -n "$model" ] && [ "$model" != claude ] || die "implementer is claude; set --implementer <codex model> in init"
  clear_evidence "$n"
  setst "$n" "coding"
  { echo "Implement plan PR $n from $PLAN in this git worktree ($W). Work only here; do not commit, push or switch branches."
    echo "Make the smallest change that meets the acceptance check. Add a regression test that fails without the fix. Run the affected tests and the typecheck."
    echo "When done, write what was wrong, what changed (files), the proof (tests, counts) and what was not checked live to $S/runs/pr$n.report."
    for extra in "$@"; do echo; cat "$extra"; done
    echo; echo "=== Plan item ==="; cat "$S/runs/pr$n.task"
  } > "$P"
  "$SKILL/dashboard/run-job.sh" "pr$n-impl" "$n" implement "$provider" "$model" "$impl_effort" "$W" "$S/runs/pr$n-impl.out" "$S/runs/pr$n-impl.log" -- "$P"; rc=$?
  [[ $(cat "$S/state/pr$n") = stopped:* ]] && exit 1
  [ $rc = 0 ] && setst "$n" "implemented" || setst "$n" "needs-attention: implement failed ($S/runs/pr$n-impl.log)"
  tail -n 30 "$S/runs/pr$n-impl.out" 2>/dev/null; exit $rc;;

stop)
  n=${1:?plan PR number}
  exec 7>"$S/state/pr$n.lock"; flock 7
  exec 8<>"$S/dashboard/jobs.json"; flock 8
  setst "$n" "stopped: ${2:-stopped by the orchestrator}"
  rm -f "$S/state/pr$n.approval" "$S/state/pr$n.verified"
  flock -u 8
  stop_jobs plan "$n"
  echo "PR $n stopped";;

adopt)
  n=${1:?plan PR number}; b=$(br "$n")
  seen=$(git -C "$R" ls-remote --exit-code origin "refs/heads/$b") || die "cannot read remote branch $b"
  echo "${seen%%$'\t'*}" > "$S/state/pr$n.remote"
  echo "adopted $b at ${seen%%$'\t'*}";;

stop-job)
  stop_jobs id "${1:?job id}";;

verify)
  n=${1:?plan PR number}
  [ -s "$S/runs/pr$n.proof" ] || {
    echo "Write runs/pr$n.proof: run the real thing (covering tests with pass counts; for UI, the app in a browser with a screenshot path); green mocked tests alone are not proof." >&2
    exit 10
  }
  newest=$(python3 "$SKILL/change.py" "$(wt "$n")" "$(cat "$S/runs/pr$n.base")" "$PLAN" newest) || exit 1
  if [ "$newest" -gt "$(python3 -c 'import os,sys;print(os.stat(sys.argv[1]).st_mtime_ns)' "$S/runs/pr$n.proof")" ]; then
    echo "cm: proof is older than the newest changed file; rerun verification and rewrite runs/pr$n.proof" >&2; exit 10
  fi
  hash=$(change_hash "$n") || exit 1
  printf '%s %s\n' "$hash" "$(sha256sum "$S/runs/pr$n.proof" | cut -d' ' -f1)" > "$S/state/pr$n.verified"
  echo "PR $n verification bound to current change";;

approve)
  n=${1:?plan PR number}; ledger=$(realpath -e -- "${2:?resolution ledger}") || exit 12
  exec 7>"$S/state/pr$n.lock"; flock 7
  active "$n"
  gate_hash=""; gate_round=""; verdict=""
  read -r gate_hash gate_round verdict < "$S/state/pr$n.gate" 2>/dev/null || true
  if [ -z "$gate_hash" ] || [ -z "$gate_round" ] || { [ "$verdict" != APPROVE ] && [ "$verdict" != CHANGES ]; }; then
    echo "cm: a gate round must run after the latest panel round" >&2; exit 12
  fi
  ledger_hash=$(sha256sum -- "$ledger" | cut -d' ' -f1) || exit 12
  python3 "$SKILL/reviews.py" validate "$S/state/pr$n.reviews.json" "$gate_round" "$ledger" || exit 12
  [ "$ledger_hash" = "$(sha256sum -- "$ledger" | cut -d' ' -f1)" ] || { echo "cm: ledger changed during approval" >&2; exit 12; }
  hash=$(change_hash "$n") || exit 1
  printf '%s\n' "$ledger_hash" > "$S/state/pr$n.approval.ledger"
  printf '%s\n' "$ledger" > "$S/state/pr$n.approval.ledger.path"
  printf '%s orchestrator %s\n' "$hash" "$gate_round" > "$S/state/pr$n.approval"
  echo "PR $n orchestrator approval bound to current change (gate round $gate_round)";;

review)
  n=${1:?plan PR number} r=${2:?round}; mode=${3:-all}; W=$(wt "$n"); P=$S/runs/pr$n-rev$r.prompt
  [ -s "$S/runs/pr$n.report" ] || die "write the implementer report to $S/runs/pr$n.report first"
  impl=$(conf implementer); [ "${impl:-claude}" = claude ] && job "pr$n-implement" "$n" implement anthropic claude "$(effort_for implementer)" done "$S/runs/pr$n.report"
  setst "$n" "review round $r"
  { echo "Review only. Do not edit, commit, push, comment on PRs, or start subagents."
    echo "Repo: $W (a git worktree). The change under review is the uncommitted working tree against this branch's base commit $(cat "$S/runs/pr$n.base"): run \`git diff $(cat "$S/runs/pr$n.base")\` and read untracked files (\`git status --short\`). origin/$BASE may have moved on since the branch was cut; changes that exist only there are not part of this PR and are not regressions. Ignore node_modules symlinks."
    echo "Intent: plan PR $n from $PLAN (round $r). The plan item and the implementer's report follow."
    echo "Read surrounding code. Find bugs, broken callers, mismatch with intent, and regressions of existing behaviour."
    echo "Skip style unless it hides a bug. Hold to the smallest change. Flag code, tests, or guards the intent does not need. Other paths, rare cases, small perf, extra compat: nits."
    echo "blocker = intended case wrong. should = real bug callers will hit, in intent. nit = rest."
    echo "Reply:"; echo "VERDICT: APPROVE or CHANGES"; echo "S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)"
    echo; echo "=== Plan item ==="; cat "$S/runs/pr$n.task"
    echo; echo "=== Implementer report ==="; cat "$S/runs/pr$n.report"
    [ "$r" -gt 1 ] && [ -f "$S/runs/pr$n-rev$((r-1)).out" ] && { echo; echo "=== Earlier findings (verify they are fixed) ==="; cat "$S/runs/pr$n-rev$((r-1)).out"; }
  } > "$P"
  [[ $mode = panel || $mode = gate || $mode = all ]] || die "review mode must be all, panel or gate"
  before=$(change_hash "$n") || exit 1
  rm -f "$S/state/pr$n.approval" "$S/state/pr$n.gate"
  dropped=()
  if [ "$mode" = panel ] || [ "$mode" = all ]; then
    pids=(); ids=(); gate_pid=""
    if [ "$mode" = all ]; then
      # The gate reviewer runs in the same round as the panel, in parallel.
      model=$(conf reviewer)
      "$SKILL/dashboard/run-job.sh" "pr$n-rev$r-gate" "$n" review "$(conf reviewerProvider)" "$model" "$(effort_for reviewer)" "$W" "$S/runs/pr$n-rev$r-gate.out" "$S/runs/pr$n-rev$r-gate.log" -- "$P" &
      gate_pid=$!
    fi
    while IFS=$'\t' read -r p_provider p_model p_effort p_slug; do
      id=pr$n-rev$r-$p_slug; ids+=("$id")
      "$SKILL/dashboard/run-job.sh" "$id" "$n" review "$p_provider" "$p_model" "$p_effort" "$W" "$S/runs/$id.out" "$S/runs/$id.log" -- "$P" &
      pids+=("$!")
    done < <(python3 - "$S/config.json" <<'EOF'
import json,re,sys
for i, m in enumerate(json.load(open(sys.argv[1]))['reviewPanel']):
    slug=re.sub('[^a-z0-9]+','-',m['model'].lower()).strip('-')
    print(m['provider'],m['model'],m['effort'],str(i)+'-'+slug,sep='\t')
EOF
)
    : > "$S/runs/pr$n-rev$r.out"
    failed=0; approved=1
    if [ "$mode" = all ]; then
      # Watch every reviewer at once: Astra failing or the round timing out stops the rest
      # (their outputs stay); a panel member that fails or hangs is noted, not waited on.
      limit=$(conf reviewTimeout); deadline=$(( $(date +%s) + ${limit:-1200} ))
      declare -A rcs=()
      while :; do
        for i in "${!pids[@]}"; do
          [ -n "${rcs[$i]:-}" ] && continue
          kill -0 "${pids[$i]}" 2>/dev/null && continue
          rc=0; wait "${pids[$i]}" || rc=$?; rcs[$i]=$rc
        done
        if [ -z "${rcs[gate]:-}" ] && ! kill -0 "$gate_pid" 2>/dev/null; then
          rc=0; wait "$gate_pid" || rc=$?; rcs[gate]=$rc
        fi
        pending=0; for i in "${!pids[@]}"; do [ -n "${rcs[$i]:-}" ] || pending=1; done
        [ -n "${rcs[gate]:-}" ] || pending=1
        [ "$pending" = 0 ] && break
        timed_out=0; [ "$(date +%s)" -ge "$deadline" ] && timed_out=1
        if [ "$timed_out" = 1 ] || { [ -n "${rcs[gate]:-}" ] && [ "${rcs[gate]}" != 0 ]; }; then
          for i in "${!pids[@]}"; do
            [ -n "${rcs[$i]:-}" ] && continue
            echo "cm: stopping panel member ${ids[$i]} (round ended without it)" >&2
            stop_jobs id "${ids[$i]}"; wait "${pids[$i]}" 2>/dev/null; rcs[$i]=124; dropped+=("${ids[$i]}")
          done
          if [ -z "${rcs[gate]:-}" ]; then
            echo "cm: gate reviewer timed out" >&2
            stop_jobs id "pr$n-rev$r-gate"; wait "$gate_pid" 2>/dev/null; rcs[gate]=124; dropped+=("pr$n-rev$r-gate")
          fi
          break
        fi
        sleep 1
      done
      for i in "${!pids[@]}"; do
        if [ "${rcs[$i]}" != 0 ]; then approved=0; echo "cm: panel member ${ids[$i]} failed or timed out; noted" >&2; fi
        out=$S/runs/${ids[$i]}.out
        python3 "$SKILL/reviews.py" clean "$out" || approved=0
        cat "$out" | tee -a "$S/runs/pr$n-rev$r.out"
      done
      ids+=("pr$n-rev$r-gate")
      [ "${rcs[gate]}" = 0 ] || failed=1
      out=$S/runs/pr$n-rev$r-gate.out
      python3 "$SKILL/reviews.py" clean "$out" || approved=0
      cat "$out" | tee -a "$S/runs/pr$n-rev$r.out"
    else
      for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || failed=1
        out=$S/runs/${ids[$i]}.out
        python3 "$SKILL/reviews.py" clean "$out" || approved=0
        cat "$out" | tee -a "$S/runs/pr$n-rev$r.out"
      done
    fi
  else
    ids=("pr$n-rev$r")
    model=$(conf reviewer)
    "$SKILL/dashboard/run-job.sh" "pr$n-rev$r" "$n" review "$(conf reviewerProvider)" "$model" "$(effort_for reviewer)" "$W" "$S/runs/pr$n-rev$r.out" "$S/runs/pr$n-rev$r.log" -- "$P"; failed=$?
    out=$S/runs/pr$n-rev$r.out; approved=0
    if [ "$failed" = 0 ] && python3 "$SKILL/reviews.py" clean "$out"; then approved=1; fi
    tail -n 40 "$out"
  fi
  # Preserve all panel outputs, including findings from an unsuccessful run.
  outputs=()
  for id in "${ids[@]}"; do
    [ ! -f "$S/runs/$id.out" ] || outputs+=("$S/runs/$id.out")
  done
  if [ "$mode" = panel ]; then
    python3 "$SKILL/reviews.py" record "$S/state/pr$n.reviews.json" "$mode" "$r" "${outputs[@]}" || exit 1
  fi
  exec 8<>"$S/dashboard/jobs.json"; flock 8
  [[ $(cat "$S/state/pr$n") = stopped* ]] && exit 1
  # A stopped job may exit zero after trapping TERM; it still cannot approve.
  if python3 - "$S/dashboard/jobs.json" "${#dropped[@]}" "${dropped[@]}" "${ids[@]}" <<'EOF'
import json,sys
k=int(sys.argv[2]); dropped=set(sys.argv[3:3+k]); ids=set(sys.argv[3+k:])-dropped
sys.exit(not any(j['id'] in ids and j['status']=='stopped' for j in json.load(open(sys.argv[1]))['jobs']))
EOF
  then setst "$n" "needs-attention: review stopped"; exit 1; fi
  if [ "$failed" != 0 ]; then
    setst "$n" "needs-attention: reviewer job failed"; exit 1
  elif [ "$before" != "$(change_hash "$n")" ]; then
    setst "$n" "needs-attention: change moved during review"; exit 1
  else
    if [ "$mode" = gate ] || [ "$mode" = all ]; then
      python3 "$SKILL/reviews.py" record "$S/state/pr$n.reviews.json" "$mode" "$r" "${outputs[@]}" || exit 1
    fi
    if { [ "$mode" = gate ] || [ "$mode" = all ]; } && grep -qxE 'VERDICT: (APPROVE|CHANGES)' "$out"; then
      verdict=CHANGES; [ "$approved" = 1 ] && verdict=APPROVE
      printf '%s %s %s\n' "$before" "$r" "$verdict" > "$S/state/pr$n.gate"
    fi
    if [ "$approved" = 1 ]; then
      { [ "$mode" = gate ] || [ "$mode" = all ]; } && printf '%s %s %s\n' "$before" "$model" "$r" > "$S/state/pr$n.approval"
      setst "$n" "$mode approved round $r"
    else setst "$n" "changes round $r"; fi
  fi
  cat "$S/state/pr$n";;

bot-review)
  # Waits for a PR review bot that keeps a codex-review-state summary comment (chatgpt-codex-connector).
  # It re-reviews new commits by itself. Unresolved bot threads block; resolve a thread on GitHub once it is
  # fixed or judged not worth fixing.
  n=${3:-}; [ -z "$n" ] || active "$n"
  pr=${1:?pr}; bot=$(conf botReview); [ -n "$bot" ] || { echo "no botReview configured; skipping"; exit 0; }
  head=${2:-$(gh pr view "$pr" --repo "$GH" --json headRefOid -q .headRefOid)}
  limit=$(conf botTimeout); limit=${limit:-900}; t0=$(date +%s); poked=""
  while :; do
    [ -z "$n" ] || active "$n"
    read -r sha status < <(python3 "$SKILL/bot_review.py" state "$GH" "$pr" "$bot" 2>/dev/null || echo "- -")
    if [ "$sha" = "$head" ] && [ "$status" = completed ]; then break; fi
    [ "$sha" = "$head" ] && [ "$status" = failed ] && { echo "bot review failed on ${head:0:8}"; exit 7; }
    el=$(( $(date +%s) - t0 ))
    [ $el -ge "$limit" ] && { echo "bot review not finished on ${head:0:8} after ${limit}s (last: ${sha:0:8} $status)"; exit 7; }
    # Nudge once if the bot has not picked up the head commit after 5 minutes.
    [ -z "$poked" ] && [ $el -ge 300 ] && [ "$sha" != "$head" ] && { [ -z "$n" ] || active "$n"; gh pr comment "$pr" --repo "$GH" --body "@codex review" >/dev/null; poked=1; }
    sleep 15
  done
  open=$(python3 "$SKILL/bot_review.py" open "$GH" "$pr" "$bot") || { echo "could not read review threads"; exit 7; }
  if [ -z "$open" ]; then echo "bot review clean on ${head:0:8}"; exit 0; fi
  echo "bot review on ${head:0:8}: unresolved findings (thread id, place, title):"; echo "$open"; exit 6;;

gate)
  mode=${1:?check|merge}; shift
  if [ "$mode" = merge ]; then pr=${1:?pr}; ref=${2:?ref}; expected=${3:?expected head sha}; n=${4:-}; else ref=${1:?ref}; n=${2:-}; fi
  if [ -z "$n" ] && [[ $ref = council/"$SLUG"-* ]]; then n=${ref##*-}; fi
  if [ "$mode" = merge ]; then [[ $n =~ ^[0-9]+$ ]] || die "gate merge needs the plan PR number"; fi
  [ -z "$n" ] || active "$n"
  # One gate per repo: every plan builds in the same verify worktree.
  exec 9>"$ROOT/gate-$(basename "$R").lock"; flock 9
  [ -z "$n" ] || active "$n"
  git -C "$R" fetch -q origin "$BASE" "$ref" || exit 5
  main=$(git -C "$R" rev-parse "origin/$BASE")
  head=$(git -C "$R" rev-parse "origin/$ref" 2>/dev/null || git -C "$R" rev-parse FETCH_HEAD)
  if [ "$mode" = merge ] && [ "$head" != "$expected" ]; then echo "head moved: expected $expected, got $head"; exit 9; fi
  if [ "$mode" = merge ]; then
    shipping_evidence "$(change_hash "$n" committed "$expected")"
    [ "$(cat "$S/state/pr$n.head" 2>/dev/null)" = "$expected" ] || { echo "head does not match shipped commit"; exit 9; }
  fi
  [ -z "$n" ] || active "$n"
  [ -d "$V" ] || git -C "$R" worktree add -q --detach "$V" "$main"
  [ -z "$n" ] || active "$n"
  out=$(git -C "$V" merge-tree --write-tree "$main" "$head") || { echo "conflicts with $BASE"; exit 3; }; tree=${out%%$'\n'*}
  [ -z "$n" ] || active "$n"
  git -C "$V" checkout -q --detach -f "$main" || exit 1
  [ -z "$n" ] || active "$n"
  git -C "$V" read-tree -u --reset "$tree" || exit 1
  log=$S/runs/gate-${ref//\//_}.log
  [ -z "$n" ] || active "$n"
  ( cd "$V/$(conf gateDir)" && set -e; echo "== gate: $BASE ${main:0:8} + $ref ${head:0:8}"; eval "$(conf gate)" ) > "$log" 2>&1; rc=$?
  [ -z "$n" ] || active "$n"
  git -C "$V" checkout -q --detach -f "$main"
  [ -z "$n" ] || active "$n"
  git -C "$V" clean -qfd
  [ $rc = 0 ] || { echo "gate FAILED: $log"; tail -n 20 "$log"; exit 1; }
  echo "gate passed: $BASE ${main:0:8} + $ref ${head:0:8}"
  [ "$mode" = merge ] || exit 0
  [ "$(git -C "$R" ls-remote origin "refs/heads/$BASE" | cut -f1)" = "$main" ] || { echo "$BASE moved"; exit 4; }
  [ "$(git -C "$R" ls-remote origin "refs/heads/$ref" | cut -f1)" = "$expected" ] || { echo "head moved"; exit 9; }
  subject="$(gh pr view "$pr" --repo "$GH" --json title -q .title) (#$pr)"
  shipping_evidence "$(change_hash "$n" committed "$expected")"
  [ "$(cat "$S/state/pr$n.head" 2>/dev/null)" = "$expected" ] || exit 9
  active "$n"
  merge_active gh pr merge "$pr" --repo "$GH" --squash --subject "$subject" --match-head-commit "$head" >/dev/null 2>&1 || exit 5
  echo "merged #$pr onto ${main:0:8}";;

ship)
  no_merge=false; [ "${1:-}" = --no-merge ] && { no_merge=true; shift; }
  n=${1:?plan PR number}; W=$(wt "$n") b=$(br "$n")
  # Serialize staging and commits without blocking cm stop.
  exec 6>"$S/state/pr$n.ship.lock"; flock 6
  active "$n"
  hash=$(change_hash "$n") || exit 1
  shipping_evidence "$hash"
  approved=$hash
  [ -s "$S/runs/pr$n.title" ] && [ -s "$S/runs/pr$n.body" ] || die "write $S/runs/pr$n.title and pr$n.body first"
  shipst "$n" "shipping: commit + gate"
  if [ -n "$(git -C "$W" status --porcelain -- . ":!$PLAN")" ]; then
    active "$n"
    git -C "$W" add -A -- . ":!$PLAN" || die "cannot stage change"
    active "$n"
    git -C "$W" reset -q HEAD -- "$PLAN" || die "cannot exclude plan"
    while IFS= read -r -d '' dep; do
      active "$n"
      git -C "$W" reset -q -- "${dep#./}" || die "cannot exclude $dep"
    done < <(cd "$W" && find . -maxdepth 4 -name node_modules -type l -print0)
    [ "$(change_hash "$n" staged)" = "$approved" ] || { echo "cm: staged change differs from approval" >&2; exit 8; }
    active "$n"
    { cat "$S/runs/pr$n.title"; echo; if [ "$(conf adhoc)" = True ]; then echo "One-off PR $n."; else echo "PR $n in $PLAN."; fi; t=$(conf trailer); [ -n "$t" ] && { echo; echo "$t"; }; } > "$S/runs/pr$n.msg"
    before=$(git -C "$W" rev-parse HEAD)
    active "$n"
    git -C "$W" commit -q -F "$S/runs/pr$n.msg" || { shipst "$n" "needs-attention: commit failed"; die "commit failed"; }
    active "$n"
    if [ "$(change_hash "$n" committed)" != "$approved" ]; then
      active "$n"
      git -C "$W" reset --soft "$before" || die "cannot undo unapproved commit"
      shipst "$n" "needs-attention: committed change differs from approval"; exit 8
    fi
  fi
  active "$n"
  head=$(git -C "$W" rev-parse HEAD)
  shipping_evidence "$(change_hash "$n" committed "$head")"
  [ "$(git -C "$W" rev-parse HEAD)" != "$(cat "$S/runs/pr$n.base")" ] || { shipst "$n" "needs-attention: nothing to ship"; die "nothing to ship"; }
  flock -u 6
  # Keep the last observed remote SHA; never overwrite an intervening push.
  seen_file=$S/state/pr$n.remote
  if [ ! -f "$seen_file" ]; then
    active "$n"
    git -C "$W" ls-remote --exit-code origin "refs/heads/$b" > "$seen_file.tmp"; rc=$?
    [ $rc = 0 ] || [ $rc = 2 ] || { rm -f "$seen_file.tmp"; die "cannot read remote head"; }
    active "$n"
    if [ $rc = 0 ]; then
      rm -f "$seen_file.tmp"
      echo "cm: branch exists on origin and we never pushed it; take it over explicitly with \`cm adopt $n\`" >&2; exit 11
    fi
    cut -f1 "$seen_file.tmp" > "$seen_file"; rm -f "$seen_file.tmp"
  fi
  seen=$(cat "$seen_file")
  active "$n"
  if [ -n "$seen" ]; then
    git -C "$W" push -q "--force-with-lease=refs/heads/$b:$seen" origin "$head:refs/heads/$b" || { shipst "$n" "needs-attention: push lease refused"; exit 1; }
  else
    git -C "$W" push -q "--force-with-lease=refs/heads/$b:" origin "$head:refs/heads/$b" || { shipst "$n" "needs-attention: push failed"; exit 1; }
  fi
  active "$n"
  echo "$head" > "$S/state/pr$n.head"
  active "$n"
  echo "$head" > "$seen_file"
  active "$n"
  "$0" gate check "$b" "$n"; rc=$?
  active "$n"
  [ $rc = 3 ] && { shipst "$n" "needs-attention: conflicts with $BASE (merge origin/$BASE in $W, resolve, commit, ship again)"; exit 3; }
  [ $rc = 0 ] || { shipst "$n" "needs-attention: gate check failed ($S/runs/gate-${b//\//_}.log)"; exit 1; }
  pr=$(gh pr list --repo "$GH" --head "$b" --state open --json number -q '.[0].number')
  if [ -z "$pr" ]; then
    active "$n"
    url=$(cd "$R" && gh pr create --repo "$GH" --head "$b" --base "$BASE" --title "$(cat "$S/runs/pr$n.title")" --body-file "$S/runs/pr$n.body" 2>&1 | tail -1)
    pr=${url##*/}; [[ $pr =~ ^[0-9]+$ ]] || { shipst "$n" "needs-attention: pr create failed: $url"; die "$url"; }
  fi
  shipst "$n" "opened #$pr: waiting for bot review"
  active "$n"
  "$0" bot-review "$pr" "$head" "$n"; rc=$?
  active "$n"
  [ $rc = 6 ] && { shipst "$n" "needs-attention: bot findings on #$pr (fix and ship again, or resolve the threads)"; exit 6; }
  [ $rc = 0 ] || { shipst "$n" "needs-attention: bot review did not finish on #$pr"; exit 7; }
  shipst "$n" "opened #$pr: bot review clean"
  if [ "$no_merge" = true ]; then shipst "$n" "ready #$pr"; echo "ready #$pr (not merged)"; exit 0; fi
  for i in 1 2 3; do active "$n"; "$0" gate merge "$pr" "$b" "$head" "$n"; rc=$?; active "$n"; [ $rc = 4 ] || [ $rc = 1 ] && [ $i -lt 3 ] && continue; break; done
  if [ $rc = 0 ]; then shipst "$n" "merged #$pr"; active "$n"; git -C "$R" worktree remove --force "$W"; active "$n"; git -C "$R" branch -D "$b" >/dev/null 2>&1; echo "merged #$pr"
  else shipst "$n" "needs-attention: merge rc=$rc for #$pr"; exit $rc; fi;;

status)
  for f in "$S"/state/pr*; do [[ ${f##*/} =~ ^pr[0-9]+$ ]] && [ -e "$f" ] && printf '%s: %s\n' "${f##*/pr}" "$(head -1 "$f")"; done | sort -n;;

dashboard)
  if [ "${1:-}" = stop ]; then pid=$(cat "$S/dashboard/serve.pid" 2>/dev/null) && kill "$pid" && rm -f "$S/dashboard/serve.pid"; exit 0; fi
  port=$(conf port)
  while [ $# -gt 0 ]; do case $1 in
    --transcript) python3 - "$S/config.json" "$(readlink -f "$2")" <<'EOF'
import json,sys
c=json.load(open(sys.argv[1])); c["transcript"]=sys.argv[2]; json.dump(c,open(sys.argv[1],"w"),indent=1)
EOF
      shift 2;;
    --port) port=$2; shift 2;; *) die "unknown option $1";; esac; done
  pid=$(cat "$S/dashboard/serve.pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null && { echo "board already running: http://127.0.0.1:$port (pid $pid)"; exit 0; }
  nohup python3 "$SKILL/dashboard/serve.py" --port "$port" > "$S/dashboard/server.log" 2>&1 &
  echo $! > "$S/dashboard/serve.pid"; sleep 2
  kill -0 "$(cat "$S/dashboard/serve.pid")" 2>/dev/null || { tail -5 "$S/dashboard/server.log"; die "board failed to start"; }
  echo "board: http://127.0.0.1:$port";;

*) sed -n '2,17p' "$0"; exit 1;;
esac
