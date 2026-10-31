#!/usr/bin/env python3
"""Write pstack's per-role model rule from sidstack's models.md (one source of truth)."""
import json
import subprocess
import sys
from pathlib import Path

ROLES = [
    ('feature, refactoring', 'implementer'), ('bug-fix', 'implementer'),
    ('perf-issue', 'implementer'), ('hillclimb', 'implementer'),
    ('judgment and prose', 'judgment and prose'), ('hardest tasks', 'hardest tasks'),
    ('how explorer', 'explorers (how explorer, why investigators, reflect tooling)'),
    ('why investigators', 'explorers (how explorer, why investigators, reflect tooling)'),
    ('reflect tooling', 'explorers (how explorer, why investigators, reflect tooling)'),
    ('how explainer', 'explainers (how explainer, why synthesizer, reflect judgment)'),
    ('why synthesizer', 'explainers (how explainer, why synthesizer, reflect judgment)'),
    ('reflect judgment, divergent, synthesizer', 'explainers (how explainer, why synthesizer, reflect judgment)'),
    ('arena runners', 'arena runners'), ('arena cross-judge pool', 'arena runners'),
    ('architect runners', 'architect runners'), ('interrogate reviewers', 'interrogate reviewers'),
    ('swarm workers', 'swarm workers'),
]


def main(models_md, out):
    roles = json.loads(subprocess.check_output([sys.executable, str(Path(__file__).with_name('models.py')), models_md]))
    lines = ['# Generated from ~/.local/share/sidstack/models.md by install.sh. Do not edit; change models.md.',
             '# Each value: provider/model effort. Run through ~/.local/share/sidstack/docs/adapter.md.']
    for pstack_role, role in ROLES:
        entries = roles.get(role)
        if not entries:
            sys.exit(f'models.md has no role {role!r} for pstack role {pstack_role!r}')
        lines.append(f"{pstack_role}: " + ', '.join(f"{e['provider']}/{e['model']} {e['effort']}" for e in entries))
    Path(out).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    main(*sys.argv[1:3])
