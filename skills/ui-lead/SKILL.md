---
name: ui-lead
description: "How visible UI gets built and proved in sstack. Sol writes it to these rules, Terra screenshots it, and Claude Opus judges it before any other review and tests it at the end. Use for any change a user can see: layout, styling, components, copy, interaction, or a UI review. Built on pstack's experience-first, prototype and visual-parity."
---

# UI lead

Claude Opus owns every visible decision and has the final say, but it doesn't write the code, which saves its tokens for judgment. Keep the bar here: clean, minimal, tasteful. The founder has found GPT models sloppy at UI when left to judge it, so Sol works to these rules and nothing ships on its taste alone.

Read `<pstack>/skills/principle-experience-first/SKILL.md` first. Use `<pstack>/skills/poteto-mode/playbooks/prototype.md` for open design choices, and `visual-parity.md` when the target is an exact match.

## Who does what

| Work | Who |
|---|---|
| Direction, brief, final call on anything visible | Opus |
| Writing the UI and its logic | Sol, with these rules in its brief |
| Screenshots, in T3's in-app browser | Terra |
| Judging the UI, before any other review | Opus |
| Bug pass and code review, after Opus approves | Composer and Astra, for logic only. Ignore their taste findings. |
| Final test in the app, local and prod | Opus |

## Steps

1. **Before screenshots, before any code changes.** Run `sid-preview.sh main`, then Terra captures the affected screens on local and on prod and posts them on the card (see Screenshots).
2. **Direction.** Opus looks at the before shots and reads the reference: T3 Code for chat and settings (`~/templates/t3code`), OpenDots for Spaces (`~/templates/opendots`), Medusa admin for tables and commerce (`~/templates/medusa`), pulling it first if it's out of date. Then subtract: every control must justify itself, so list what can go before adding anything. Check `git log -S` before removing a choice that looks deliberate.
3. **If the layout is genuinely open,** Sol builds 2 or 3 throwaway variants in plain HTML behind one switcher, Opus recommends one, and the founder chooses. Skip this for a clear fix, and don't ask about a fact you can see by rendering it.
4. **Sol builds it.** Its brief has the reference file paths, what to remove, the states to handle and this file's Taste rules: tell it to read this file. Our components and design tokens only, with the smallest diff that gets it right.
5. **After screenshots, local.** Run `sid-preview.sh <worktree>`, then Terra captures the same screens and states, and posts them on the card next to the before set.
6. **Opus judges it, before Composer and Astra.** Read the screenshots and the diff against the Taste rules. In the app only if a screenshot can't answer it, such as an interaction. Send it back to Sol with exact changes, once. If it's still wrong, scrap it (`full-send`'s Scrap section).
7. **Composer, then Astra,** for logic. Then the gate, PR and merge.
8. **After deploy,** Terra captures prod and posts it, and Opus does the final test in the app. **Check the card for founder flags at each step:** a comment with `flag:` means stop and deal with it first.

## Screenshots

Terra runs as a `delegate_task` on the `screenshots` role with no worktree. It uses T3's in-app browser (`preview_*` tools, loading them with tool search if needed), because that's where local and prod are already signed in. Never Chromium or Playwright. Each brief lists the card, URLs, and an exact numbered shot list with the selector to wait for and click (a vague brief makes it stop early), and says "finish the whole list and post it". It also says:

- Open your own tab with `reuseExistingTab=false` and `open=false`, wait until the page's content has loaded (`preview_wait_for` or `preview_evaluate`), not just the title, and close the tab at the end.
- Don't click anything that changes data. Don't print customer details. Leave appearance as you found it.
- Capture dark and light at the default width and at narrow width, plus each state asked for, using `preview_snapshot` with `save=true`. Look at each image, and retake anything that's blank, mid-load, or shows the wrong page.
- Post with `~/.local/share/sidstack/scripts/sid-card.py shots <oe#n> "<caption>" <images...>`. The caption says the stage (before, after local, after prod), environment, screen and commit, and starts with "Terra:", because these comments show as "me" on the board.
- Don't judge the design. Reply with what posted and anything missing.
- Any popover that changes data when closed, such as Notifications marking items read: shoot it last, then close the tab without clicking.
- Check the card has the images (`kanzo` `get_task`) before moving on. Nothing posted means rerun it.

Local commerce pages may not load while the local store rejects the account's key. Say so rather than posting an empty screen, and capture prod instead. A 502 in a panel the card isn't about is fine: carry on.

## Taste rules

**Hierarchy.** One primary action per view. Titles, values and secondary text stay clearly different. Quiet by default: controls that aren't in use can wait for hover or focus, as long as keyboard and touch still reach them.

**Layout.** No boxes inside boxes and no card inside a card. Use one spacing scale; edges line up, and you measure them rather than eyeball them. Content fills its space: no blank reserved slots, no tiny panels. Controls line up across pages of the same kind.

**Tables and lists.** One line per row, with one value per column, truncated at the end with the full value on hover. Never stack text in a row or truncate in the middle.

**Forms.** Not a dump of raw inputs: group by meaning, pick the right control, and give sensible defaults. No full-width button where a small one will do.

**Type and colour.** Few sizes and weights, from tokens. Colour carries meaning, not decoration; status always comes with a label too. No gradients, glows or heavy shadows without a reason. Light and dark both have to look right.

**Words.** Short and plain, in the user's language. No system names, no internal terms, and no explanation for something a good layout makes obvious.

**States.** Design empty, loading, error, very long text, many items and narrow width. No layout jumps when content loads. Nothing is hidden behind a control that does nothing.

**AI slop tells to reject:** icon-in-a-circle feature grids, a badge on everything, centred everything, card-wrapped everything, decorative gradients, wordy subtitles under each heading, and three equal buttons where one should lead.

## Proof

In the PR's `## Proof`, naming the head commit:

- Before and after screenshots with their paths, as posted on the card: light and dark, default width and narrow.
- Measurements for what you claim about layout, from the DOM: widths, offsets, row heights.
- Each changed state, and hover, focus and keyboard for any new interaction.
- For an exact match, an image diff against a baseline, per the visual-parity playbook. A nonzero diff is a failure to explain.
- On prod after deploy, signed in, in the in-app browser.

Green tests don't prove a UI. Don't write a test just to pin how something looks. `sid-merge.sh` refuses a PR changing app UI files unless `## Proof` has a screenshot, or says "no visible change" with the reason.

## When the founder rejects it

Their taste wins. Don't defend it or patch around it: scrap the approach (`full-send`'s Scrap section), ask what was wrong if it isn't clear, and add any new rule to the Taste rules, so it's enforced next time.
