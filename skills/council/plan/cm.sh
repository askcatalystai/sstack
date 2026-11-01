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
#   cm.sh implement <n> [--effort L] [--hardest] [extra.md...]  write the implementer's brief; the orchestrator runs it as a subagent
#   cm.sh implemented <n>              record that the implementer subagent wrote runs/pr<n>.report
#   cm.sh bugpass <n> start|done|failed  record the Cursor Composer bug pass (before Astra) as its own board job
#   cm.sh seat <name> <provider> <model> <effort> start|done|failed [reply-file]  record one council seat as its own board job, under PR 1
#   cm.sh stop <n> [reason]            mark a PR stopped (not active) and close its running jobs
#   cm.sh adopt <n>                   explicitly take over the current origin branch SHA
#   cm.sh verify <n>                  bind runs/pr<n>.proof to the current change
#   cm.sh brief <n> <round> [all|panel|gate|gate-after-panel]  write review briefs, pin the change hash, print
#                                      which subagent to run and where to save each reply (models never run from here)
#   cm.sh review <n> <round> [all|panel|gate]  record the round from the saved replies and apply the gates;
#                                      all (default): panel replies, then Astra's consolidated reply decides
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
# Default: Sol builds, a Composer bug pass runs first (pstack poteto bug-fix playbook: reproduce, root-cause, minimal fix), then Astra reviews and returns one list; the orchestrator takes the final call, Sol fixes once, the orchestrator verifies and approves.
# Every model runs as a subagent the orchestrator starts; cm writes briefs and records replies.
# One review round per PR: bug pass, then Astra once. After Sol fixes, the orchestrator verifies the fixes itself; no second round (user, 2026-11-01). "sol loop": Sol only, up to 3 rounds.
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
# Mark a PR's board jobs stopped; the orchestrator cancels the subagents themselves (task_cancel).
stop_jobs() {
  python3 - "$S" "$1" "$2" <<'EOF'
import fcntl, json, sys, time
from pathlib import Path
s, kind, target = sys.argv[1:]
p = Path(s)/'dashboard/jobs.json'
p.parent.mkdir(parents=True, exist_ok=True)
with open(p, 'a+') as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.seek(0)
    data = json.loads(f.read() or '{"jobs":[]}')
    for j in data['jobs']:
        if (str(j.get('plan')) if kind == 'plan' else j['id']) == target and j.get('status') == 'running':
            j['status'] = 'stopped'; j['finishedAt'] = time.strftime('%Y-%m-%dT%H:%M:%S%z')
    f.seek(0); f.truncate(); json.dump(data, f, indent=1)
EOF
}

case $cmd in
path) echo "$S";;

new)
  n=${1:?plan PR number}; task=${2:-}; W=$(wt "$n")
  if [ -n "$task" ]; then
    [ -s "$task" ] || die "task file $task is empty or missing"
    title=$(head -1 "$task" | sed 's/^#* *//; s/[[:space:]]*$//')
    [ -n "$title" ] || die "the task file's first line is its title; it is empty"
    # One task per PR number: the board and the implementer must read the same brief.
    if [ -s "$S/runs/pr$n.task" ] && ! cmp -s -- "$task" "$S/runs/pr$n.task"; then
      die "PR $n already has a different task; use a new PR number"
    fi
    cp -- "$task" "$S/runs/pr$n.task"
    pf=$(conf planFile)
    if [ -n "$pf" ] && ! grep -q "^### \[.\] PR $n " "$pf"; then
      { printf '### [ ] PR %s — %s\n' "$n" "$title"; tail -n +2 "$task"; echo; } >> "$pf"
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
  # Writes the implementer's brief. The orchestrator runs it as a subagent (never from the terminal),
  # then calls `cm implemented <n>` once the subagent has written runs/pr<n>.report.
  n=${1:?plan PR number}; W=$(wt "$n"); P=$S/runs/pr$n-impl.prompt; shift
  [ -d "$W" ] || die "run cm.sh new $n first"
  provider=$(conf implementerProvider); model=$(conf implementer); impl_effort=$(effort_for implementer)
  # --effort records the level the subagent actually runs at (shown on the board).
  if [ "${1:-}" = --effort ]; then impl_effort=${2:?effort}; shift 2; fi
  if [ "${1:-}" = --hardest ]; then
    read -r provider model impl_effort < <(python3 - "$S/config.json" <<'EOF'
import json,sys
m=json.load(open(sys.argv[1]))['hardestTasks']
print(m['provider'], m['model'], m['effort'])
EOF
)
    shift
  fi
  active_or_new() { [[ $(cat "$S/state/pr$n" 2>/dev/null) != stopped* ]] || die "PR $n is stopped"; }
  active_or_new
  clear_evidence "$n"
  rm -f "$S/runs/pr$n.report"
  what="plan PR $n from $PLAN"; [ "$(conf adhoc)" = True ] && what="one-off PR $n"
  { echo "Implement $what in this git worktree ($W). Work only here; do not commit, push or switch branches."
    echo "Make the smallest change that meets the acceptance check. Add a regression test that fails without the fix. Run the affected tests and the typecheck."
    echo "When done, write what was wrong, what changed (files), the proof (tests, counts) and what was not checked live to $S/runs/pr$n.report."
    for extra in "$@"; do echo; cat "$extra"; done
    echo; echo "=== Plan item ==="; cat "$S/runs/pr$n.task"
  } > "$P"
  setst "$n" "coding"
  job "pr$n-impl" "$n" implement "$provider" "$model" "$impl_effort" running "$S/runs/pr$n.report"
  echo "subagent: implementer $provider / $model / $impl_effort"
  echo "brief: $P"
  echo "then: cm implemented $n";;

