from pathlib import Path
import hashlib,json,os,shlex,subprocess,xml.etree.ElementTree as ET
trial=Path(__file__).resolve().parent
out=trial/'runtime/build19-preflash';out.mkdir(exist_ok=False)
private=trial/'private-before-wmt-command-v2-clang';private.mkdir(mode=0o700,exist_ok=False)
adb=['/home/desmond/Android/Sdk/platform-tools/adb','-s','0123456789ABCDEF']
env=dict(os.environ,ADB_LIBUSB='1')
def capture(name,command):
 r=subprocess.run(adb+['shell',command],capture_output=True,env=env,timeout=35)
 (out/name).write_bytes(r.stdout+r.stderr)
 r.check_returncode()
 return r.stdout
identity=capture('identity.txt','getprop ro.build.version.incremental; cat /proc/sys/kernel/random/boot_id; getprop sys.boot_completed; cat /proc/sys/kernel/tainted')
expected=json.loads((trial/'build17-expected-installed.json').read_text())
last=json.loads((trial/'runtime/build17-final/result.json').read_text())
assert identity.decode().splitlines()==[expected['incremental'],last['boot_id'],'1','0']
capture('dmesg.txt','dmesg')
capture('pstore-hashes.txt','find /sys/fs/pstore -type f -exec sha256sum {} \\;')
capture('launcher-before.txt','pm list packages -u bitpit.launcher; settings get secure enabled_notification_listeners; cat /data/system/users/0/roles.xml')
r=subprocess.run(adb+['pull','/data/misc/wifi/WifiConfigStore.xml',str(private/'WifiConfigStore.xml')],capture_output=True,env=env,timeout=35)
r.check_returncode()
(private/'WifiConfigStore.xml').chmod(0o600)
ET.fromstring((private/'WifiConfigStore.xml').read_bytes())
reference=json.loads((trial/'runtime/build17-final/calibration-firmware.json').read_text())
paths=[v['path'] for v in reference['files']]
raw=capture('calibration-firmware-hashes.txt','sha256sum '+' '.join(shlex.quote(p) for p in paths))
hashes=dict((line.split(None,1)[1].strip(),line.split()[0]) for line in raw.decode().splitlines())
rows=[dict(path=v['path'],before_sha256=v['after_sha256'],after_sha256=hashes[v['path']],match=v['after_sha256']==hashes[v['path']]) for v in reference['files']]
assert len(rows)==19 and all(v['match'] for v in rows)
result=dict(status='PASS',identity=identity.decode().splitlines(),calibration_firmware_unchanged=19,wifi_backup_xml_valid=True,wifi_backup_mode='0600',wifi_backup_parent_mode='0700',files=rows)
(out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS: build17 identity, 19 calibration/firmware hashes, launcher baseline and private Wi-Fi backup captured')

