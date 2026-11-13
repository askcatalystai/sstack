# Operator rules

Standing orders from Sid, the operator. They apply to every model in every role: orchestrator, builder, reviewer, screenshots, council seat. `install.sh` links this file into each harness, and every subagent brief names it. A rule here beats a skill; a newer instruction from the operator in the session beats this file.

Each rule is something the operator has had to say more than once. The date is when it was last said, and the quote is theirs. A nightly reflect proposes additions from the day's messages; remove a rule only when the operator says so.

Where things are: models for every role in `~/.local/share/sidstack/models.md`; the current arrangement from `~/.local/share/sidstack/scripts/sid-mode.sh`; where every card stands from `~/.local/share/sidstack/scripts/sid-board.py status`.

## Working with the operator

- **Never make the operator the bottleneck.** Reversible work proceeds without asking. If you're blocked on one thing, say so on the card and carry on with everything else. (2026-11-13: "dont make me human the bottle neck")
- **Ask with options.** When a decision really is the operator's, ask with the question tool: each option spelled out, your recommendation first. One decision per question. Never a question buried in a chat message. (2026-11-13: "ask me questions with options")
- **Don't pick a design alone.** Show design choices one by one and get a go or a change for each before building. (2026-11-07: "dont decide on design ask me about each")
- **Status lives on the board.** The Kanzo card shows where the work is, so the operator never has to ask "is it done?". Name the card key in every subagent title and PR body; `sid-board.py` moves the card from that. Say what you're waiting on as a card comment before you end a turn.
- **Never end a turn waiting on something that can't wake you.** If nothing will resume the thread, keep going or say exactly what's needed. (19 "continue" messages in one week.)
- **Show it here.** When asked to visualize, or when the answer is a comparison, a plan or an architecture, render it in the thread. (2026-11-13: "visualize it for me here")

## Who does what

- **Opus builds visible UI. Sol builds logic.** Anything a user can see is written by a Claude Opus builder; Sol writes server, runtime, data and tests. (2026-11-13: "yes opus for ui"; 2026-11-07: "sol is very bad at ui")
- **Terra takes screenshots and makes concept images,** in T3's in-app browser, posted on the card. (2026-11-12: "use terra")
- **The current arrangement is in `sid-mode.sh`,** not in memory notes: who codes, who reviews, which lane. When the operator changes it ("do it yourself", "skip Composer"), set it there with a note, and read it at the start of each task.
- **"Do it yourself" means the orchestrator writes it,** logic and UI, with no builder subagent, until the operator says otherwise: `sid-mode.sh set coder claude`. If they said no subagents at all, also `set reviewers none` and take screenshots yourself.

## Building

- **Never bespoke.** Extend the existing shell, components, tokens and patterns. Before building a control, find the one the app already has and use it. A new dialog, composer, sheet or list where one exists is a defect. (2026-11-11: "not a new bespoke option")
- **Match the reference.** Chat, threads and subagent views follow T3 Code (`~/templates/t3code`); Spaces follow OpenDots; tables and commerce follow Medusa admin. Open the reference and copy its structure before designing. (2026-11-13: "see how t3code is doing it")
- **No extra words in the UI.** No static labels, helper text under inputs, subtitles, or explanations a placeholder or layout already gives. (2026-11-07: "we dont need these secondary explanations")
- **Don't hardcode what the system can supply.** Timezones, effort levels, permission modes, names and limits come from the user, the provider or settings. (2026-11-12: "test is channel name not hardcoded")
- **Read the docs first.** Before proposing how to use Mastra, Composio, Razorpay or any library, read its installed docs and say what they recommend, with the citation. (2026-11-12: "see what mastra docs suggest")
- **A bug that comes back gets a test.** When the operator reports something that was fixed before, find why the earlier fix didn't hold, and add a test that fails without the fix. (2026-11-10: "we fixed it multiple times earlier")

## Shipping

- **Nothing lands unchecked, and nothing waits in line.** Every PR goes through `sid-merge.sh`, which queues it for the merge train. "Skip gates" means the fast lane (`sid-mode.sh set lane fast`), never a plain `gh pr merge` or a push to main. The one exception is sstack's own `rules.md` and `models.md`, which may be pushed to its main alone. (2026-11-13: "fast lane yes")
- **No Codex bot. Risky PRs get one more model, and only a unanimous "risky" blocks.** Don't comment `@codex review` or wait on the bot. For auth, payments, data, migrations, `commerce/`, merge scripts, or a PR that skipped a review step, add one review from a family that hasn't reviewed it (OpenCode DeepSeek or Muse, or Cursor Composer or Grok). A finding blocks the merge only when every model that reviewed the PR says it's risky; otherwise the orchestrator decides, and `## Review` says why. (2026-11-13: "skip the bot review we are reviewing locally anyways ... it can be a hard blocker only if all two or three models say its risky")
- **The app must run.** A change isn't done until the app builds and starts locally with it. (2026-11-13: "we can run the app in local without fail to see if everything is built")
- **Check prod yourself** after the deploy, signed in, in T3's browser. Don't ask the operator to test what you can test.

## Product: OpenEcommerce

- The product is **OpenEcommerce**. The EcommerceX name is dropped. In the app the word is "agent"; "coworker" is for the marketing site only. (2026-11-13)
- Agents, teams, settings, apps and memory belong to the account. Only chats are private to a person. (2026-11-11)
- Never show infrastructure names (Composio, Medusa, Mastra) or raw ids to users; show the app or thing the user knows. (2026-11-13)
