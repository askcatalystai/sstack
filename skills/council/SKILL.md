---
name: council
description: Trigger this if the user says 'council'. Also use it when the user wants a council-researched plan file worked through to merged PRs ("council plan", "council to completion", "start a council task"); see "Plan to completion".
---

# Council

Bring in delegates to help with the user's request, usually for review or
feedback. The seats are the `council` line in
`~/.local/share/sidstack/models.md`, one delegate per seat at the effort it
names. If the user names other members for a run, use those. Plan PRs use the
`implementer` and `reviewer` roles from the same file, and wait for the
`pr bot` before merging.

Models served through a gateway harness such as OpenCode (for example
DeepSeek or Muse Spark) count by the company that made the model, not by the
harness, so two OpenCode models from different vendors are two providers.

In T3 Code, use `orchestrator_capabilities` to resolve the models, then
`delegate_task` to start one delegate per model in parallel. Elsewhere, use
the harness's subagent tools. If a seat is unavailable, report it instead of substituting.

Give each delegate the request and relevant context. For review or feedback,
keep their work read-only. Collect their responses and summarize the useful
findings, disagreements, and recommended next steps.

For a code review, ask each delegate for a score out of 10.
Count each full review pass as one round.
A fresh review after fixes starts a new round.

If the work ends in a pull request, put the results in the PR description.
Put this section before the model and harness line at the end:

```markdown
## Council review

Rounds: 2

| Delegate | Round 1 | Round 2 |
| --- | --- | --- |
| Claude Opus | 7/10 | 9/10 |
| GPT Sol | 8/10 | 10/10 |
| Gemini Pro | 7/10 | 9/10 |
```

If a delegate gives no score, write `no score`. Do not invent one.
If the PR is open, edit the description. Do not post a comment for this.
If there is no PR, put the same results in the final reply only.

If you agree with their recommendations, make the changes and request a fresh
review after. Continue this process until all delegates are satisfied with the
outcome.

Do not let repeated reviews result in scope creep. It is your job to fight to
keep scope limited.

## Plan to completion

Use this when the user wants a council task carried from research to merged
PRs: "council plan", "council to completion", or a council request followed by
"and fix everything". Everything lives in `plan/` next to this file:

- `plan/todo-template.md`: the plan file's shape. Copy it, fill it, and keep
  the `## Phase <n> — <title>` and `### [ ] PR <n> — <title> (S|M|L)` headings
  exact: the board and the scripts read them.
- `plan/cm.sh`: one script for the loop (worktree, review, gate, ship). Run
  it with no arguments to see its commands.
- `plan/dashboard/`: the progress board (kanban, live jobs, phases, activity
  feed) on `http://127.0.0.1:<port>`. It reads the plan file, this session's
  transcript, and `cm.sh`'s state. Always use it; never build a new one.

### 1. Research and council

1. Restate the goal and the one observable "done" check for the whole task.
2. Research before asking: read the code paths involved, and the reference
   product if there is one (for example `~/templates/<ref>`). Note file:line
   for every finding.
3. Run the council above, read-only, with the research attached. Ask each
   delegate for findings with file:line, effort (S/M/L), an acceptance
   check, and scores per axis. One reviewer with read-only survey agents
   counts as a round too; say so in the file.

### 2. The plan file

1. Copy `plan/todo-template.md` to the repo (for example
   `app/<TOPIC>-FIXES.md`). Fill the header (rounds, council members, the
   scores table), "How to read", and "How this file gets done".
2. Group findings into phases by area. One PR item per concern: root cause,
   files, reference, fix, depends-on, acceptance. Number PRs once, never
   renumber; later finds take the next free number.
3. Ask the user only for real decisions, with the question tool: 2-4
   options, recommendation first. Record answers under "Decisions" and
   choices that stay on purpose under "Kept on purpose".
4. Land the plan file as its own docs PR through the gate (step 4), then:

```bash
cm=<this skill>/plan/cm.sh
$cm init <repo>/<plan>.md --gh <owner/repo> --title "<short title>" \
  --gate-dir <dir> --gate '<exact install, typecheck and build commands the deploy runs>' \
  --trailer '<the commit attribution line, if any>' --port 8787 \
  [--bot-review chatgpt-codex-connector]
$cm dashboard --transcript <this session's .jsonl>   # open the URL for the user
```

Model defaults (implementer, hardest tasks, review panel and gate reviewer) come
from `~/.local/share/sidstack/models.md`; set `SIDSTACK_MODELS` to use another
file at init. Provider, model and effort are saved in `config.json`.
`--reviewer`, `--implementer`, `--effort`, `--implementer-effort` and
`--reviewer-effort` override defaults. Model overrides keep the role's provider.
`--implementer claude` means the orchestrator writes the code itself.

`--bot-review <login>` names the GitHub review bot; it does not replace local
review. `--bot-timeout` sets the wait in seconds (default 900).

