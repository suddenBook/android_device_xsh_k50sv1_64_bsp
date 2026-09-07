#!/usr/bin/env python3
"""Exercise the actual post-flash app-launch function against bounded adb traces."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


FAKE_ADB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
base = Path(os.environ['K50_LAUNCH_FIXTURE'])
config = json.loads((base / 'config.json').read_text())
state_file = base / 'state.json'
state = json.loads(state_file.read_text()) if state_file.exists() else {'probes': 0}
command = sys.argv[-1]
if command.startswith('am start '):
    if config.get('launch_error'):
        print('Error: Activity class does not exist.')
    elif config.get('launch_failure'):
        sys.exit(1)
    else:
        state['active'] = command.split()[-1] + '/.Main'
        print('Starting: Intent { fixture }')
else:
    state['probes'] += 1
    if config.get('race') and not state.get('permission_settled'):
        if state['probes'] == 1:
            state['active'] = 'app.clock/.Main'
        elif state['probes'] == 2:
            state['active'] = 'com.android.permissioncontroller/.GrantPermissionsActivity'
        else:
            state['permission_settled'] = True
            state['active'] = 'app.clock/.Main'
        value = state['active']
    elif config.get('race'):
        value = state['active']
    else:
        values = config['trace']
        value = values[min(state['probes'] - 1, len(values) - 1)]
    if value == 'unread':
        print('__K50_ACTIVITY_RC__=1')
    else:
        print('__K50_ACTIVITY_RC__=0')
        if value != 'empty':
            print('mResumedActivity: ActivityRecord{fixture u0 ' + value + ' t1}')
state_file.write_text(json.dumps(state))
'''


def main():
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).with_name('verify-post-flash.sh')
    text = source.read_text()
    start = text.index('\nlaunch_package() {') + 1
    end = text.index('\n}\n', start) + 3
    body = text[start:end]
    tests = [
        ('stable', {'trace': ['app.test/.Main']}, ['app.test'], ['PASS'], 3),
        ('transient', {'trace': ['app.test/.Main', 'app.other/.Main']}, ['app.test'], ['FAIL'], 10),
        ('permission-interruption', {'trace': ['app.test/.Main', 'com.android.permissioncontroller/.GrantPermissionsActivity', 'app.test/.Main']}, ['app.test'], ['PASS'], 5),
        ('unread-interruption', {'trace': ['app.test/.Main', 'unread', 'app.test/.Main']}, ['app.test'], ['PASS'], 5),
        ('empty-interruption', {'trace': ['app.test/.Main', 'empty', 'app.test/.Main']}, ['app.test'], ['PASS'], 5),
        ('never-resumed', {'trace': ['app.other/.Main']}, ['app.test'], ['FAIL'], 10),
        ('unread', {'trace': ['unread']}, ['app.test'], ['SKIP'], 10),
        ('launch-error', {'launch_error': True}, ['app.test'], ['FAIL'], 0),
        ('launch-failure', {'launch_failure': True}, ['app.test'], ['SKIP'], 0),
        ('delayed-clock-permission', {'race': True}, ['app.clock', 'app.calendar'], ['PASS', 'PASS'], 8),
    ]
    failed = 0
    with tempfile.TemporaryDirectory(prefix='k50-launch-fixture-') as temporary:
        root = Path(temporary)
        fake_adb = root / 'adb'
        fake_adb.write_text(FAKE_ADB)
        fake_adb.chmod(0o700)
        for name, config, packages, expected, minimum_probes in tests:
            case = root / name
            case.mkdir()
            (case / 'config.json').write_text(json.dumps(config))
            script = '\n'.join([
                'set -u', f'ADB_BIN={shlex.quote(str(fake_adb))}', 'SERIAL=fixture',
                f'CAPTURE_DIR={shlex.quote(str(case))}',
                'must_write_text() { printf "%s\\n" "$2" > "$1"; }',
                'ok() { printf "PASS\\n"; }', 'no() { printf "FAIL\\n"; }',
                'skip() { printf "SKIP\\n"; }', 'note() { :; }',
                'sleep() { :; }', body,
                *[f'launch_package {shlex.quote(package)} fixture' for package in packages],
            ])
            result = subprocess.run(['bash', '-c', script], env=dict(os.environ, K50_LAUNCH_FIXTURE=str(case)), capture_output=True, text=True, timeout=15)
            state = json.loads((case / 'state.json').read_text()) if (case / 'state.json').exists() else {'probes': 0}
            passed = result.returncode == 0 and result.stdout.splitlines() == expected and state['probes'] >= minimum_probes
            failed += not passed
            print(f"{'PASS' if passed else 'FAIL'} {name}: outcomes={result.stdout.splitlines()} probes={state['probes']} expected={expected} minimum_probes={minimum_probes}")
            if result.stderr:
                print(result.stderr, file=sys.stderr)
    print(f'{len(tests) - failed}/{len(tests)} passed')
    return bool(failed)


if __name__ == '__main__':
    sys.exit(main())
