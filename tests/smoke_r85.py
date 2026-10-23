"""Bounded real-image startup smoke; intentionally not an end-to-end reward test."""
import copy
import datetime
import json
from pathlib import Path
import subprocess
import sqlite3
import sys
import time

PIN = '6c7006d530355c8f07240e28bebac5c9f6c71b7d'
IMAGES = {
    'core': 'ghcr.io/ar-io/ar-io-core:27b668f978a7a28009097d6df4f19fffe4e3af04',
    'observer': 'ghcr.io/ar-io/ar-io-observer:c5e98ddcf567598358fa73a0852b6be2cbbd42c4',
    'envoy': 'ghcr.io/ar-io/ar-io-envoy:9a28d6538aca7fb88d96c862062b13a0ed0fce69',
    # Public Docker Hub redis:7 manifest HEAD checked 2026-10-23; no image pulled locally.
    'redis': 'redis:7@sha256:44960b3100c48159a66d28c18b0588c193492e25f7551d60e51dd464fc3eca5b',
}
# Public RFC 8032 section 7.1 test vectors. These are not real operator secrets.
KEYS = [
    '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
    '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb'
    '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
]


def b58(raw):
    alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    n, result = int.from_bytes(raw, 'big'), ''
    while n:
        n, r = divmod(n, 58)
        result = alphabet[r] + result
    return '1' * (len(raw) - len(raw.lstrip(b'\0'))) + result


def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + '\n', encoding='utf-8')


def command(args, timeout=20):
    return subprocess.run(args, text=True, capture_output=True, timeout=timeout, check=True).stdout


def compose(base, project, *args):
    return command(['docker', 'compose', '-p', project, '-f', str(base/'runtime.json'), *args])


def prepare(base, project):
    original = json.loads((base/'production-config.json').read_text())
    services = original['services']
    assert services['observer']['environment']['RUN_OBSERVER'] == 'true'
    assert services['observer']['environment']['SUBMIT_CONTRACT_INTERACTIONS'] == 'true'
    assert services['observer']['environment']['REPORT_DATA_SINK'] == 'turbo'
    result = {'name': project, 'services': {}, 'networks': {'smoke': {'internal': True}}}
    caps = {'core': ('2.5g', 1.5), 'observer': ('1g', 0.75), 'envoy': ('256m', 0.25), 'redis': ('192m', 0.25)}
    for name, image in IMAGES.items():
        s = copy.deepcopy(services[name])
        assert s['image'] == ('redis:7' if name == 'redis' else image), (name, s['image'])
        s['image'] = image
        for field in ('build', 'profiles', 'depends_on', 'labels', 'container_name', 'ports', 'networks'):
            s.pop(field, None)
        s.update(restart='no', networks=['smoke'], mem_limit=caps[name][0], cpus=caps[name][1], pids_limit=256)
        s['logging'] = {'driver': 'json-file', 'options': {'max-size': '5m', 'max-file': '2'}}
        s['security_opt'] = ['no-new-privileges:true']
        for volume in s.get('volumes', []):
            if volume['type'] == 'volume':
                assert volume['source'] == 'envoy-eds-data'
                volume.pop('volume', None)
                volume.update(type='bind', source=str(base/'node/data/envoy-eds'))
            src = Path(volume['source']).resolve()
            assert src.is_relative_to((base/'node').resolve()), src
            src.mkdir(parents=True, exist_ok=True)
            if name == 'observer' and volume['target'] == '/app/wallets':
                volume['read_only'] = True
        if name in ('core', 'observer'):
            # Cover the image's VOLUME /app/data as well as the upstream
            # subdirectory mounts, so Docker cannot create an uncapped anonymous
            # parent volume for writes outside those subdirectories.
            s.setdefault('volumes', []).insert(0, {'type': 'bind', 'source': str(base/'node/data'), 'target': '/app/data'})
        result['services'][name] = s
    core = result['services']['core']['environment']
    core.update(START_WRITERS='false', L1_BAND_IMPORT_ENABLED='false',
                ANS104_UNBUNDLE_WORKERS='0', NODE_MAX_OLD_SPACE_SIZE='1024',
                ENABLE_MEMPOOL_WATCHER='false', ENABLE_ARWEAVE_PEER_EDS='false',
                SOLANA_RPC_URL='http://127.0.0.1:9', RUN_AUTOHEAL='false')
    obs = result['services']['observer']['environment']
    obs.update(SUBMIT_CONTRACT_INTERACTIONS='false', ENABLE_EPOCH_CRANKING='false', ENABLE_CLEANUP='false',
               SOLANA_RPC_URL='http://127.0.0.1:9', TURBO_UPLOAD_SERVICE_URL='http://127.0.0.1:9')
    # Leave RUN_OBSERVER and REPORT_DATA_SINK enabled: this checks real key and
    # uploader construction. Paid actions have no route out of the network.
    result['services']['envoy']['environment']['TVAL_ENABLE_ARWEAVE_PEER_EDS'] = 'false'
    write(base/'runtime.json', result)
    write(base/'artifacts/scope.json', {
        'upstreamCommit': PIN, 'images': IMAGES, 'services': list(IMAGES),
        'network': 'Docker internal network; external egress disabled',
        'testDataHardLimitBytes': 1024**3, 'logLimitBytesPerService': 10*1024**2,
        'checks': ['actual installer write_env and validate_observer_config', 'real R85 image startup',
                   'fresh SQLite migrations', 'native operator/observer/upload key-loader startup validation',
                   'core and observer health and info', 'Envoy routing', 'no OOM/restarts'],
        'notCovered': ['interactive package installation', 'Nginx and public DNS/TLS', 'external data retrieval',
                       'chain synchronization', 'observer network assessments', 'paid upload/submission',
                       'stake, registration and reward eligibility'],
        'testOnlyOverrides': {'START_WRITERS': False, 'SUBMIT_CONTRACT_INTERACTIONS': False,
                             'ENABLE_EPOCH_CRANKING': False, 'RPCAndTurbo': 'unreachable loopback port'},
    })


