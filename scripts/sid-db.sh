#!/usr/bin/env bash
# Disposable Postgres, with no persistent data volume.
set -eu
exec python3 - "$@" <<'PY'
import datetime, json, secrets, subprocess, sys, time
from urllib.parse import urlparse

def docker(*args, **kw):
    return subprocess.run(['docker', *args], check=True, text=True, stdout=subprocess.PIPE, **kw).stdout.strip()
def fail(message):
    sys.exit('sid-db: ' + message)
def inspect(name):
    return json.loads(docker('inspect', name))[0]
def owned(c):
    labels = c['Config'].get('Labels') or {}
    return labels.get('sidstack.throwaway') == '1' and 'com.docker.compose.project' not in labels
try:
    args = sys.argv[1:]
    if not args or args[0] not in ('start', 'stop', 'list') or len(args) > 2 or (args[0] == 'stop' and len(args) != 2) or (args[0] == 'list' and len(args) != 1):
        fail('usage: sid-db.sh start [name] | stop <name|url> | list')
    try:
        docker('info', stderr=subprocess.DEVNULL)
    except (OSError, subprocess.CalledProcessError):
        fail('Docker is not available or is not running')
    cmd = args[0]
    if cmd == 'start':
        image = 'pgvector/pgvector:pg17'
        try:
            docker('image', 'inspect', image, stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            fail('image ' + image + ' is not pulled; pull it explicitly first')
        name = args[1] if len(args) == 2 else 'sid-db-' + secrets.token_hex(6)
        password = secrets.token_hex(16)
        cid = docker('run', '-d', '--pull=never', '--rm', '--name', name,
                     '--tmpfs', '/var/lib/postgresql/data', '--label', 'sidstack.throwaway=1',
                     '--label', 'sidstack.started-at=' + str(int(time.time())),
                     '-e', 'POSTGRES_USER=sid', '-e', 'POSTGRES_PASSWORD=' + password,
                     '-e', 'POSTGRES_DB=sid', '-p', '127.0.0.1::5432', image)
        try:
            deadline = time.monotonic() + 60
            while True:
                try:
                    docker('exec', cid, 'pg_isready', '-h', '127.0.0.1', '-U', 'sid', '-d', 'sid', stderr=subprocess.DEVNULL,
                           timeout=max(.1, deadline - time.monotonic()))
                    break
                except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                    if time.monotonic() >= deadline:
                        fail('Postgres did not become ready within 60 seconds')
                    time.sleep(min(.5, max(0, deadline - time.monotonic())))
            port = inspect(cid)['NetworkSettings']['Ports']['5432/tcp'][0]['HostPort']
            print(f'postgres://sid:{password}@127.0.0.1:{port}/sid')
        except BaseException:
            docker('rm', '-fv', cid)
            raise
    else:
        ids = docker('ps', '-aq', '--filter', 'label=sidstack.throwaway=1').split()
        if cmd == 'list':
            for cid in ids:
                c = inspect(cid)
                if owned(c) and c['State']['Running']:
                    started = datetime.datetime.fromisoformat(c['State']['StartedAt'].replace('Z', '+00:00'))
                    age = int((datetime.datetime.now(datetime.timezone.utc) - started).total_seconds())
                    print(f"{c['Name'].lstrip('/')} age={age}s")
        else:
            target = args[1]
            if '://' in target:
                url = urlparse(target)
                if url.scheme != 'postgres' or url.hostname != '127.0.0.1' or not url.port:
                    fail('expected a local sid-db Postgres URL')
                matches = [c for cid in ids if owned(c := inspect(cid)) and any(
                    p['HostIp'] == '127.0.0.1' and p['HostPort'] == str(url.port)
                    for p in c['NetworkSettings']['Ports'].get('5432/tcp') or [])]
                if len(matches) != 1:
                    fail('URL does not identify one throwaway database')
                c = matches[0]
            else:
                c = inspect(target)
            if not owned(c):
                fail('refusing to stop a container without our label or belonging to Compose')
            docker('rm', '-fv', c['Id'])
except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as e:
    fail(str(e))
PY
