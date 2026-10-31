# {{Title}} ({{YYYY-MM-DD}})

<!--
Template for a council-driven plan file, from research to merged and verified on prod.
Copy to app/<NAME>.md, replace every {{placeholder}}, and delete these comments.
The `council-to-merge` skill fills this in and works through it; it reads PR items by the
`### [ ] PR <n> — <title>` heading, so keep that shape exactly.
-->

{{One paragraph: what was asked, by whom, and what "done" means for the whole file.}}

Every finding from {{N}} review rounds, split into small PRs:

- Round 1 ({{date}}, council): {{what it covered, e.g. UX and performance of the chat}}.
- Round 2 ({{date}}): {{e.g. compared X with the reference at `~/templates/<ref>` (version or commit)}}.
- {{Later rounds: who reviewed (council, or one reviewer plus read-only survey agents), what they compared, and the commit their line numbers are from.}}

Council: {{Claude Opus 5.5 (medium)}}, {{GPT-6.1-Sol (high)}}, {{DeepSeek V4.1 Flash (high)}} and {{Muse Spark 1.3 (medium)}}. {{Use the members the user's instructions name, at their efforts. Say when a named member was unavailable.}}

| Delegate | R1 {{product}} ({{axes, e.g. UX / Perf}}) | R2 {{product}} ({{axes}}) |
| --- | --- | --- |
| {{Claude Opus 5.5}} | {{6.5 / 5}} | {{5 / 6 / 5 / 7}} |
| {{GPT-6.1-Sol}} | {{6.5 / 6}} | {{no score}} |
| {{DeepSeek V4.1 Flash}} | {{6.5 / 6}} | {{6 / 6.5 / 6 / 8}} |
| {{Muse Spark 1.3}} | {{7 / 6}} | {{6 / 7 / 6 / 7}} |

{{One line on how the reference products scored, if they were scored.}}

## How to read this file

- Paths are relative to `{{app/apps/app/src/}}`. Paths starting `{{Ref}}:` are relative to `{{~/templates/<ref>/...}}`.
- Effort: **S** takes hours; **M** takes about a day; **L** takes several days.
- Each PR is one concern, safe to ship alone, with an acceptance check. Within a phase the PRs are independent unless "Depends on" says otherwise.
- Line numbers are from `{{commit}}`. Check them again before editing.
- Tick a box only when the PR is merged: `[x]` merged, `[~]` partly done (say what is left), `[ ]` open.

## How this file gets done

- **Roles.** {{Use the roles the user named; this is the default.}}
  - {{Claude}} orchestrates: it briefs each PR, does the final review of the diff, runs the gate, merges, and checks the change on prod.
  - {{GPT-6.1-Sol (high)}} writes the code through `cm implement`, in the PR's own worktree.
  - {{The Codex GitHub bot (`chatgpt-codex-connector`)}} reviews every PR on GitHub. `cm ship` waits for its review of the head commit and merges only with no unresolved bot thread. P0 and P1 findings, and real P2 bugs, get fixed and pushed; the bot reviews the new commit itself. Threads judged not worth fixing are resolved with the reason in the PR body.
  - {{Optional manual reviewer, e.g. GPT-6-Astra (low), through `cm review`, at most 2 rounds. Only when the user asks for one, or no review bot is set up.}}
- **Gate.** Every PR runs the deploy gate before it opens and again before merge: main plus the branch, `pnpm install --frozen-lockfile`, `pnpm typecheck`, server build, web build.
- **Merge.** Only after the gate passes and the bot review is clean. Squash-merge, delete the worktree and branch, and check the deploy on prod once it is live.
- **Ticks.** Tick items in a small docs PR, per phase or per batch, with `- Done (#<github>).` under each item.
- **Deliberate UX.** Before a PR undoes a choice made on purpose, check its history (`git log -S`) and ask the user. List those choices under "Kept on purpose" below.
- **Questions.** Ask the user only for real decisions: two to four options, with the recommended one first. Record the answer under "Decisions".

---

## Phase 1 — {{Area}} ({{the round that found it}})

{{Optional: one paragraph of context for the phase: where the findings came from, what to keep, the shared root cause.}}

### [ ] PR 1 — {{Short outcome, in the user's words}} ({{S|M|L}}) {{**Bug**}} {{*(who found it: Opus, Sol, DeepSeek, Muse, all 4)*}}
- Root cause: {{what is wrong and why, with `file.ts:line`}}.
- Files: {{`path/a.ts:12`, `path/b.tsx:40-60`}}.
- {{Ref}}: {{how the reference does it, `RefFile.tsx:120-140`}}.
- Fix: {{the smallest change that meets the acceptance check}}.
- Depends on: {{PR n, or leave this line out}}.
- Acceptance: {{one observable check, e.g. a regression test that fails before the fix, plus a live check on prod}}.

### [ ] PR 2 — {{...}} ({{S}})
- {{...}}
- Acceptance: {{...}}

---

## Phase 2 — {{Area}}

### [ ] PR 3 — {{...}} ({{M}})
- {{...}}
- Acceptance: {{...}}

<!--
When a PR merges, mark it [x] in a docs PR and add, directly under its heading:
- Done (#<github>). {{Anything left out on purpose, and why.}}
If its GitHub PR shipped something else, leave the box open and add:
- Not done. Its PR (#<github>) shipped <what> instead. Redo it.
Items found during the work (a user request, a prod bug) get the next free number,
under the phase they belong to, with their origin: (user request, {{date}}).
-->

---

## Kept on purpose

- {{Choice}}: {{why it stays, with the commit, e.g. one expanded tool detail at a time (717c2992)}}.

## Decisions

- {{YYYY-MM-DD}}: {{Question}} → {{answer}}. {{What it changed, or "unchanged on purpose".}}

## Live checks

- {{YYYY-MM-DD}}, {{prod URL or build}}: {{what was checked, how (browser, DOM query, screenshot) and the result. Say what was not checked live.}}

## Not verified

- {{Anything that only tests covered, e.g. "macOS window chrome needs a real Electron build".}}
