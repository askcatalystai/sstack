---
name: council
description: Trigger this if the user says 'council'. Also use it when the user wants a council-researched plan file worked through to merged PRs ("council plan", "council to completion", "start a council task"); see "Plan to completion".
---

# Council

Before an audit, address outstanding PR comments, fix known issues, and run
relevant checks. Give council the updated implementation; do not defer known
fixes until reviews return. If the user wants to discard the implementation
and explore new ideas, skip fixes to code being replaced.

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
"and fix everything".

### 1. Research and council

1. Restate the goal and the one observable "done" check for the whole task.
2. Research before asking: read the code paths involved, and the reference
   product if there is one (for example `~/templates/<ref>`). Note file:line
   for every finding.
3. Run the council above, read-only, with the research attached. Ask each
   delegate for findings with file:line, effort (S/M/L), an acceptance
   check, and scores per axis.

### 2. The plan file

1. Write one plan doc in the repo (for example `app/<TOPIC>-FIXES.md`), or add
   phases to the current one. Start with the goal, council members and scores.
   Use `## Phase <n> — <title>` and `### [ ] PR <n> — <title> (S|M|L)` headings.
2. Group findings into phases by area. One PR item per concern: root cause,
   files, reference, fix, depends-on, and the behaviour to prove. Don't write
   "a test finds X" as the acceptance: name the behaviour, and let the test rule
   in `full-send` decide whether a test or the running app proves it. Number PRs once, never
   renumber; later finds take the next free number.
3. Ask the user only for real decisions, with the question tool: 2-4
   options, recommendation first. Record answers under "Decisions" and
   choices that stay on purpose under "Kept on purpose".
4. Land the plan file as its own docs PR.

### 3. Each PR item

Work each item the `full-send` way: a `delegate_task` worktree for Sol, the
bug pass, Astra, Claude's final call, Sol's one fix, proof, `sid-gate.sh`, PR,
watch, `sid-merge.sh`, then a live check. Inside a phase, PRs that touch disjoint
files run in parallel, each in its own worktree. Each brief names the item in
full: read it, check its line numbers, and check history before undoing a
deliberate choice (`git log -S`). Never switch the main checkout's branch.

### 4. After each phase or batch

1. Tick the items in one docs PR: `[x]`, then `- Done (#<github>).` under each.
   Check that each merged PR shipped what its item asked for. If it did not,
   leave the box open and say what shipped instead.
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
