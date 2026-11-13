#!/usr/bin/env bash
# Verdicts are gone: the reviewer's approval goes in the PR's ## Review section, and sid-merge reads it there.
# This stays so a thread still following the old steps is told, and carries on.
echo "sid-verdict is retired: write who approved in the PR's ## Review section, then run sid-merge.sh ${1:-<pr>}"
