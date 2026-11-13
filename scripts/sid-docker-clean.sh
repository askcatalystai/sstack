#!/usr/bin/env bash
# Protect Compose and named volumes; expire disposable Docker resources.
set -eu
exec python3 - "$@" <<'PY'
import datetime, json, re, subprocess, sys, time

def docker(*args):
    return subprocess.check_output(['docker', *args], text=True).strip()
def stamp(value):
    try:
        if not value:
            return None
        dt = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if dt.year <= 1:  # Docker unset StartedAt/FinishedAt is 0001-01-01T00:00:00Z.
            return None
        return dt.timestamp()
    except (ValueError, TypeError):
        return None
def candidate(c):
    labels = c['Config'].get('Labels') or {}
    if 'com.docker.compose.project' in labels:
        return None
    state = c['State']
    if labels.get('sidstack.throwaway') == '1':
        if state['Status'] == 'exited':
            return '-fv'
        status = state['Status']
        if status in ('created', 'dead'):
            age_from, limit = stamp(c.get('Created')), 7200
        else:
            age_from, limit = stamp(state.get('StartedAt')), 28800
        if age_from is not None and time.time() - age_from > limit:
            return '-fv'
    elif state['Status'] == 'exited':
        finished = stamp(state['FinishedAt'])
        if finished is not None and time.time() - finished > 86400:
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
failed = False
def report(error):
    global failed
    failed = True
    print('sid-docker-clean: ' + str(error), file=sys.stderr)
def attempt(*args):
    try:
        return docker(*args)
    except (OSError, subprocess.CalledProcessError) as e:
        report(e)
        return None
def usage_total():
    rows = attempt('system', 'df', '--format', '{{json .}}')
    if rows is not None:
        try:
            return total(rows)
        except (ValueError, KeyError, TypeError) as e:
            report(e)
    return None
try:
    if sys.argv[1:] not in ([], ['--dry-run']):
        sys.exit('usage: sid-docker-clean.sh [--dry-run]')
    dry = bool(sys.argv[1:])
    try:
        docker('info')
    except (OSError, subprocess.CalledProcessError):
        print('Docker is not running; nothing to clean.')
        sys.exit(0)
    before = usage_total()
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
                if attempt('rm', flags, cid) is not None:
                    print(f"Removed container {c['Name'].lstrip('/')} ({cid})")
    # Only engine-labelled anonymous volumes outside Compose are disposable.
    volumes = attempt('volume', 'ls', '-q', '--filter', 'dangling=true',
                     '--filter', 'label=com.docker.volume.anonymous')
    for volume in (volumes or '').splitlines():
        inspected = attempt('volume', 'inspect', volume)
        if inspected is None:
            continue
        try:
            labels = json.loads(inspected)[0].get('Labels') or {}
        except (ValueError, KeyError, TypeError, IndexError) as e:
            report(e)
            continue
        if any(key in labels for key in ('com.docker.compose.project', 'com.docker.compose.volume')):
            continue
        if dry:
            print('Would remove anonymous volume ' + volume)
        else:
            result = attempt('volume', 'rm', volume)
            if result is not None:
                print(result)
    if dry:
        for image in (attempt('image', 'ls', '-q', '--filter', 'dangling=true') or '').splitlines():
            print('Would remove dangling image ' + image)
        print('Would prune unused build cache older than 72h')
    else:
        for args in [('image', 'prune', '-f'),
                     ('builder', 'prune', '-f', '--filter', 'until=72h')]:
            result = attempt(*args)
            if result is not None:
                print(result)
    after = usage_total()
    prefix = 'dry-run; ' if dry else ''
    if before is None or after is None:
        print(f'Summary: {prefix}space reclaimed unavailable (docker system df failed)')
    else:
        print(f"Summary: {prefix}space reclaimed approximately {before - after:,.0f} bytes (docker system df before={before:,.0f}, after={after:,.0f})")
    sys.exit(1 if failed else 0)
except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as e:
    sys.exit('sid-docker-clean: ' + str(e))
PY
