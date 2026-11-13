#!/usr/bin/env bash
# Protect Compose and named volumes; expire disposable Docker resources.
set -eu
exec python3 - "$@" <<'PY'
import datetime, json, os, re, subprocess, sys, time

def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()
def stamp(value):
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, TypeError):
        return time.time()  # Missing timestamps never authorize removal.
def candidate(c):
    labels = c['Config'].get('Labels') or {}
    if 'com.docker.compose.project' in labels:
        return None
    state = c['State']
    if labels.get('sidstack.throwaway') == '1':
        if state['Status'] == 'exited' or time.time() - stamp(state['StartedAt']) > 7200:
            return '-fv'
    elif state['Status'] == 'exited' and time.time() - stamp(state['FinishedAt']) > 86400:
        return '-v'
    return None
def total(rows):
    # Docker reports rounded human-readable sizes, so the difference is approximate.
    units = {'B':1, 'kB':1000, 'MB':10**6, 'GB':10**9, 'TB':10**12}
    result = 0
    for row in rows.splitlines():
        size = json.loads(row)['Size']
        m = re.fullmatch(r'([\d.]+)(B|kB|MB|GB|TB)', size)
        if not m:
            raise ValueError('unrecognized Docker size: ' + size)
        result += float(m[1]) * units[m[2]]
    return result
try:
    if sys.argv[1:] not in ([], ['--dry-run']):
        sys.exit('usage: sid-docker-clean.sh [--dry-run]')
    dry = bool(sys.argv[1:])
    try:
        docker('info')
    except (OSError, subprocess.CalledProcessError):
        print('Docker is not running; nothing to clean.')
        sys.exit(0)
    versions = json.loads(docker('version', '--format', '{{json .}}'))
    version = versions['Server']
    api = min((version['ApiVersion'], versions['Client']['ApiVersion'],
               os.environ.get('DOCKER_API_VERSION', version['ApiVersion'])),
              key=lambda v: tuple(map(int, v.split('.'))))
    modern = tuple(map(int, api.split('.'))) >= (1, 42)
    volume_prune = ('volume', 'prune', '-f')
    if not modern:
        volume_prune += ('--filter', 'label=com.docker.volume.anonymous')
    policy = 'volume prune without --all removes anonymous volumes only' if modern else 'volume prune restricted to the anonymous-volume engine label'
    print(f"Docker {version['Version']} API {api}: {policy}.")
    before = total(docker('system', 'df', '--format', '{{json .}}'))
    ids = docker('ps', '-aq').split()
    for cid in ids:
        try:
            c = json.loads(docker('inspect', cid))[0]
        except subprocess.CalledProcessError:
            continue  # Auto-removed since enumeration.
        flags = candidate(c)
        if flags:
            if dry:
                print(f"Would remove container {c['Name'].lstrip('/')} ({cid})")
            else:
                # rm without force also protects a formerly-exited unlabelled container
                # which another process starts between inspect and rm.
                docker('rm', flags, cid)
                print(f"Removed container {c['Name'].lstrip('/')} ({cid})")
    if dry:
        # Anonymous volumes have this engine label; never infer anonymity from names.
        for volume in docker('volume', 'ls', '-q', '--filter', 'dangling=true', '--filter', 'label=com.docker.volume.anonymous').splitlines():
            print('Would remove anonymous volume ' + volume)
        for image in docker('image', 'ls', '-q', '--filter', 'dangling=true').splitlines():
            print('Would remove dangling image ' + image)
        print('Would prune unused build cache older than 72h')
    else:
        # These commands report each deleted object and their reclaimed totals.
        for args in [volume_prune, ('image', 'prune', '-f'),
                     ('builder', 'prune', '-f', '--filter', 'until=72h')]:
            print(docker(*args))
    after = total(docker('system', 'df', '--format', '{{json .}}'))
    print(f"Summary: {'dry-run; ' if dry else ''}space reclaimed approximately {before - after:,.0f} bytes (docker system df before={before:,.0f}, after={after:,.0f})")
except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as e:
    sys.exit('sid-docker-clean: ' + str(e))
PY
