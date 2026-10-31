#!/usr/bin/env bash
# cm.sh: drive a council plan file to merged PRs, one PR item at a time.
#
#   cm.sh init <plan.md> [--repo DIR] [--gh owner/repo] [--title T] [--gate-dir DIR] [--gate "CMDS"]
#                        [--reviewer MODEL] [--implementer MODEL|claude] [--effort LEVEL] [--implementer-effort LEVEL] [--reviewer-effort LEVEL] [--trailer "Co-Authored-By: ..."] [--port N]
#                        [--bot-review LOGIN] [--bot-timeout SECONDS]
#   cm.sh use <slug>                   make another initialised plan current
#   cm.sh new <n>                      worktree + branch for plan PR <n>, from origin/<default>
#   cm.sh implement <n> [extra.md...]    Codex implementer (config implementer) writes the change in the worktree
#   cm.sh stop <n> [reason]            mark a PR stopped (not active) and close its running jobs
#   cm.sh verify <n>                  bind runs/pr<n>.proof to the current change
#   cm.sh stop-job <id>               stop one job process group
#   cm.sh review <n> <round> [panel|gate]           read-only review of the uncommitted change (needs runs/pr<n>.report);
#   cm.sh ship <n>                     commit, push, gate, open the PR, gate again, merge, remove the worktree
#                                      (needs runs/pr<n>.title and runs/pr<n>.body)
#   cm.sh bot-review <pr> [head-sha]   wait for the GitHub review bot (config botReview) to finish on the head commit;
#                                      exit 0 clean, 6 unresolved findings (printed), 7 failed or timed out
#   cm.sh gate check <ref> | gate merge <pr> <ref> <expected-head>
#   cm.sh status                       one line per PR from the state dir
#   cm.sh dashboard [--transcript F] [--port N] | dashboard stop
#   cm.sh path                         print the state dir (runs/, state/, dashboard/)
#
# With more than one plan, name yours on every call: COUNCIL_PLAN=<slug> cm.sh <command> (slug: printed by init).
# State lives in ~/.local/state/council/<slug>/ (current plan: ~/.local/state/council/current).
# Exit codes for gate: 0 pass/merged, 1 build failed, 3 conflicts with main, 4 main moved, 5 merge refused.
set -u
SKILL=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
ROOT=${COUNCIL_HOME:-$HOME/.local/state/council}
die() { echo "cm: $*" >&2; exit 1; }

cmd=${1:-}; shift || true

if [ "$cmd" = init ]; then
  plan=${1:?plan file}; shift
  repo=$(git -C "$(dirname "$(readlink -f "$plan")")" rev-parse --show-toplevel) || die "plan is not in a git repo"
  models=$(python3 "$SKILL/models.py" "${SIDSTACK_MODELS:-$HOME/.local/share/sidstack/models.md}") || die "cannot read models.md"
  model_field() { python3 -c 'import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]][0][sys.argv[3]])' "$models" "$1" "$2"; }
  # Defaults follow ~/.local/share/sidstack/models.md: Sol implements, Astra reviews, the Codex GitHub bot gates merges.
  gh="" title="" gate_dir="." gate="" reviewer=$(model_field reviewer model) implementer=$(model_field implementer model) effort="" impl_effort="" rev_effort="" trailer="" port=8787 bot="chatgpt-codex-connector" bot_timeout=900
  while [ $# -gt 0 ]; do case $1 in
    --repo) repo=$2; shift 2;; --gh) gh=$2; shift 2;; --title) title=$2; shift 2;;
    --gate-dir) gate_dir=$2; shift 2;; --gate) gate=$2; shift 2;; --reviewer) reviewer=$2; shift 2;; --implementer) implementer=$2; shift 2;;
    --effort) effort=$2; shift 2;; --implementer-effort) impl_effort=$2; shift 2;; --reviewer-effort) rev_effort=$2; shift 2;; --trailer) trailer=$2; shift 2;; --port) port=$2; shift 2;;
    --bot-review) bot=$2; shift 2;; --bot-timeout) bot_timeout=$2; shift 2;;
    *) die "unknown option $1";; esac; done
  impl_effort=${impl_effort:-${effort:-$(model_field implementer effort)}}
  rev_effort=${rev_effort:-${effort:-$(model_field reviewer effort)}}
  [ -n "$gh" ] || gh=$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner) || die "pass --gh owner/repo"
  [ -n "$gate" ] || die "pass --gate with the commands the deploy runs (install, typecheck, builds)"
  relplan=$(realpath --relative-to="$repo" "$plan")
  slug=$(basename "$repo")-$(basename "$relplan" .md | tr 'A-Z_ ' 'a-z--')
  S=$ROOT/$slug; mkdir -p "$S/runs" "$S/state" "$S/dashboard"
  base=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'); base=${base:-main}
  python3 - "$S/config.json" "$repo" "$gh" "$relplan" "$title" "$base" "$slug" "$gate_dir" "$gate" "$reviewer" "$implementer" "$effort" "$trailer" "$port" "$impl_effort" "$rev_effort" "$bot" "$bot_timeout" "$models" <<'EOF'