bugpass)
  # Records the Cursor Composer bug pass (runs before Astra) as its own job on the board.
  # cm bugpass <n> start|done|failed   (the orchestrator runs the subagent; this only records it)
  n=${1:?plan PR number}; act=${2:-start}
  log="$S/runs/pr$n.bugpass"
  read -r prov model effort < <(python3 "$SKILL/models.py" "${SIDSTACK_MODELS:-$HOME/.local/share/sidstack/models.md}" | python3 -c 'import json,sys; d=json.load(sys.stdin).get("bug pass") or [{"provider":"cursor","model":"composer-2.5","effort":"-"}]; e=d[0]; print(e["provider"], e["model"], e["effort"])')
  case $act in
    start) COUNCIL_STATE="$S" job "pr$n-bugpass" "$n" bugpass "$prov" "$model" "$effort" running "$log"; setst "$n" "bug pass";;
    done|failed) COUNCIL_STATE="$S" job "pr$n-bugpass" "$n" bugpass "$prov" "$model" "$effort" "$act" "$log";;
    *) die "cm bugpass <n> start|done|failed";;
  esac
  echo "PR $n bug pass: $act";;

seat)
  # Each council seat is its own job on the board. The orchestrator runs the subagent; this only records it.
  name=${1:?seat name}; prov=${2:?provider}; model=${3:?model}; effort=${4:?effort}; act=${5:?start, done or failed}; log=${6:-$S/runs/seat-$name.reply}
  case $act in
    start) COUNCIL_STATE="$S" JOB_TITLE="Council: $name" job "seat-$name" 1 review "$prov" "$model" "$effort" running "$log";;
    done|failed) COUNCIL_STATE="$S" JOB_TITLE="Council: $name" job "seat-$name" 1 review "$prov" "$model" "$effort" "$act" "$log";;
    *) die "cm seat <name> <provider> <model> <effort> start|done|failed [reply-file]";;
  esac
  echo "seat $name: $act";;

implemented)
  n=${1:?plan PR number}
  [ -s "$S/runs/pr$n.report" ] || die "the implementer subagent has not written $S/runs/pr$n.report"
  [[ $(cat "$S/state/pr$n" 2>/dev/null) != stopped* ]] || die "PR $n is stopped"
  python3 - "$S/dashboard/jobs.json" "pr$n-impl" <<'EOF'
import json,sys,time
p,i=sys.argv[1:]
try: d=json.load(open(p))
except (OSError, ValueError): sys.exit()
for j in d.get('jobs',[]):
    if j['id']==i and j.get('status')=='running': j['status']='done'; j['finishedAt']=time.strftime('%Y-%m-%dT%H:%M:%S%z')
json.dump(d,open(p,'w'),indent=1)
EOF
  setst "$n" "implemented"; echo "PR $n implemented";;

stop)
  n=${1:?plan PR number}
  exec 7>"$S/state/pr$n.lock"; flock 7
  exec 8<>"$S/dashboard/jobs.json"; flock 8
  setst "$n" "stopped: ${2:-stopped by the orchestrator}"
  rm -f "$S/state/pr$n.approval" "$S/state/pr$n.verified"
  flock -u 8
  stop_jobs plan "$n"
  echo "PR $n stopped; cancel its running subagents (task_cancel)";;

