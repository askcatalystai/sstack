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
#   cm.sh review <n> <round>           read-only review of the uncommitted change (needs runs/pr<n>.report);
#                                      CM_REVIEWER=<model> CM_REVIEWER_EFFORT=<level> picks the round's reviewer
#   cm.sh ship <n>                     commit, push, gate, open the PR, gate again, merge, remove the worktree
#                                      (needs runs/pr<n>.title and runs/pr<n>.body)
#   cm.sh bot-review <pr> [head-sha]   wait for the GitHub review bot (config botReview) to finish on the head commit;
#                                      exit 0 clean, 6 unresolved findings (printed), 7 failed or timed out
#   cm.sh gate check <ref> | gate merge <pr> <ref>
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
  # Defaults follow ~/.local/share/sidstack/models.md: Sol implements, Astra reviews, the Codex GitHub bot gates merges.
  gh="" title="" gate_dir="." gate="" reviewer="gpt-6-astra" implementer="gpt-6.1-sol" effort="medium" impl_effort="high" rev_effort="low" trailer="" port=8787 bot="chatgpt-codex-connector" bot_timeout=900
  while [ $# -gt 0 ]; do case $1 in
    --repo) repo=$2; shift 2;; --gh) gh=$2; shift 2;; --title) title=$2; shift 2;;
    --gate-dir) gate_dir=$2; shift 2;; --gate) gate=$2; shift 2;; --reviewer) reviewer=$2; shift 2;; --implementer) implementer=$2; shift 2;;
    --effort) effort=$2; shift 2;; --implementer-effort) impl_effort=$2; shift 2;; --reviewer-effort) rev_effort=$2; shift 2;; --trailer) trailer=$2; shift 2;; --port) port=$2; shift 2;;
    --bot-review) bot=$2; shift 2;; --bot-timeout) bot_timeout=$2; shift 2;;
    *) die "unknown option $1";; esac; done
  [ -n "$gh" ] || gh=$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner) || die "pass --gh owner/repo"
  [ -n "$gate" ] || die "pass --gate with the commands the deploy runs (install, typecheck, builds)"
  relplan=$(realpath --relative-to="$repo" "$plan")
  slug=$(basename "$repo")-$(basename "$relplan" .md | tr 'A-Z_ ' 'a-z--')
  S=$ROOT/$slug; mkdir -p "$S/runs" "$S/state" "$S/dashboard"
  base=$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||'); base=${base:-main}
  python3 - "$S/config.json" "$repo" "$gh" "$relplan" "$title" "$base" "$slug" "$gate_dir" "$gate" "$reviewer" "$implementer" "$effort" "$trailer" "$port" "$impl_effort" "$rev_effort" "$bot" "$bot_timeout" <<'EOF'
import json,os,sys
out,repo,gh,plan,title,base,slug,gate_dir,gate,reviewer,implementer,effort,trailer,port,impl_effort,rev_effort,bot,bot_timeout=sys.argv[1:]
old=json.load(open(out)) if os.path.exists(out) else {}
json.dump({"repo":repo,"gh":gh,"plan":plan,"title":title or None,"base":base,"slug":slug,
  "worktrees":os.path.join(os.path.dirname(repo),os.path.basename(repo)+"-wt"),"gateDir":gate_dir,"gate":gate,
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
conf() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get(sys.argv[2]);print("" if v is None else v)' "$S/config.json" "$1"; }
# Per-role effort; falls back to the shared effort.
effort_for() { e=$(conf "${1}Effort"); echo "${e:-$(conf effort)}"; }
R=$(conf repo) GH=$(conf gh) PLAN=$(conf plan) BASE=$(conf base) SLUG=$(conf slug) WTS=$(conf worktrees)
V=$WTS/verify
wt() { echo "$WTS/$SLUG-$1"; }
br() { echo "council/$SLUG-$1"; }
setst() { echo "$2" > "$S/state/pr$1"; }
job() { python3 "$SKILL/dashboard/jobs.py" upsert "$@"; }

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
  model=$(conf implementer); [ -n "$model" ] && [ "$model" != claude ] || die "implementer is claude; set --implementer <codex model> in init"
  setst "$n" "coding"
  { echo "Implement plan PR $n from $PLAN in this git worktree ($W). Work only here; do not commit, push or switch branches."
    echo "Make the smallest change that meets the acceptance check. Add a regression test that fails without the fix. Run the affected tests and the typecheck."
    echo "When done, write what was wrong, what changed (files), the proof (tests, counts) and what was not checked live to $S/runs/pr$n.report."
    for extra in "$@"; do echo; cat "$extra"; done
    echo; echo "=== Plan item ==="; cat "$S/runs/pr$n.task"
  } > "$P"
  "$SKILL/dashboard/run-job.sh" "pr$n-impl" "$n" implement "$model" "$(effort_for implementer)" "$W" "$S/runs/pr$n-impl.out" "$S/runs/pr$n-impl.log" -- "$P"; rc=$?
  [ $rc = 0 ] && setst "$n" "implemented" || setst "$n" "needs-attention: implement failed ($S/runs/pr$n-impl.log)"
  tail -n 30 "$S/runs/pr$n-impl.out" 2>/dev/null; exit $rc;;

stop)
  n=${1:?plan PR number}; setst "$n" "stopped: ${2:-stopped by the orchestrator}"
  python3 - "$S/dashboard/jobs.json" "$n" <<'EOF'
import json,sys,time
p,n=sys.argv[1],int(sys.argv[2])
try: d=json.load(open(p))
except FileNotFoundError: sys.exit()
for j in d['jobs']:
  if j.get('plan')==n and j.get('status')=='running': j['status']='stopped'; j['finishedAt']=time.strftime('%Y-%m-%dT%H:%M:%S%z')
json.dump(d,open(p,'w'),indent=1)
EOF
  echo "PR $n stopped";;

review)
  n=${1:?plan PR number} r=${2:?round}; W=$(wt "$n"); P=$S/runs/pr$n-rev$r.prompt
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
  # CM_REVIEWER / CM_REVIEWER_EFFORT pick this round's reviewer (review-loop order: DeepSeek, Muse, then Astra).
  "$SKILL/dashboard/run-job.sh" "pr$n-rev$r" "$n" review "${CM_REVIEWER:-$(conf reviewer)}" "${CM_REVIEWER_EFFORT:-$(effort_for reviewer)}" "$W" "$S/runs/pr$n-rev$r.out" "$S/runs/pr$n-rev$r.log" -- "$P"
  out=$S/runs/pr$n-rev$r.out
  if grep -q VERDICT "$out" 2>/dev/null && ! grep -qE '\[(blocker|should)\]' "$out"; then setst "$n" "approved round $r"; else setst "$n" "changes round $r"; fi
  cat "$S/state/pr$n"; tail -n 40 "$out" 2>/dev/null;;

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
  if [ "$mode" = merge ]; then pr=${1:?pr}; ref=${2:?ref}; else ref=${1:?ref}; fi
  # One gate per repo: every plan builds in the same verify worktree.
  exec 9>"$ROOT/gate-$(basename "$R").lock"; flock 9
  git -C "$R" fetch -q origin "$BASE" "$ref" || exit 5
  main=$(git -C "$R" rev-parse "origin/$BASE")
  head=$(git -C "$R" rev-parse "origin/$ref" 2>/dev/null || git -C "$R" rev-parse FETCH_HEAD)
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
  subject="$(gh pr view "$pr" --repo "$GH" --json title -q .title) (#$pr)"
  gh pr merge "$pr" --repo "$GH" --squash --subject "$subject" --match-head-commit "$head" >/dev/null 2>&1 || exit 5
  echo "merged #$pr onto ${main:0:8}";;

