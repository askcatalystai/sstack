#!/usr/bin/env bash
# sid-verdict <pr> <tested-commit> <PASS|PASS+NOTES|FAIL> <verifier> <t3-thread-id> "<what it ran and saw>"
# The orchestrator records a verifier's verdict from its delegate's result. The verifier must not have written the code.
# <tested-commit> is the commit the verifier reports it ran. Its patch or its tree must match the PR's: a stacked PR
# rebased onto its squashed parent keeps the tree and changes the patch.
# A verdict covers the patch, so it survives a rebase or merging the default branch, and not a code change.
set -u
pr=${1:?usage: sid-verdict <pr> <tested-commit> <PASS|PASS+NOTES|FAIL> <verifier> <t3-thread-id> "<what it ran and saw>"}
tested=${2:?tested commit}; result=${3:?result}; verifier=${4:?verifier}; thread=${5:?t3 thread id}; summary=${6:?what it ran and saw}
case "$result" in PASS|PASS+NOTES|FAIL) ;; *) echo "result must be PASS, PASS+NOTES or FAIL"; exit 1;; esac
common=$(git rev-parse --path-format=absolute --git-common-dir) || exit 1; cd "$(dirname "$common")" || exit 1
gh=$(gh repo view --json nameWithOwner -q .nameWithOwner) || exit 1
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
gh pr view "$pr" --repo "$gh" --json headRefOid,headRefName,baseRefName > "$tmp" || { echo "could not read #$pr"; exit 1; }
read -r head branch base < <(python3 -c 'import json,sys;p=json.load(open(sys.argv[1]));print(p["headRefOid"],p["headRefName"],p["baseRefName"])' "$tmp")
git fetch -q origin "$base" "$branch" || exit 1
patch_of() { git diff "$(git merge-base "origin/$base" "$1")" "$1" | git patch-id --verbatim | cut -d' ' -f1; }
git rev-parse -q --verify "$tested^{commit}" >/dev/null || { echo "no commit $tested here"; exit 1; }
patch=$(patch_of "$head")
[ -n "$patch" ] || { echo "#$pr has an empty patch"; exit 1; }
[ "$(patch_of "$tested")" = "$patch" ] || [ "$(git rev-parse "$tested^{tree}")" = "$(git rev-parse "$head^{tree}")" ] || { echo "the verifier tested ${tested:0:8}, which isn't the code in #$pr at ${head:0:8}: verify again"; exit 1; }
clean() { printf '%s' "$1" | tr '\t\n' '  '; }
verifier=$(clean "$verifier"); thread=$(clean "$thread"); summary=$(clean "$summary")
# Record first: the merge reads the record, so a posted comment with no record would be a false trail.
mkdir -p "$common/sid-gate/verdicts" && printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$result" "$patch" "$head" "$verifier" "$thread" "$summary" >> "$common/sid-gate/verdicts/$pr.tsv" || { echo "could not record the verdict"; exit 1; }
gh pr comment "$pr" --repo "$gh" --body "Verdict: $result by $verifier on ${head:0:8} (patch ${patch:0:8}, T3 thread $thread). $summary" >/dev/null || { echo "recorded, but could not post the verdict on the PR"; exit 1; }
echo "verdict $result recorded for #$pr, patch ${patch:0:8}"