adopt)
  n=${1:?plan PR number}; b=$(br "$n")
  seen=$(git -C "$R" ls-remote --exit-code origin "refs/heads/$b") || die "cannot read remote branch $b"
  echo "${seen%%$'\t'*}" > "$S/state/pr$n.remote"
  echo "adopted $b at ${seen%%$'\t'*}";;

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

brief)
  # Writes this round's review briefs and pins the change hash. The orchestrator runs each reviewer
  # as a subagent and saves its reply verbatim to the printed path, then runs `cm review <n> <r> [mode]`.
  # all: the panel first (in parallel), then `cm brief <n> <r> gate-after-panel` for Astra with the panel's findings.
  n=${1:?plan PR number} r=${2:?round}; mode=${3:-all}; W=$(wt "$n"); P=$S/runs/pr$n-rev$r.prompt
  [ -s "$S/runs/pr$n.report" ] || die "write the implementer report to $S/runs/pr$n.report first"
  [[ $(cat "$S/state/pr$n" 2>/dev/null) != stopped* ]] || die "PR $n is stopped"
  if [ "$mode" = gate-after-panel ]; then
    [ -s "$P" ] && [ -s "$S/state/pr$n.rev$r.hash" ] || die "run cm brief $n $r first"
    G=$S/runs/pr$n-rev$r-gate.prompt
    { cat "$P"
      echo; echo "=== Review panel findings for this round ==="
      echo "Check each finding against the code: confirm it (keep or correct its severity), reject it with evidence, and add anything the panel missed. Your reply is the single consolidated list the implementer fixes; restate every confirmed finding as your own S<n> line."
      while IFS=$'\t' read -r _ _ _ slug; do
        f=$S/runs/pr$n-rev$r-$slug.out
        echo; echo "--- pr$n-rev$r-$slug ---"
        if [ -s "$f" ]; then cat "$f"; else echo "(no reply: failed or timed out)"; fi
      done < <(python3 "$SKILL/panel.py" "$S/config.json")
    } > "$G"
    echo "subagent: gate $(conf reviewerProvider) / $(conf reviewer) / $(effort_for reviewer)"
    echo "brief: $G"; echo "save reply to: $S/runs/pr$n-rev$r-gate.out"
    job "pr$n-rev$r-gate" "$n" review "$(conf reviewerProvider)" "$(conf reviewer)" "$(effort_for reviewer)" running "$S/runs/pr$n-rev$r-gate.out"
    setst "$n" "review round $r: gate"; exit 0
  fi
  [[ $mode = all || $mode = panel || $mode = gate ]] || die "brief mode must be all, panel, gate or gate-after-panel"
  { echo "Review only. Do not edit, commit, push, comment on PRs, or start subagents."
    echo "Repo: $W (a git worktree). The change under review is the uncommitted working tree against this branch's base commit $(cat "$S/runs/pr$n.base"): run \`git diff $(cat "$S/runs/pr$n.base")\` and read untracked files (\`git status --short\`). origin/$BASE may have moved on since the branch was cut; changes that exist only there are not part of this PR and are not regressions. Ignore node_modules symlinks."
    what="plan PR $n from $PLAN"; [ "$(conf adhoc)" = True ] && what="one-off PR $n"
    echo "Intent: $what (round $r). The task and the implementer's report follow."
    echo "Read surrounding code. Find bugs, broken callers, mismatch with intent, and regressions of existing behaviour."
    echo "Skip style unless it hides a bug. Hold to the smallest change. Flag code, tests, or guards the intent does not need. Other paths, rare cases, small perf, extra compat: nits."
    echo "blocker = intended case wrong. should = real bug callers will hit, in intent. nit = rest."
    echo "Reply:"; echo "VERDICT: APPROVE or CHANGES"; echo "S1 [blocker|should|nit] <file>:<line> <claim>. Fix: <suggestion> (stable ids)"
    echo; echo "=== Plan item ==="; cat "$S/runs/pr$n.task"
    echo; echo "=== Implementer report ==="; cat "$S/runs/pr$n.report"
  } > "$P"
  change_hash "$n" > "$S/state/pr$n.rev$r.hash" || exit 1
  rm -f "$S/state/pr$n.approval" "$S/state/pr$n.gate" "$S/runs/pr$n-rev$r".out "$S/runs/pr$n-rev$r"-*.out
  # Reviewers run as subagents; the board shows each one as a running review job until the round is recorded.
  if [ "$mode" = gate ]; then
    echo "subagent: gate $(conf reviewerProvider) / $(conf reviewer) / $(effort_for reviewer)"
    echo "brief: $P"; echo "save reply to: $S/runs/pr$n-rev$r.out"
    job "pr$n-rev$r" "$n" review "$(conf reviewerProvider)" "$(conf reviewer)" "$(effort_for reviewer)" running "$S/runs/pr$n-rev$r.out"
  else
    while IFS=$'\t' read -r provider model effort slug; do
      echo "subagent: panel $provider / $model / $effort"; echo "brief: $P"; echo "save reply to: $S/runs/pr$n-rev$r-$slug.out"
      job "pr$n-rev$r-$slug" "$n" review "$provider" "$model" "$effort" running "$S/runs/pr$n-rev$r-$slug.out"
    done < <(python3 "$SKILL/panel.py" "$S/config.json")
    [ "$mode" = all ] && echo "then: cm brief $n $r gate-after-panel (Astra with the panel's findings)"
  fi
  setst "$n" "review round $r: $mode";;