import json,os,sys
out,repo,gh,plan,title,base,slug,gate_dir,gate,reviewer,implementer,effort,trailer,port,impl_effort,rev_effort,bot,bot_timeout,models=sys.argv[1:]
models=json.loads(models)
old=json.load(open(out)) if os.path.exists(out) else {}
json.dump({"repo":repo,"gh":gh,"plan":plan,"title":title or None,"base":base,"slug":slug,
  "worktrees":os.path.join(os.path.dirname(repo),os.path.basename(repo)+"-wt"),"gateDir":gate_dir,"gate":gate,
  "reviewerProvider":models["reviewer"][0]["provider"],"implementerProvider":models["implementer"][0]["provider"],"reviewPanel":models["review panel"],"hardestTasks":models["hardest tasks"][0],
  "reviewer":reviewer,"implementer":implementer,"effort":effort,**({"implementerEffort":impl_effort} if impl_effort else {}),**({"reviewerEffort":rev_effort} if rev_effort else {}),"trailer":trailer,"port":int(port),"botReview":bot or None,"botTimeout":int(bot_timeout),"transcript":old.get("transcript")},open(out,"w"),indent=1)
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
import json, subprocess, sys
path, parser, source = sys.argv[1:]
c = json.load(open(path))
fields = {'reviewerProvider': ('reviewer', 'provider'),
          'implementerProvider': ('implementer', 'provider'),
          'reviewPanel': ('review panel', None), 'hardestTasks': ('hardest tasks', None)}
if any(key not in c for key in fields):
    models = json.loads(subprocess.check_output(['python3', parser, source]))
    for key, (role, field) in fields.items():
        value = models[role] if key == 'reviewPanel' else models[role][0]
        c.setdefault(key, value[field] if field else value)
    with open(path, 'w') as f: json.dump(c, f, indent=1)
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

# Hash the exact tracked diff and untracked paths and bytes, including symlink targets.
change_hash() {
  python3 - "$(wt "$1")" "$(cat "$S/runs/pr$1.base")" <<'EOF'
import hashlib, os, subprocess, sys
w, base = sys.argv[1:]
def git(*args):
    return subprocess.check_output(['git', '-C', w, *args])
h = hashlib.sha256()
h.update(git('diff', '--no-ext-diff', '--binary', base, '--'))
for path in sorted(filter(None, git('ls-files', '--others', '--exclude-standard', '-z').split(b'\0'))):
    full = os.path.join(os.fsencode(w), path)
    content = os.readlink(full) if os.path.islink(full) else open(full, 'rb').read()
    h.update(b'\0' + path + b'\0' + str(len(content)).encode() + b'\0' + content)
print(h.hexdigest())
EOF
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
        (Path(s)/f"state/pr{j['plan']}.approval").unlink(missing_ok=True)
        if j.get('status') != 'running':
            continue
        pidfile = Path(s)/f"runs/{j['id']}.pid"
        pid = int(pidfile.read_text()) if pidfile.exists() else j.get('pid')
        if pid and pid > 1:
            groups.append(pid)
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
        for pid in groups:
            try: os.killpg(pid, 0); alive.append(pid)
            except ProcessLookupError: pass
        groups = alive
        if not groups: break
        time.sleep(.1)
    for pid in groups:
        try: os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError: pass
EOF
}

case $cmd in
path) echo "$S";;

new)
  n=${1:?plan PR number}; W=$(wt "$n")
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
  n=${1:?plan PR number}; setst "$n" "stopped: ${2:-stopped by the orchestrator}"
  rm -f "$S/state/pr$n.approval"
  stop_jobs plan "$n"
  echo "PR $n stopped";;

