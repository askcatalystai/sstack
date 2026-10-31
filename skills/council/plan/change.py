"""Hash the same snapshot that ship stages, or find its newest changed path."""
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

worktree, base, plan, mode = sys.argv[1:5]
head = sys.argv[5] if len(sys.argv) > 5 else 'HEAD'
env = os.environ.copy()

def git(*args):
    return subprocess.check_output(['git', '-C', worktree, *args], env=env)

with tempfile.TemporaryDirectory() as temp:
    if mode != 'staged':
        env['GIT_INDEX_FILE'] = temp + '/index'
        git('read-tree', head if mode == 'committed' else 'HEAD')
    if mode not in ('staged', 'committed'):
        git('add', '-A', '--', '.', ':!' + plan)
        # Dependency links are shared with the main checkout, never shipped.
        for root, dirs, files in os.walk(worktree):
            depth = len(Path(root).relative_to(worktree).parts)
            if depth >= 4:
                dirs[:] = []
            for name in dirs + files:
                path = Path(root)/name
                if name == 'node_modules':
                    if path.is_symlink():
                        git('reset', '-q', '--', str(path.relative_to(worktree)))
                    if name in dirs:
                        dirs.remove(name)
            if '.git' in dirs:
                dirs.remove('.git')
    paths = [p for p in git('diff', '--cached', '--name-only', '-z', base, '--', '.', ':!' + plan).split(b'\0') if p]
    if mode == 'newest':
        timestamps = []
        for path in paths:
            full = Path(worktree)/os.fsdecode(path)
            timestamps.append((full if full.exists() or full.is_symlink() else full.parent).lstat().st_mtime_ns)
        print(max(timestamps, default=0))
    else:
        h = hashlib.sha256(git('diff', '--cached', '--no-ext-diff', '--binary', base, '--', '.', ':!' + plan))
        # Include each addition's portable mode and type as well as the diff.
        # Use additions against base so staging does not change the hash format.
        added = git('diff', '--cached', '--diff-filter=A', '--name-only', '-z', base, '--', '.', ':!' + plan)
        for path in sorted(filter(None, added.split(b'\0'))):
            full = os.path.join(os.fsencode(worktree), path)
            if mode == 'committed':
                entry = git('ls-tree', head, '--', os.fsdecode(path)).split()[0]
                m = int(entry, 8)
                if m == 0o120000:
                    m |= 0o777
            else:
                m = os.lstat(full).st_mode
                # Hash Git's portable file mode, not checkout-specific permissions.
                m = (stat.S_IFLNK | 0o777 if stat.S_ISLNK(m) else
                     stat.S_IFREG | (0o755 if m & 0o111 else 0o644))
            kind = b'symlink' if stat.S_ISLNK(m) else b'file'
            h.update(b'\0' + path + b'\0' + str(m).encode() + b'\0' + kind)
        print(h.hexdigest())
