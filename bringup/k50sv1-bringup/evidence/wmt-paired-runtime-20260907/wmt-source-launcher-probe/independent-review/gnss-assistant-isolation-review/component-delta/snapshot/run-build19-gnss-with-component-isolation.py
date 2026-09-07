"""Pause the observed voice component for one GNSS run and restore its state."""
from pathlib import Path
import hashlib
import json
import os
import re
import shlex
import subprocess
import time
import traceback
import xml.etree.ElementTree as ET

trial = Path(__file__).resolve().parent
out = trial / 'runtime/build19-gnss-component-isolation'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')
package = 'com.google.android.googlequicksearchbox'
service_class = 'com.google.android.voiceinteraction.GsaVoiceInteractionService'
component = package + '/' + service_class
steps = []
state = dict(status='PREPARING', mutations_started=False)


def save():
    (out / 'result.json').write_text(json.dumps(state, indent=2) + '\n')


def shell(name, command):
    result = subprocess.run(adb + ['shell', command], env=env, capture_output=True, timeout=60)
    (out / (name + '.txt')).write_bytes(result.stdout + result.stderr)
    steps.append(dict(name=name, command=command, exit_code=result.returncode))
    (out / 'steps.json').write_text(json.dumps(steps, indent=2) + '\n')
    result.check_returncode()
    return result.stdout.decode()


def roles(name):
    root = ET.fromstring(shell(name, 'cat /data/system/users/0/roles.xml'))
    return {entry.get('name'): sorted(holder.get('name') for holder in entry.findall('holder'))
            for entry in root.findall('role')}


def package_state(text):
    user = re.search(r'^    User 0:.*\n(?:(?: {6,}[^\n]*|)\n)*', text, re.M)
    assert user, 'Missing user 0 package state'
    user = user[0]
    permissions = sorted(re.findall(r'^        android\.permission\.[\w.]+: granted=(?:true|false),.*$', user, re.M))
    assert permissions
    components = {}
    for kind in ('enabled', 'disabled'):
        found = re.search(r'^      ' + kind + r'Components:\n((?:        [\w.$]+\n)*)', user, re.M)
        components[kind] = sorted(found[1].split()) if found else []
    return dict(permissions=permissions, components=components,
                stopped=re.search(r'\bstopped=(true|false)\b', user)[1],
                enabled=int(re.search(r'\benabled=(\d+)\b', user)[1]))


try:
    expected = json.loads((trial / 'build19-expected-installed.json').read_text())
    early = json.loads((trial / 'runtime/build19-normal-reboot-early/early-complete.json').read_text())
    identity = shell('identity', 'cat /proc/sys/kernel/random/boot_id; '
                     'getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted').splitlines()
    assert identity == [early['identity'].splitlines()[0], expected['incremental'], '0']
    state['boot_id'] = identity[0]
    state['original_roles'] = roles('roles-before')
    shell('roles-live-before', 'dumpsys role')
    state['original_settings'] = {key: shell('before-' + key, 'settings get secure ' + key).rstrip('\r\n')
                                  for key in ('assistant', 'voice_recognition_service', 'voice_interaction_service')}
    assert state['original_settings']['voice_interaction_service'] == component
    state['original_package'] = package_state(shell('search-package-before', 'dumpsys package ' + package))
    original = state['original_package']
    assert original['enabled'] == 0 and original['stopped'] == 'false'
    assert all(service_class not in values for values in original['components'].values())
    state['component'] = component
    state['original_component_state'] = 'default'
    state['mutations_started'] = True
    save()
    disabled = shell('pause-observed-component', 'pm disable --user 0 ' + component)
    assert 'new state: disabled' in disabled
    shell('pause-system-binding', "settings put secure voice_interaction_service ''")
    for attempt in range(40):
        binding = shell('binding-isolated-' + str(attempt), 'settings get secure voice_interaction_service').rstrip('\r\n')
        service = shell('service-isolated-' + str(attempt), 'dumpsys voiceinteraction')
        if binding == '' and '(No active implementation)' in service:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('The observed voice component did not stop')
    isolated = package_state(shell('search-package-isolated', 'dumpsys package ' + package))
    assert service_class in isolated['components']['disabled']
    state['isolation'] = dict(status='PASS', method='Temporary disabled state for the observed voice-interaction component')
    state['status'] = 'RUNNING_GNSS'
    save()
    with (out / 'gnss-run.log').open('xb') as log:
        result = subprocess.run(['python3', str(trial / 'run-build19-gnss.py')],
                                env=env, stdout=log, stderr=subprocess.STDOUT, timeout=360)
    state['gnss_exit_code'] = result.returncode
    state['gnss_runner_sha256'] = hashlib.sha256((trial / 'run-build19-gnss.py').read_bytes()).hexdigest()
    result.check_returncode()
    state['status'] = 'PASS'
except BaseException as error:
    state['status'] = 'FAIL'
    state['error'] = repr(error)
    (out / 'failure-traceback.txt').write_text(traceback.format_exc())
finally:
    errors = []
    if state['mutations_started']:
        try:
            restored_component = shell('restore-component-default', 'pm default-state --user 0 ' + component)
            assert 'new state: default' in restored_component
        except BaseException as error:
            errors.append(dict(step='component-default', error=repr(error)))
        for key, value in state['original_settings'].items():
            try:
                command = 'settings delete secure ' + key if value == 'null' else 'settings put secure ' + key + ' ' + shlex.quote(value)
                shell('restore-' + key, command)
            except BaseException as error:
                errors.append(dict(step=key, error=repr(error)))
        try:
            shell('restore-search-availability', 'am start -W -n ' + package + '/.SearchActivity')
            time.sleep(2)
            restored = package_state(shell('search-package-restored', 'dumpsys package ' + package))
            assert restored == state['original_package']
            state['package_state_restored'] = True
        except BaseException as error:
            errors.append(dict(step='package-state', error=repr(error)))
        try:
            restored_roles = roles('roles-restored')
            shell('roles-live-restored', 'dumpsys role')
            assert restored_roles == state['original_roles']
            state['roles_restored'] = True
        except BaseException as error:
            errors.append(dict(step='role-holders', error=repr(error)))
        for key, value in state['original_settings'].items():
            try:
                assert shell('restored-' + key, 'settings get secure ' + key).rstrip('\r\n') == value
            except BaseException as error:
                errors.append(dict(step='verify-' + key, error=repr(error)))
    for name, command in [('remove-selector-dump', 'rm -f /data/local/tmp/k50-assistant-selector.xml'),
                          ('restore-home', 'input keyevent KEYCODE_HOME')]:
        try:
            shell(name, command)
        except BaseException as error:
            errors.append(dict(step=name, error=repr(error)))
    state['cleanup'] = dict(status='FAIL' if errors else 'PASS', errors=errors)
    if errors:
        state['status'] = 'FAIL'
    save()
print(json.dumps(state, indent=2))
raise SystemExit(state['status'] != 'PASS')