stop-job)
  stop_jobs id "${1:?job id}";;

verify)
  n=${1:?plan PR number}
  [ -s "$S/runs/pr$n.proof" ] || {
    echo "Write runs/pr$n.proof: run the real thing (covering tests with pass counts; for UI, the app in a browser with a screenshot path); green mocked tests alone are not proof." >&2
    exit 10
  }
  change_hash "$n" > "$S/state/pr$n.verified" || exit 1
  echo "PR $n verification bound to current change";;

review)
  n=${1:?plan PR number} r=${2:?round}; mode=${3:-gate}; W=$(wt "$n"); P=$S/runs/pr$n-rev$r.prompt
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
  [[ $mode = panel || $mode = gate ]] || die "review mode must be panel or gate"
  before=$(change_hash "$n") || exit 1
  rm -f "$S/state/pr$n.approval"
  if [ "$mode" = panel ]; then
    pids=(); ids=()
    while IFS=$'\t' read -r provider model effort slug; do
      id=pr$n-rev$r-$slug; ids+=("$id")
      "$SKILL/dashboard/run-job.sh" "$id" "$n" review "$provider" "$model" "$effort" "$W" "$S/runs/$id.out" "$S/runs/$id.log" -- "$P" &
      pids+=("$!")
    done < <(python3 - "$S/config.json" <<'EOF'
import json,re,sys
for i, m in enumerate(json.load(open(sys.argv[1]))['reviewPanel']):
    slug=re.sub('[^a-z0-9]+','-',m['model'].lower()).strip('-')
    print(m['provider'],m['model'],m['effort'],slug,sep='\t')
EOF
)
    : > "$S/runs/pr$n-rev$r.out"
    failed=0; approved=1
    for i in "${!pids[@]}"; do
      wait "${pids[$i]}" || failed=1
      out=$S/runs/${ids[$i]}.out
      grep -qx 'VERDICT: APPROVE' "$out" && ! grep -qE '\[(blocker|should)\]|^VERDICT: CHANGES$' "$out" || approved=0
      cat "$out" | tee -a "$S/runs/pr$n-rev$r.out"
    done
  else
    ids=("pr$n-rev$r")
    model=$(conf reviewer)
    "$SKILL/dashboard/run-job.sh" "pr$n-rev$r" "$n" review "$(conf reviewerProvider)" "$model" "$(effort_for reviewer)" "$W" "$S/runs/pr$n-rev$r.out" "$S/runs/pr$n-rev$r.log" -- "$P"; failed=$?
    out=$S/runs/pr$n-rev$r.out; approved=0
    if [ "$failed" = 0 ] && grep -qx 'VERDICT: APPROVE' "$out" && ! grep -qE '\[(blocker|should)\]|^VERDICT: CHANGES$' "$out"; then approved=1; fi
    tail -n 40 "$out"
  fi
  [[ $(cat "$S/state/pr$n") = stopped:* ]] && exit 1
  # A stopped job may exit zero after trapping TERM; it still cannot approve.
  if python3 - "$S/dashboard/jobs.json" "${ids[@]}" <<'EOF'
import json,sys
sys.exit(not any(j['id'] in sys.argv[2:] and j['status']=='stopped' for j in json.load(open(sys.argv[1]))['jobs']))
EOF
  then setst "$n" "needs-attention: review stopped"; exit 1; fi
  if [ "$failed" != 0 ]; then
    setst "$n" "needs-attention: reviewer job failed"; exit 1
  elif [ "$before" != "$(change_hash "$n")" ]; then
    setst "$n" "needs-attention: change moved during review"; exit 1
  elif [ "$approved" = 1 ]; then
    [ "$mode" = gate ] && printf '%s %s %s\n' "$before" "$model" "$r" > "$S/state/pr$n.approval"
    setst "$n" "$mode approved round $r"
  else setst "$n" "changes round $r"; fi
  cat "$S/state/pr$n";;