`init` prints the plan's slug. Other sessions may run their own plans, so put
`COUNCIL_PLAN=<slug>` in front of every later `cm` call (and give each plan its
own `--port`). Without it, `cm` uses whichever plan was initialised last.

### 3. Each PR item

Work phase by phase. Inside a phase, PRs that touch disjoint files can run in
parallel, each in its own worktree. Never switch the main checkout's branch.

1. `cm new <n>`: a worktree and branch from the default branch, with the
   item in `runs/pr<n>.task`. Read the item, check its line numbers, and check
   history before undoing a deliberate choice (`git log -S`).
2. Implement the smallest change that meets the acceptance check. With a
   Codex implementer, run `cm implement <n> [brief.md]` instead and review its
   diff and report before step 4. Use `cm implement <n> --hardest [brief.md]`
   for the `hardest tasks` model and effort from models.md. Add a
   regression test that fails without the fix. Run the affected tests and
   the typecheck. Compare any failure against the default branch before
   calling it pre-existing, and name stale builds or isolation failures as
   such.
3. Write `runs/pr<n>.report`: what was wrong, what changed (files), the proof
   (tests and counts, what failed before), and what was not checked live.
   To pause or drop a PR, run `cm stop <n> [reason]` so the board stops
   showing it as active. It kills running process groups and clears approval.
   `cm stop-job <id>` stops one job and clears its PR approval.
4. Review with models from models.md:
   - `cm review <n> 1 panel`: every review-panel member in parallel.
   - `cm review <n> 2 panel`: the panel again on the same code, cross-checking
     the round-1 findings. No fixes between rounds.
   - `cm review <n> 3 gate`: Astra, one pass.
   - Then `cm implement <n> <findings.md>` once with every accepted finding,
     and the orchestrator verifies each fix (until the runner records an
     orchestrator approval for the fixed change, rerun the gate round on it).
   A light review, only when the user asks, uses one panel round and the gate.
   Only a successful gate with an exact `VERDICT: APPROVE` line and no blocker
   or should finding grants approval. Panel approval cannot grant it.
5. Write `runs/pr<n>.title` (a conventional commit title in plain words) and
   `runs/pr<n>.body`: the plan reference, what was wrong, the bullets of what
   changed, the tests, "Reviewed by <reviewer> (approved in round N)", what
   is not checked live, and the harness attribution line.
6. Run the real thing: tests covering the change (commands and pass counts),
   and for UI the app in a browser with a screenshot path. Green mocked tests
   alone are not proof. Write what ran, how and the result to `runs/pr<n>.proof`,
   then `cm verify <n>`. This binds the proof to the current change.
7. `cm ship <n>`. It commits (never the plan file), pushes, runs the gate on
   the default branch plus the branch, opens the PR, runs the gate again,
   squash-merges, and removes the worktree. With `botReview` set, it waits
   between opening and merging until the bot has finished reviewing the
   head commit (`cm bot-review <pr>`), and merges only if no bot thread is
   unresolved.
   - Exit 8 means no gate approval for the current change; exit 10 means no
     verification for it. Review and verify again after edits. Exit 9 means the
     remote head moved after shipping; do not merge it on the old approval.
   - Exit 6 means bot findings; they're printed with severity and thread id.
     Fix P0 and P1 findings, and real P2 bugs, in the worktree, rerun the gate review
     and verification, and run `cm ship <n>` again; the bot re-reviews new commits by itself.
     Resolve each thread once it's fixed, or once you judge it not worth
     fixing (say why in the PR body):
     `gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:"<id>"}){thread{isResolved}}}'`.
   - Exit 7 means the bot review failed or timed out. Check the PR; don't
     merge around it without telling the user.
   - Exit 3 means conflicts: merge `origin/<default>` in the worktree, resolve,
     rerun the gate review and verification, and run `cm ship <n>` again.
   - A gate log ending in `Killed` means memory pressure from parallel
     builds. Rerun it; it's not a code failure.
8. Let the next item proceed while gates run in the background. Wait on
   them with background commands, never sleep loops in the foreground.

### 4. After each phase or batch

1. Tick the items in one docs PR through the gate: `[x]`, then `- Done
   (#<github>).` under each. Check that each merged PR shipped what its item
   asked for. If it did not, leave the box open and say what shipped instead.
2. Once the deploy is live, check the change on prod (browser, DOM queries,
   screenshots), and record it under "Live checks". List anything only tests
   covered under "Not verified".
3. Delete merged worktrees and local branches; keep worktrees that hold
   unmerged work or untracked files, and say which.

### 5. Finish

Run until every item is ticked or blocked on the user. Mid-task requests
from the user become new numbered items in the same file (for example "user
request, <date>") and go through the same loop. Final report: the PRs with
links, what was checked live, what wasn't, and the decisions taken.
