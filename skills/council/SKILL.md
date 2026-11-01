---
name: council
description: Trigger this if the user says 'council'. Also use it when the user wants a council-researched plan worked through to merged PRs ("council plan", "council to completion", "start a council task"); see "Plan to completion".
---

# Council

Before an audit, address outstanding PR comments, fix known issues, and run
relevant checks. Give council the updated implementation; do not defer known
fixes until reviews return. If the user wants to discard the implementation
and explore new ideas, skip fixes to code being replaced.

Bring in delegates to help with the user's request, usually for review or
feedback. The seats are in `~/.local/share/sidstack/models.md`: the `council` line for
big plans, the `council small` line for smaller ones, one delegate per seat at the
effort it names. If the user names other members for a run, use those. Plan PRs use the
`implementer` and `reviewer` roles from the same file. The council plans once, at
the start. It doesn't review each PR.

Models served through a gateway harness such as OpenCode (for example
DeepSeek or Muse Spark) count by the company that made the model, not by the
harness, so two OpenCode models from different vendors are two providers.

In T3 Code, use `orchestrator_capabilities` to resolve the models, then
`delegate_task` to start one delegate per model in parallel. Elsewhere, use
the harness's subagent tools. If a seat is unavailable, report it instead of substituting.

If the project is on the user's Kanzo board, make a card before starting the seats and
comment each seat's reply on it as it returns, so results show as they arrive.

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

If you agree with their recommendations, make the changes. Ask for a fresh round only if
a decision is still contested. A plan gets one round unless the user asks for more.

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

### 2. The plan goes on the board

Kanzo is the source of truth, not a file. Where the project has no board, ask.

1. Make one card per PR item, holding its full detail: root cause, files, reference, fix,
   depends-on, and the behaviour to prove. Don't write "a test finds X": name the behaviour,
   and let the test rule in `full-send` decide whether a test or the running app proves it.
   One card per concern; split anything that isn't small. Each area of work, such as Sidebar
   or Settings, is its own Kanzo project. The title is plain words with no number; a `pr-<n>`
   tag gives the number shown as `#<n>` on the card.
2. Todo holds what's next; Backlog holds what waits. Put the council's scores and any decisions
   on a council card.
3. Ask the user only for real decisions, with the question tool: 2-4 options, recommendation
   first. Record the answers on the cards they affect. A choice that stays on purpose goes on
   its card, and in the project's instructions if it should outlast the work.
4. The user may edit, reorder or delete cards. Read the board before picking the next item.

### 3. Each PR item

Work each item the `full-send` way: a `delegate_task` worktree for Sol, the
bug pass, Astra, Claude's final call, Sol's one fix, proof, `sid-gate.sh`, PR,
watch, `sid-merge.sh`, then a live check. Inside a phase, PRs that touch disjoint
files run in parallel, each in its own worktree. Each brief carries the card in
full: read it, check its line numbers, and check history before undoing a
deliberate choice (`git log -S`). Never switch the main checkout's branch.

### 4. After each batch

1. Check that each merged PR shipped what its card asked for. If it did not, say what shipped
   on the card and leave it open.
2. Once the deploy is live, check the change on prod (browser, DOM queries, screenshots), and
   comment what was checked and what only tests covered.
3. Delete merged worktrees and local branches; keep worktrees that hold unmerged work or
   untracked files, and say which.

### 5. Finish

Run until every card is done or blocked on the user. Mid-task requests
from the user become new cards and go through the same loop. Final report: the PRs with
links, what was checked live, what wasn't, and the decisions taken.