bot-review)
  # Waits for a PR review bot that keeps a codex-review-state summary comment (chatgpt-codex-connector).
  # It re-reviews new commits by itself. Unresolved bot threads block; resolve a thread on GitHub once it is
  # fixed or judged not worth fixing.
  pr=${1:?pr}; bot=$(conf botReview); [ -n "$bot" ] || { echo "no botReview configured; skipping"; exit 0; }
  head=${2:-$(gh pr view "$pr" --repo "$GH" --json headRefOid -q .headRefOid)}
  limit=$(conf botTimeout); limit=${limit:-900}; t0=$(date +%s); poked=""
  while :; do
    read -r sha status < <(python3 "$SKILL/bot_review.py" state "$GH" "$pr" "$bot" 2>/dev/null || echo "- -")
    if [ "$sha" = "$head" ] && [ "$status" = completed ]; then break; fi
    [ "$sha" = "$head" ] && [ "$status" = failed ] && { echo "bot review failed on ${head:0:8}"; exit 7; }
    el=$(( $(date +%s) - t0 ))
    [ $el -ge "$limit" ] && { echo "bot review not finished on ${head:0:8} after ${limit}s (last: ${sha:0:8} $status)"; exit 7; }
    # Nudge once if the bot has not picked up the head commit after 5 minutes.
    [ -z "$poked" ] && [ $el -ge 300 ] && [ "$sha" != "$head" ] && { gh pr comment "$pr" --repo "$GH" --body "@codex review" >/dev/null; poked=1; }
    sleep 20
  done
  open=$(python3 "$SKILL/bot_review.py" open "$GH" "$pr" "$bot") || { echo "could not read review threads"; exit 7; }
  if [ -z "$open" ]; then echo "bot review clean on ${head:0:8}"; exit 0; fi
  echo "bot review on ${head:0:8}: unresolved findings (thread id, place, title):"; echo "$open"; exit 6;;

