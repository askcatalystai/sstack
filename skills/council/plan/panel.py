#!/usr/bin/env python3
"""Print the review panel from a plan config: provider, model, effort, job slug (index-model)."""
import json
import re
import sys

for i, m in enumerate(json.load(open(sys.argv[1]))['reviewPanel']):
    slug = re.sub('[^a-z0-9]+', '-', m['model'].lower()).strip('-')
    print(m['provider'], m['model'], m['effort'], f'{i}-{slug}', sep='\t')