review)
  # Records a round from the replies the orchestrator saved; launches nothing.
  n=${1:?plan PR number} r=${2:?round}; mode=${3:-all}
  [[ $mode = all || $mode = panel || $mode = gate ]] || die "review mode must be all, panel or gate"
  [ -s "$S/state/pr$n.rev$r.hash" ] || die "run cm brief $n $r $mode first"
  before=$(cat "$S/state/pr$n.rev$r.hash")
  exec 8<>"$S/dashboard/jobs.json"; flock 8
  [[ $(cat "$S/state/pr$n") = stopped* ]] && { echo "cm: PR $n is stopped" >&2; exit 1; }
  outputs=(); failed=0; approved=1; : > "$S/runs/pr$n-rev$r.all"
  if [ "$mode" != gate ]; then
    while IFS=$'\t' read -r _ _ _ slug; do
      f=$S/runs/pr$n-rev$r-$slug.out
      if [ -s "$f" ]; then outputs+=("$f"); cat "$f" >> "$S/runs/pr$n-rev$r.all"
        [ "$mode" = panel ] && { python3 "$SKILL/reviews.py" clean "$f" || approved=0; }
      else echo "cm: panel member pr$n-rev$r-$slug has no reply; noted" >&2; [ "$mode" = panel ] && failed=1; fi
    done < <(python3 "$SKILL/panel.py" "$S/config.json")
  fi
  if [ "$mode" != panel ]; then
    out=$S/runs/pr$n-rev$r.out; [ "$mode" = all ] && out=$S/runs/pr$n-rev$r-gate.out
    if [ -s "$out" ]; then outputs+=("$out"); cat "$out" >> "$S/runs/pr$n-rev$r.all"
      # Astra's consolidated verdict decides; the panel informed it.
      python3 "$SKILL/reviews.py" clean "$out" || approved=0
    else failed=1; fi
  fi
  if [ "$failed" != 0 ]; then
    setst "$n" "needs-attention: reviewer reply missing"; exit 1
  elif [ "$before" != "$(change_hash "$n")" ]; then
    setst "$n" "needs-attention: change moved during review"; exit 1
  fi
  python3 "$SKILL/reviews.py" record "$S/state/pr$n.reviews.json" "$mode" "$r" "${outputs[@]}" || exit 1
  python3 - "$S/dashboard/jobs.json" "pr$n-rev$r" <<'EOF'
import json,sys,time
p,prefix=sys.argv[1:]
try: d=json.load(open(p))
except (OSError, ValueError): sys.exit()
for j in d.get('jobs',[]):
    if (j['id']==prefix or j['id'].startswith(prefix+'-')) and j.get('status')=='running':
        j['status']='done'; j['finishedAt']=time.strftime('%Y-%m-%dT%H:%M:%S%z')
json.dump(d,open(p,'w'),indent=1)
EOF
  if [ "$mode" != panel ] && grep -qxE 'VERDICT: (APPROVE|CHANGES)' "$out"; then
    verdict=CHANGES; [ "$approved" = 1 ] && verdict=APPROVE
    printf '%s %s %s\n' "$before" "$r" "$verdict" > "$S/state/pr$n.gate"
  fi
  if [ "$approved" = 1 ]; then
    [ "$mode" != panel ] && printf '%s %s %s\n' "$before" "$(conf reviewer)" "$r" > "$S/state/pr$n.approval"
    setst "$n" "$mode approved round $r"
  else setst "$n" "changes round $r"; fi
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