def get_json(url, probe_container):
    # Docker internal networks can suppress host port publishing. Keep egress
    # isolation and make genuine bounded HTTP requests from the running core
    # container instead. No new probe container and no mocked response.
    script = '''
const response = await fetch(process.argv[1], {signal: AbortSignal.timeout(5000)});
if (response.status !== 200) throw new Error(`HTTP ${response.status}`);
const chunks = []; let bytes = 0;
for await (const chunk of response.body) {
  bytes += chunk.length;
  if (bytes > 131072) throw new Error('Response exceeds 128 KiB');
  chunks.push(chunk);
}
const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
process.stdout.write(JSON.stringify(body));
'''
    result = subprocess.run(['docker', 'exec', probe_container, '/nodejs/bin/node',
                             '--input-type=module', '-e', script, url],
                            text=True, capture_output=True, timeout=10)
    if result.returncode:
        raise RuntimeError(url + ': ' + result.stderr.strip()[-800:])
    return json.loads(result.stdout)


def check(base, project):
    ids = compose(base, project, 'ps', '-aq').split()
    assert len(ids) == 4, ids
    containers = json.loads(command(['docker', 'inspect', *ids]))
    networks = set()
    for c in containers:
        assert len(c['NetworkSettings']['Networks']) == 1
        assert all(m['Type'] == 'bind' for m in c['Mounts']), 'Unexpected anonymous/named Docker volume'
        networks.update(c['NetworkSettings']['Networks'])
    assert len(networks) == 1
    network = json.loads(command(['docker', 'network', 'inspect', *networks]))[0]
    assert network['Internal'] is True
    core_id = next(c['Id'] for c in containers if c['Config']['Labels']['com.docker.compose.service'] == 'core')
    observations = []
    deadline = time.monotonic() + 180
    expected_observer = (base/'addresses.txt').read_text().split()[1]
    while time.monotonic() < deadline:
        try:
            health = get_json('http://127.0.0.1:4000/ar-io/healthcheck', core_id)
            assert health['status'] == 'ok', health
            direct = get_json('http://observer:5050/ar-io/observer/healthcheck', core_id)
            assert direct['uptime'] > 0
            proxy = get_json('http://envoy:3000/ar-io/healthcheck', core_id)
            assert proxy['status'] == 'ok'
            info = get_json('http://envoy:3000/ar-io/observer/info', core_id)
            assert info['wallet'] == expected_observer, info
            assert info['reportSink'] == 'turbo'
            core_info = get_json('http://envoy:3000/ar-io/info', core_id)
            observations.append({'ok': True, 'coreHealth': health, 'observerHealth': direct, 'observerInfo': info, 'coreInfo': core_info})
            break
        except Exception as error:
            observations.append({'ok': False, 'error': str(error), 'at': datetime.datetime.now(datetime.timezone.utc).isoformat()})
            time.sleep(5)
    else:
        write(base/'artifacts/readiness.json', observations)
        raise SystemExit('Core/observer/Envoy did not become ready within 180 seconds.')
    time.sleep(20)
    final = json.loads(command(['docker', 'inspect', *ids]))
    states = []
    for c in final:
        state = c['State']
        assert state['Running'] and not state['OOMKilled'] and c['RestartCount'] == 0, state
        if 'Health' in state:
            assert state['Health']['Status'] != 'unhealthy', state['Health']
        states.append({'service': c['Config']['Labels']['com.docker.compose.service'],
                       'imageId': c['Image'], 'running': state['Running'], 'oomKilled': state['OOMKilled'],
                       'restartCount': c['RestartCount']})
    assert (base/'node/data/sqlite/core.db').is_file(), 'Fresh core.db missing'
    with sqlite3.connect((base/'node/data/sqlite/core.db').as_uri()+'?mode=ro', uri=True, timeout=2) as db:
        assert db.execute('PRAGMA quick_check').fetchone() == ('ok',)
        assert db.execute("SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0] > 0
    write(base/'artifacts/readiness.json', observations)
    write(base/'artifacts/startup-result.json', {'ok': True, 'states': states, 'freshCoreDb': True,
          'note': 'Startup smoke passed; network observations and rewards are not exercised.'})
    print('R85 isolated startup smoke passed (not a reward/registration/network-observation test).')


def collect(base, project, exit_code):
    try:
        raw = compose(base, project, 'logs', '--no-color', '--tail', '160')
        env = base/'node/.env'
        if env.exists():
            for line in env.read_text().splitlines():
                if line.startswith('ADMIN_API_KEY='):
                    raw = raw.replace(line.split('=', 1)[1], '[REDACTED_TEST_ADMIN_KEY]')
        (base/'artifacts/container-logs.txt').write_text(raw[-160000:], encoding='utf-8')
    except Exception as error:
        (base/'artifacts/log-collection.txt').write_text(type(error).__name__, encoding='utf-8')
    write(base/'artifacts/exit.json', {'exitCode': int(exit_code)})


if __name__ == '__main__':
    action, base = sys.argv[1], Path(sys.argv[2]).resolve()
    if action == 'keys':
        addresses = []
        for key_hex in KEYS:
            key = bytes.fromhex(key_hex)
            address = b58(key[32:])
            write(base/'node/wallets'/f'{address}.json', list(key))
            addresses.append(address)
        (base/'addresses.txt').write_text(' '.join(addresses)+'\n', encoding='utf-8')
    elif action == 'prepare':
        prepare(base, sys.argv[3])
    elif action == 'check':
        check(base, sys.argv[3])
    elif action == 'collect':
        collect(base, sys.argv[3], sys.argv[4])
    else:
        raise SystemExit('Unknown action')