ship)
  n=${1:?plan PR number}; W=$(wt "$n") b=$(br "$n")
  [ -s "$S/runs/pr$n.title" ] && [ -s "$S/runs/pr$n.body" ] || die "write $S/runs/pr$n.title and pr$n.body first"
  setst "$n" "shipping: commit + gate"
  if [ -n "$(git -C "$W" status --porcelain -- . ":!$PLAN")" ]; then
    git -C "$W" add -A -- . ":!$PLAN"
    git -C "$W" reset -q -- $(cd "$W" && find . -maxdepth 4 -name node_modules -type l | sed 's|^\./||') 2>/dev/null
    { cat "$S/runs/pr$n.title"; echo; echo "PR $n in $PLAN."; t=$(conf trailer); [ -n "$t" ] && { echo; echo "$t"; }; } > "$S/runs/pr$n.msg"
    git -C "$W" commit -q -F "$S/runs/pr$n.msg" || { setst "$n" "needs-attention: commit failed"; die "commit failed"; }
  fi
  [ "$(git -C "$W" rev-parse HEAD)" != "$(cat "$S/runs/pr$n.base")" ] || { setst "$n" "needs-attention: nothing to ship"; die "nothing to ship"; }
  for i in 1 2 3 4 5; do
    git -C "$W" push -q -f origin "HEAD:refs/heads/$b" 2>&1 | grep -v '^remote:'
    [ "$(git -C "$R" ls-remote origin "refs/heads/$b" | cut -f1)" = "$(git -C "$W" rev-parse HEAD)" ] && break; sleep $((i * 10))
  done
  "$0" gate check "$b"; rc=$?
  [ $rc = 3 ] && { setst "$n" "needs-attention: conflicts with $BASE (merge origin/$BASE in $W, resolve, commit, ship again)"; exit 3; }
  [ $rc = 0 ] || { setst "$n" "needs-attention: gate check failed ($S/runs/gate-${b//\//_}.log)"; exit 1; }
  pr=$(gh pr list --repo "$GH" --head "$b" --state open --json number -q '.[0].number')
  if [ -z "$pr" ]; then
    url=$(cd "$R" && gh pr create --repo "$GH" --head "$b" --base "$BASE" --title "$(cat "$S/runs/pr$n.title")" --body-file "$S/runs/pr$n.body" 2>&1 | tail -1)
    pr=${url##*/}; [[ $pr =~ ^[0-9]+$ ]] || { setst "$n" "needs-attention: pr create failed: $url"; die "$url"; }
  fi
  setst "$n" "opened #$pr: waiting for bot review"
  "$0" bot-review "$pr" "$(git -C "$W" rev-parse HEAD)"; rc=$?
  [ $rc = 6 ] && { setst "$n" "needs-attention: bot findings on #$pr (fix and ship again, or resolve the threads)"; exit 6; }
  [ $rc = 0 ] || { setst "$n" "needs-attention: bot review did not finish on #$pr"; exit 7; }
  setst "$n" "opened #$pr: bot review clean"
  for i in 1 2 3; do "$0" gate merge "$pr" "$b"; rc=$?; [ $rc = 4 ] || [ $rc = 1 ] && [ $i -lt 3 ] && continue; break; done
  if [ $rc = 0 ]; then setst "$n" "merged #$pr"; git -C "$R" worktree remove --force "$W"; git -C "$R" branch -D "$b" >/dev/null 2>&1; echo "merged #$pr"
  else setst "$n" "needs-attention: merge rc=$rc for #$pr"; exit $rc; fi;;

status)
  for f in "$S"/state/pr*; do [ -e "$f" ] && printf '%s: %s\n' "${f##*/pr}" "$(head -1 "$f")"; done | sort -n;;

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
