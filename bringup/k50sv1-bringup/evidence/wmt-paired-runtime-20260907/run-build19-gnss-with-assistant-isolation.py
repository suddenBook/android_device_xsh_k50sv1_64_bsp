"""Use the system's None assistant choice for one GNSS run, then restore it."""
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
out = trial / 'runtime/build19-gnss-assistant-isolation'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')
package = 'com.google.android.googlequicksearchbox'
role = 'android.app.role.ASSISTANT'
steps = []
state = dict(status='PREPARING', mutations_started=False, cleanup=dict(status='NOT_NEEDED'))


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


def permissions(text):
    user = text.split('    User 0:', 1)[1]
    runtime = user.split('      runtime permissions:', 1)[1]
    return sorted(line.strip() for line in runtime.splitlines()
                  if re.match(r'^\s+android\.permission\.[\w.]+: granted=(?:true|false),', line))


try:
    expected = json.loads((trial / 'build19-expected-installed.json').read_text())
    early = json.loads((trial / 'runtime/build19-normal-reboot-early/early-complete.json').read_text())
    identity = shell('identity', 'cat /proc/sys/kernel/random/boot_id; '
                     'getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted').splitlines()
    assert identity == [early['identity'].splitlines()[0], expected['incremental'], '0']
    state['boot_id'] = identity[0]
    state['original_roles'] = roles('roles-before')
    assert state['original_roles'][role] == [package]
    state['original_settings'] = {key: shell('before-' + key, 'settings get secure ' + key).rstrip('\r\n')
                                  for key in ('assistant', 'voice_recognition_service', 'voice_interaction_service')}
    before_package = shell('search-package-before', 'dumpsys package ' + package)
    state['original_runtime_permissions'] = permissions(before_package)
    assert state['original_runtime_permissions']
    save()
    shell('wake', 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard')
    launched = shell('open-assistant-selector', 'am start -W -a android.intent.action.MANAGE_DEFAULT_APP '
                     '-e android.intent.extra.ROLE_NAME ' + role)
    assert 'Status: ok' in launched
    selected = None
    for attempt in range(10):
        shell('ui-dump-' + str(attempt), 'uiautomator dump /data/local/tmp/k50-assistant-selector.xml')
        raw = shell('ui-' + str(attempt), 'cat /data/local/tmp/k50-assistant-selector.xml')
        root = ET.fromstring(raw)
        candidates = [node for node in root.iter('node') if node.get('text') == 'None' and node.get('enabled') == 'true']
        if len(candidates) == 1:
            selected = candidates[0]
            break
        time.sleep(0.5)
    assert selected is not None, 'The system assistant selector did not expose one enabled None choice'
    bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', selected.get('bounds', ''))
    assert bounds
    left, top, right, bottom = map(int, bounds.groups())
    assert right > left and bottom > top
    state['none_choice'] = dict(selected.attrib)
    state['mutations_started'] = True
    save()
    shell('choose-none', 'input tap ' + str((left + right) // 2) + ' ' + str((top + bottom) // 2))
    for attempt in range(40):
        observed = roles('roles-isolated-' + str(attempt))
        binding = shell('binding-isolated-' + str(attempt), 'settings get secure voice_interaction_service').rstrip('\r\n')
        service = shell('service-isolated-' + str(attempt), 'dumpsys voiceinteraction')
        if observed.get(role) == [] and binding == '' and '(No active implementation)' in service:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError('None did not remove the assistant role and system implementation')
    assert {key: value for key, value in observed.items() if key != role} == {
        key: value for key, value in state['original_roles'].items() if key != role}
    state['isolation'] = dict(status='PASS', method='System assistant selector None choice', roles=observed)
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
            shell('restore-assistant-role', 'cmd role add-role-holder --user 0 ' + role + ' ' + package + ' 0')
            for attempt in range(40):
                restored_roles = roles('restored-roles-' + str(attempt))
                if restored_roles == state['original_roles']:
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError('Original role holders did not return')
            state['restored_roles'] = restored_roles
        except BaseException as error:
            errors.append(dict(step='assistant-role', error=repr(error)))
        for key, value in state['original_settings'].items():
            try:
                command = 'settings delete secure ' + key if value == 'null' else 'settings put secure ' + key + ' ' + shlex.quote(value)
                shell('restore-' + key, command)
                assert shell('restored-' + key, 'settings get secure ' + key).rstrip('\r\n') == value
            except BaseException as error:
                errors.append(dict(step=key, error=repr(error)))
        try:
            shell('restore-search-availability', 'am start -W -n ' + package + '/.SearchActivity')
            restored = shell('search-package-restored', 'dumpsys package ' + package)
            assert re.search(r'^\s*User 0:.*\bstopped=false\b', restored, re.M)
            assert permissions(restored) == state['original_runtime_permissions']
            state['runtime_permission_state_restored'] = True
        except BaseException as error:
            errors.append(dict(step='search-availability-and-permissions', error=repr(error)))
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
