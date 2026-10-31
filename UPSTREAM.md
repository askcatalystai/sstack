# Upstream

Copied from [tstack](https://github.com/t3dotgg/tstack), upstream base `7de017b`
(main). The local checkout also had three unpublished commits on top
(`bc811cd`, `9cd1960`, `10b2bf0`); their changes are already in sidstack.

- full-send
- full-stop
- council (including plan files)
- file-pr
- babysit-pr
- takeover
- modernize
- leaving-pr-comments
- sol-loop (renamed review-loop here)

[pstack](https://github.com/cursor/plugins) at commit `4dd1d05` is used in
place through the adapter, not copied.

Run `scripts/upstream-check.sh` for a report of changes since these commits.
It fetches temporary clones, prints diff stats, and always exits 0.
