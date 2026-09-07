"""Observe standard fresh-data HOME selection and enable radios before network restoration."""

from pathlib import Path
import json
import os
import subprocess
import time
import xml.etree.ElementTree as ET

trial = Path(__file__).resolve().parent
assert (trial / 'runtime/build19-first-boot-early/early-complete.json').is_file()
out = trial / 'runtime/build19-initial-home'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')


def run(label, args):
    result = subprocess.run(adb + args, env=env, capture_output=True, text=True, timeout=30)
    (out / (label + '.txt')).write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f'{label}: adb failed with {result.returncode}')
    return result.stdout


def sh(label, command):
    return run(label, ['shell', command])


def home_holders(text):
    return [item.get('name') for item in ET.fromstring(text).findall(
        "./role[@name='android.app.role.HOME']/holder")]


before = sh('before', 'settings get global device_provisioned; settings get secure user_setup_complete; getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id')
assert before.splitlines()[:3] == ['0', '0', '1'], before
before_holders = home_holders(sh('roles-before', 'cat /data/system/users/0/roles.xml'))
sh('resolver-before', 'cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME -c android.intent.category.DEFAULT')
sh('bypass', 'settings put global device_provisioned 1 && settings put secure user_setup_complete 1 && pm disable-user --user 0 org.lineageos.setupwizard && pm disable-user --user 0 com.google.android.setupwizard')

deadline = time.monotonic() + 90
observations = []
while time.monotonic() < deadline:
    holders = home_holders(sh('roles-after', 'cat /data/system/users/0/roles.xml'))
    resolved = sh('resolved', 'cmd package resolve-activity --brief --user 0 -a android.intent.action.MAIN -c android.intent.category.HOME -c android.intent.category.DEFAULT')
    observations.append(dict(epoch=time.time(), holders=holders, resolver=resolved))
    (out / 'home-observations.json').write_text(json.dumps(observations, indent=2) + '\n')
    if holders == ['com.android.launcher3'] and any(line.strip() in {
            'com.android.launcher3/.lineage.LineageLauncher',
            'com.android.launcher3/com.android.launcher3.lineage.LineageLauncher'}
            for line in resolved.splitlines()):
        break
    time.sleep(2)
else:
    raise RuntimeError('Standard HOME did not settle on Trebuchet after setup')

sh('wake', 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard')
launched = sh('launch', 'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME -c android.intent.category.DEFAULT')
assert 'com.android.launcher3/.lineage.LineageLauncher' in launched, launched
policy = subprocess.run(['python3', str(trial / 'build-project/work/k50sv1-bringup/tools/check-launcher-policy.py'),
                         'runtime', '--adb', adb[0], '--serial', adb[2], '--post-setup'],
                        env=env, capture_output=True, text=True, timeout=180)
(out / 'launcher-policy.json').write_text(policy.stdout)
if policy.returncode or json.loads(policy.stdout).get('status') != 'PASS':
    raise RuntimeError('Launcher runtime policy failed: ' + policy.stderr + policy.stdout)

sh('calendar-before-test-preparation', 'dumpsys package org.lineageos.etar')
sh('calendar-test-preparation', 'pm grant org.lineageos.etar android.permission.READ_EXTERNAL_STORAGE; pm grant org.lineageos.etar android.permission.WRITE_EXTERNAL_STORAGE')
calendar = sh('calendar-after-test-preparation', 'dumpsys package org.lineageos.etar')
assert all('android.permission.' + name + ': granted=true' in calendar for name in
           ['READ_EXTERNAL_STORAGE', 'WRITE_EXTERNAL_STORAGE'])
result = dict(status='PASS', boot_id=before.splitlines()[3], manual_home_setter_called=False,
              setup_before=before.splitlines()[:3], home_role_holders_before_setup=before_holders,
              home_role_holders_after_setup=holders, first_resolution=resolved,
              first_launch=launched, launcher_removal_policy='PASS',
              calendar_storage_grants='Explicit test preparation, not a default-grant claim')
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')

sh('radios-enable-without-saved-network', 'svc wifi enable; svc bluetooth enable')
print('PASS: standard HOME, Niagara absence and Calendar test permissions; radios enabled without restoring the saved network yet', flush=True)