gate)
  mode=${1:?check|merge}; shift
  if [ "$mode" = merge ]; then pr=${1:?pr}; ref=${2:?ref}; expected=${3:?expected head sha}; else ref=${1:?ref}; fi
  # One gate per repo: every plan builds in the same verify worktree.
  exec 9>"$ROOT/gate-$(basename "$R").lock"; flock 9
  git -C "$R" fetch -q origin "$BASE" "$ref" || exit 5
  main=$(git -C "$R" rev-parse "origin/$BASE")
  head=$(git -C "$R" rev-parse "origin/$ref" 2>/dev/null || git -C "$R" rev-parse FETCH_HEAD)
  if [ "$mode" = merge ] && [ "$head" != "$expected" ]; then echo "head moved: expected $expected, got $head"; exit 9; fi
  [ -d "$V" ] || git -C "$R" worktree add -q --detach "$V" "$main"
  out=$(git -C "$V" merge-tree --write-tree "$main" "$head") || { echo "conflicts with $BASE"; exit 3; }; tree=${out%%$'\n'*}
  git -C "$V" checkout -q --detach -f "$main" && git -C "$V" read-tree -u --reset "$tree"
  log=$S/runs/gate-${ref//\//_}.log
  ( cd "$V/$(conf gateDir)" && set -e; echo "== gate: $BASE ${main:0:8} + $ref ${head:0:8}"; eval "$(conf gate)" ) > "$log" 2>&1; rc=$?
  git -C "$V" checkout -q --detach -f "$main"; git -C "$V" clean -qfd
  [ $rc = 0 ] || { echo "gate FAILED: $log"; tail -n 20 "$log"; exit 1; }
  echo "gate passed: $BASE ${main:0:8} + $ref ${head:0:8}"
  [ "$mode" = merge ] || exit 0
  [ "$(git -C "$R" ls-remote origin "refs/heads/$BASE" | cut -f1)" = "$main" ] || { echo "$BASE moved"; exit 4; }
  [ "$(git -C "$R" ls-remote origin "refs/heads/$ref" | cut -f1)" = "$expected" ] || { echo "head moved"; exit 9; }
  subject="$(gh pr view "$pr" --repo "$GH" --json title -q .title) (#$pr)"
  gh pr merge "$pr" --repo "$GH" --squash --subject "$subject" --match-head-commit "$head" >/dev/null 2>&1 || exit 5
  echo "merged #$pr onto ${main:0:8}";;

ship)
  n=${1:?plan PR number}; W=$(wt "$n") b=$(br "$n")
  hash=$(change_hash "$n") || exit 1
  read -r approved reviewer round 2>/dev/null < "$S/state/pr$n.approval" || approved=""
  if [ "$approved" != "$hash" ] || [ "${reviewer:-}" != "$(conf reviewer)" ]; then
    setst "$n" "needs-attention: no approval for the current change"; exit 8
  fi
  if [ "$(cat "$S/state/pr$n.verified" 2>/dev/null)" != "$hash" ]; then
    setst "$n" "needs-attention: no verification for the current change"; exit 10
  fi
  [ -s "$S/runs/pr$n.title" ] && [ -s "$S/runs/pr$n.body" ] || die "write $S/runs/pr$n.title and pr$n.body first"
  setst "$n" "shipping: commit + gate"
  if [ -n "$(git -C "$W" status --porcelain -- . ":!$PLAN")" ]; then
    git -C "$W" add -A -- . ":!$PLAN"
    while IFS= read -r -d '' dep; do
      git -C "$W" reset -q -- "${dep#./}" || die "cannot exclude $dep"
    done < <(cd "$W" && find . -maxdepth 4 -name node_modules -type l -print0)
    { cat "$S/runs/pr$n.title"; echo; echo "PR $n in $PLAN."; t=$(conf trailer); [ -n "$t" ] && { echo; echo "$t"; }; } > "$S/runs/pr$n.msg"
    git -C "$W" commit -q -F "$S/runs/pr$n.msg" || { setst "$n" "needs-attention: commit failed"; die "commit failed"; }
  fi
  [ "$(git -C "$W" rev-parse HEAD)" != "$(cat "$S/runs/pr$n.base")" ] || { setst "$n" "needs-attention: nothing to ship"; die "nothing to ship"; }
  # Keep the last observed remote SHA; never overwrite an intervening push.
  seen_file=$S/runs/pr$n.remote
  if [ ! -f "$seen_file" ]; then
    git -C "$W" ls-remote --exit-code origin "refs/heads/$b" > "$seen_file.tmp"; rc=$?
    [ $rc = 0 ] || [ $rc = 2 ] || { rm -f "$seen_file.tmp"; die "cannot read remote head"; }
    cut -f1 "$seen_file.tmp" > "$seen_file"; rm -f "$seen_file.tmp"
  fi
  seen=$(cat "$seen_file")
  if [ -n "$seen" ]; then
    git -C "$W" push -q "--force-with-lease=refs/heads/$b:$seen" origin "HEAD:refs/heads/$b" || { setst "$n" "needs-attention: push lease refused"; exit 1; }
  else
    git -C "$W" push -q origin "HEAD:refs/heads/$b" || { setst "$n" "needs-attention: push failed"; exit 1; }
  fi
  head=$(git -C "$W" rev-parse HEAD)
  echo "$head" > "$S/runs/pr$n.head"
  echo "$head" > "$seen_file"
  "$0" gate check "$b"; rc=$?
  [ $rc = 3 ] && { setst "$n" "needs-attention: conflicts with $BASE (merge origin/$BASE in $W, resolve, commit, ship again)"; exit 3; }
  [ $rc = 0 ] || { setst "$n" "needs-attention: gate check failed ($S/runs/gate-${b//\//_}.log)"; exit 1; }
  pr=$(gh pr list --repo "$GH" --head "$b" --state open --json number -q '.[0].number')
  if [ -z "$pr" ]; then
    url=$(cd "$R" && gh pr create --repo "$GH" --head "$b" --base "$BASE" --title "$(cat "$S/runs/pr$n.title")" --body-file "$S/runs/pr$n.body" 2>&1 | tail -1)
    pr=${url##*/}; [[ $pr =~ ^[0-9]+$ ]] || { setst "$n" "needs-attention: pr create failed: $url"; die "$url"; }
  fi
  setst "$n" "opened #$pr: waiting for bot review"
  "$0" bot-review "$pr" "$head"; rc=$?
  [ $rc = 6 ] && { setst "$n" "needs-attention: bot findings on #$pr (fix and ship again, or resolve the threads)"; exit 6; }
  [ $rc = 0 ] || { setst "$n" "needs-attention: bot review did not finish on #$pr"; exit 7; }
  setst "$n" "opened #$pr: bot review clean"
  for i in 1 2 3; do "$0" gate merge "$pr" "$b" "$head"; rc=$?; [ $rc = 4 ] || [ $rc = 1 ] && [ $i -lt 3 ] && continue; break; done
  if [ $rc = 0 ]; then setst "$n" "merged #$pr"; git -C "$R" worktree remove --force "$W"; git -C "$R" branch -D "$b" >/dev/null 2>&1; echo "merged #$pr"
  else setst "$n" "needs-attention: merge rc=$rc for #$pr"; exit $rc; fi;;

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
