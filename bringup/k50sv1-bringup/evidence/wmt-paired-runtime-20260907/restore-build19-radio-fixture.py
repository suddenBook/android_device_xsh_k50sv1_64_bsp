"""Install fixed probe APKs, then restore the private saved Wi-Fi profile."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess
import time
import xml.etree.ElementTree as ET

trial = Path(__file__).resolve().parent
assert (trial / 'runtime/build19-first-boot-verify-result.json').is_file()
out = trial / 'runtime/build19-radio-preparation'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')


def run(label, args, timeout=35):
    result = subprocess.run(adb + args, env=env, capture_output=True, text=True,
                            timeout=timeout)
    (out / (label + '.txt')).write_text(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout


def shell(label, command):
    return run(label, ['shell', command])


probes = [
    ('gnss', 'local.k50.gnssprobe', trial / 'gnss-probe/gnss-probe.apk'),
    ('p2p', 'local.k50.p2pprobe', trial.parents[1] /
     'k50sv1-bringup/tools/runtime-probes/p2p/out/k50-p2p-probe.apk'),
]
installed = []
for label, package, apk in probes:
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    run(label + '-install', ['install', '-r', str(apk)], timeout=180)
    paths = shell(label + '-path', 'pm path ' + package).strip().splitlines()
    assert len(paths) == 1 and paths[0].startswith('package:/data/app/'), paths
    installed_path = paths[0].removeprefix('package:')
    actual = shell(label + '-hash', 'sha256sum ' + shlex.quote(installed_path)).split()[0]
    assert actual == digest, label
    installed.append(dict(package=package, sha256=digest, installed_path=installed_path))

source = trial / 'private-before-wmt-command-v2-clang/WifiConfigStore.xml'
ET.fromstring(source.read_bytes())
shell('wifi-disable', 'svc wifi disable')
time.sleep(2)
run('wifi-profile-push', ['push', str(source), '/data/local/tmp/k50-restore-wifi.xml'])
shell('wifi-profile-restore',
      'cp /data/local/tmp/k50-restore-wifi.xml /data/misc/wifi/WifiConfigStore.xml && '
      'chown system:system /data/misc/wifi/WifiConfigStore.xml && '
      'chmod 600 /data/misc/wifi/WifiConfigStore.xml && '
      'restorecon /data/misc/wifi/WifiConfigStore.xml && '
      'rm /data/local/tmp/k50-restore-wifi.xml')
assert shell('wifi-profile-hash', 'sha256sum /data/misc/wifi/WifiConfigStore.xml').split()[0] == hashlib.sha256(source.read_bytes()).hexdigest()
shell('wifi-profile-attributes', 'ls -lZ /data/misc/wifi/WifiConfigStore.xml')
shell('radios-enable', 'svc wifi enable; svc bluetooth enable')
(out / 'result.json').write_text(json.dumps(dict(status='PASS', probes=installed,
    wifi_restored=True, restored_after_probe_installation=True,
    requires_normal_reboot_to_load_store=True), indent=2) + '\n')
print('PASS: both probe APKs match readback; private Wi-Fi profile restored; normal reboot must load it before radio tests', flush=True)
