---
name: nightly-rules
description: Read what the operator typed today, find what they had to repeat, and add it to sidstack's rules.md so no model needs telling again. Runs nightly as a T3 scheduled task; also use for "update the rules", "what did I repeat".
---

# Nightly rules

The operator shouldn't have to say anything twice. `~/.local/share/sidstack/rules.md` is the one file every model reads, so a repeated instruction belongs there. This skill keeps it current without the operator.

## Steps

1. Read `~/.local/share/sidstack/rules.md`, then the comments on the Kanzo card "Rules changelog" in the `process` project (`kanzo` `get_task`). For each `revert: <reason>` comment from the operator with no reply after it, remove or restore that rule first, and reply on the card saying what you did.
2. Run `python3 ~/.local/share/sidstack/scripts/sid-reflect.py --week` for the last seven days, and `python3 ~/.local/share/sidstack/scripts/sid-reflect.py` for today.
3. Find today's messages that are an instruction about how to work, not what to build, and that the operator also gave earlier in the week, or gave today as a correction ("again", "I asked earlier", "we fixed this", "why is it still"). Count the times and note the dates.
4. For each, decide where it goes:
   - **Already a rule.** If the rule exists and the operator still had to say it, the rule isn't working. Make it sharper or more concrete, update its date and quote, and say in the digest which thread ignored it.
   - **A new rule for every project.** Add it under the fitting heading in `rules.md`: one bold sentence saying what to do, one saying why or how, then the date and a short quote in the operator's words.
   - **The current arrangement** (who codes, who reviews, skip a gate or the bot). Not a rule. Check `scripts/sid-mode.sh` shows it for that repo, and set it there with `--note` if it doesn't.
   - **A product decision for one repo.** Not a rule here. It goes in that repo's instructions or memory. List it in the digest for the thread that owns the repo.
   - **A one-off.** Skip it.
5. Add at most three rules a night, and keep the file short enough to read in two minutes. If it has grown past that, merge rules that say the same thing. Never remove a rule the operator hasn't withdrawn.
6. If `rules.md` changed: run `bash scripts/check.sh`, commit it alone on main in `~/.local/share/sidstack` with a message that lists each rule and its quote, and push. A change to `rules.md` alone may be pushed to main; anything else goes by PR. It's live at once, because every harness links to that file.
7. Post the digest as a comment on the Kanzo card "Rules changelog" in the `process` project (create it in Done if it's missing): each rule added or sharpened with its quote, each arrangement change, and each product decision passed on. If nothing changed, post nothing.

## What makes a good rule

- It says what to do, in words a model new to the project can act on, and names the tool or file when there is one.
- It's in the operator's terms. Quote them; don't paraphrase into something broader than they said.
- It's about working, not about one feature. "Never build a bespoke dialog where one exists" is a rule. "The agents page uses cards" is a product decision.

The operator can undo any rule by commenting `revert: <reason>` on the changelog card, or by saying so in any thread.
