"""Remove the temporary probe apps and attest the final handset/calibration state."""
from pathlib import Path
import json
import os
import shlex
import subprocess

trial = Path(__file__).resolve().parent
out = trial / 'runtime/build19-final'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')
expected = json.loads((trial / 'build19-expected-installed.json').read_text())
normal = json.loads((trial / 'runtime/build19-normal-reboot-early/early-complete.json').read_text())
boot_id = normal['identity'].splitlines()[0]


def shell(label, command):
    result = subprocess.run(adb + ['shell', command], env=env, capture_output=True,
                            text=True, timeout=90)
    (out / (label + '.txt')).write_text(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout


radio = json.loads((trial / 'runtime/build19-radio-cycle/result.json').read_text())
gnss = json.loads((trial / 'runtime/build19-gnss/result.json').read_text())
p2p = json.loads((trial / 'runtime/build19-p2p/result.json').read_text())
adie = json.loads((trial / 'runtime/build19-adie-read/result.json').read_text())
thermal = json.loads((trial / 'runtime/build19-thermal-read/result.json').read_text())
thermal_background = json.loads((trial / 'runtime/build19-thermal-background/result.json').read_text())
platform = json.loads((trial / 'runtime/build19-normal-reboot-platform-state/result.json').read_text())
launcher_exercise = json.loads((trial / 'runtime/build19-source-launcher-exercise/result.json').read_text())
assert launcher_exercise['status'] == 'PASS' and launcher_exercise['boot_id'] == boot_id
assert launcher_exercise['checks']['exercise_runtime']['status'] == 'PASS'
assert launcher_exercise['checks']['sigterm-restart']['status'] == 'PASS'
assert launcher_exercise['cleanup']['status'] == 'PASS'
assert launcher_exercise['cleanup']['restored_property'] == launcher_exercise['original_fwlog_property']
startup_statuses = []
for phase in ('first-boot', 'normal-reboot'):
    launcher = json.loads((trial / f'runtime/build19-source-launcher-{phase}/result.json').read_text())
    phase_early = json.loads((trial / f'runtime/build19-{phase}-early/early-complete.json').read_text())
    assert launcher['boot_id'] == phase_early['identity'].splitlines()[0]
    assert launcher['status'] in ('PASS', 'INCONCLUSIVE')
    assert launcher['checks']['capture_runtime']['status'] == 'PASS'
    startup_statuses.append(launcher['checks']['startup_attribution']['status'])
assert 'PASS' in startup_statuses, 'Need actual cold-boot session/patch/power startup evidence'
assert all(result['boot_id'] == boot_id for result in [radio, gnss, p2p, adie])
assert radio['completed'] and radio['settings_restored'] and not radio['new_faults']
assert gnss['summary'] and 'started=true stopped=true' in gnss['summary'][0] and not gnss['new_faults']
assert all(p2p[key] for key in ['probe_pass', 'p2p_ipv4_added', 'p2p_ipv4_removed']) and not p2p['new_faults']
assert adie['status'] == 'PASS'
assert thermal['status'] == 'PASS' and thermal['identity_after']['boot_id'] == boot_id
assert thermal['identity_after']['taint'] == 0
assert thermal_background['status'] == 'PASS_OBSERVED_CALLBACK_EXECUTION'
assert thermal_background['boot_id'] == boot_id and thermal_background['observed_nonzero_query_records'] >= 1
assert all(not row['recognized_fault_signatures'] for row in thermal['reads'])
assert platform['status'] == 'PASS' and platform['boot_id'] == boot_id
assert platform['bound_device'] == '18070000.consys'
assert platform['attributes_present'] == dict(bind=False, unbind=False)
for label, package in [('gnss', 'local.k50.gnssprobe'), ('p2p', 'local.k50.p2pprobe')]:
    shell(label + '-stop', 'am force-stop ' + package)
    assert shell(label + '-uninstall', 'pm uninstall ' + package).strip() == 'Success'
    assert not shell(label + '-package-absence', 'pm list packages -u ' + package).strip()
home = shell('home', 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard; '
             'am start -W -a android.intent.action.MAIN -c android.intent.category.HOME '
             '-c android.intent.category.DEFAULT')
assert 'com.android.launcher3/.lineage.LineageLauncher' in home
identity = shell('identity', 'getprop ro.build.version.incremental; '
                 'cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; '
                 'getprop sys.boot_completed; cat /proc/uptime').splitlines()
assert identity[:4] == [expected['incremental'], boot_id, '0', '1']
log_preparation = json.loads((trial / 'runtime/build19-normal-log-preparation/result.json').read_text())
assert log_preparation['status'] == 'PASS'
shell('restore-log-property', 'setprop ' + shlex.quote(log_preparation['property']) + ' ' +
      shlex.quote(log_preparation['original']))
assert shell('restored-log-property', 'getprop ' + shlex.quote(log_preparation['property'])).rstrip('\r\n') == log_preparation['original']
shell('restore-log-clock-property', 'setprop ' + shlex.quote(log_preparation['clock_property']) + ' ' +
      shlex.quote(log_preparation['original_clock']))
assert shell('restored-log-clock-property', 'getprop ' + shlex.quote(log_preparation['clock_property'])).rstrip('\r\n') == log_preparation['original_clock']
reference = json.loads((trial / 'runtime/build19-preflash/result.json').read_text())
paths = [row['path'] for row in reference['files']]
raw = shell('calibration-firmware-hashes', 'sha256sum ' + ' '.join(map(shlex.quote, paths)))
hashes = {line.split(None, 1)[1].strip(): line.split()[0] for line in raw.splitlines()}
rows = [dict(path=row['path'], before_sha256=row['after_sha256'],
             after_sha256=hashes[row['path']], match=row['after_sha256'] == hashes[row['path']])
        for row in reference['files']]
assert len(rows) == 19 and all(row['match'] for row in rows)
(out / 'calibration-firmware.json').write_text(json.dumps(dict(status='PASS', files=rows), indent=2) + '\n')
policy = subprocess.run(['python3', str(trial / 'build-project/work/k50sv1-bringup/tools/check-launcher-policy.py'),
                         'runtime', '--adb', adb[0], '--serial', adb[2], '--post-setup'],
                        env=env, capture_output=True, text=True, timeout=180)
(out / 'launcher-policy.json').write_text(policy.stdout)
assert policy.returncode == 0 and json.loads(policy.stdout)['status'] == 'PASS', policy.stderr
result = dict(status='PASS', boot_id=boot_id, incremental=identity[0], taint=0,
              temporary_probe_packages_removed=True, launcher_policy='PASS',
              source_launcher_exercise='PASS', source_launcher_startup_statuses=startup_statuses,
              normal_log_property_restored=True,
              attributed_thermal_callback_reads=thermal['attributed_callback_reads'],
              background_thermal_callback_records=thermal_background['observed_nonzero_query_records'],
              calibration_firmware_unchanged=19, identity=identity)
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
