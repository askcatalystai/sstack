---
name: ui-lead
description: "How visible UI gets designed, built and proved in sstack. Claude Opus leads all UI and UX; GPT models don't decide or write visible UI. Use for any change a user can see: layout, styling, components, copy, interaction, or a UI review. Built on pstack's experience-first, prototype and visual-parity."
---

# UI lead

Claude Opus owns every visible decision. The founder's verdict is that GPT models are sloppy at UI, so they don't design it, write it, or judge it. Keep the bar here: clean, minimal, tasteful.

Read `<pstack>/skills/principle-experience-first/SKILL.md` first. Use `<pstack>/skills/poteto-mode/playbooks/prototype.md` for open design choices, and `visual-parity.md` when the target is an exact match.

## Who does what

| Work | Who |
|---|---|
| Design decisions, visible components, styles, copy | Opus. The orchestrator for small changes, otherwise a `delegate_task` on the `ui lead` role in a worktree. |
| Data, stores, server and wiring with no visible output | Sol, in a separate brief or PR |
| Bug pass and code review | Composer and Astra, for logic only. Ignore their taste findings. |
| Browser proof | Opus |

## Steps

1. **See it first.** Screenshot the current screen in the real app, in light and dark, at the widths it's really used. Never design from code alone.
2. **Read the reference.** Open its source before designing: T3 Code for chat and settings (`~/templates/t3code`), OpenDots for Spaces (`~/templates/opendots`), Medusa admin for tables and commerce (`~/templates/medusa`). Adapt the idea, using our components and tokens. If the reference is out of date, pull it first.
3. **Subtract.** Every control must justify itself. List what can go before adding anything, and ship less, better. Check `git log -S` before removing a choice that looks deliberate.
4. **Pick a direction.** If the layout or interaction is genuinely open, build 2 or 3 throwaway variants in plain HTML behind one switcher, show them with `html_preview` and `html_render`, recommend one, and let the founder choose. Skip this for a clear fix, and don't ask about a fact you can see by rendering it.
5. **Build.** Our components and design tokens only, with the smallest diff that gets it right.
6. **Check against the taste rules** below, and fix what fails.
7. **Prove it** (see Proof), looking at each screenshot yourself.
8. **Say what you'd cut next.** If the answer is something in this PR, cut it now.

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

- Before and after screenshots with their paths: light and dark, default width and narrow.
- Measurements for what you claim about layout, from the DOM: widths, offsets, row heights.
- Each changed state, and hover, focus and keyboard for any new interaction.
- For an exact match, an image diff against a baseline, per the visual-parity playbook. A nonzero diff is a failure to explain.
- On prod after deploy, signed in, in the in-app browser.

Green tests don't prove a UI. Don't write a test just to pin how something looks. `sid-merge.sh` refuses a PR changing app UI files unless `## Proof` has a screenshot, or says "no visible change" with the reason.

## When the founder rejects it

Their taste wins. Don't defend it or patch around it: scrap the approach (`full-send`'s Scrap section), ask what was wrong if it isn't clear, and add any new rule to the Taste rules, so it's enforced next time.
