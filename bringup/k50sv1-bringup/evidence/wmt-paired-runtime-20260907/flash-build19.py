"""Flash only the validated build19 stage after confirming the retained predecessor."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess
import time

trial = Path(__file__).resolve().parent
stage_result = json.loads((trial / 'build19-stage-result.json').read_text())
expected = json.loads((trial / 'build19-expected-installed.json').read_text())
preserved = json.loads((trial / 'build19-preserved-stage-result.json').read_text())
preflash = json.loads((trial / 'runtime/build19-preflash/result.json').read_text())
assert all(row['status'] == 'PASS' for row in [stage_result, expected, preserved, preflash])
assert len(expected['rows']) == 30
assert expected['new_native_source_paths'] == ['/vendor/bin/wmt_launcher']
launcher = next(row for row in expected['rows'] if row['path'] == '/vendor/bin/wmt_launcher')
assert launcher['sha256'] != expected['factory_launcher_sha256']
assert Path(stage_result['stage']) == Path(preserved['stage'])
stage = Path(stage_result['stage'])
receipt = trial / 'source-stack-wmt-command-v2-clang-flash-receipt.txt'
log = trial / 'build19-flash.log'
result_path = trial / 'build19-flash-process-result.json'
assert not receipt.exists() and not log.exists() and not result_path.exists()
env = dict(os.environ, ADB_LIBUSB='1', K50SV1_BUILD_TIER='1', PYTHONDONTWRITEBYTECODE='1')
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
identity = subprocess.run(adb + ['shell',
    'getprop ro.build.version.incremental; cat /proc/sys/kernel/random/boot_id; '
    'getprop sys.boot_completed; cat /proc/sys/kernel/tainted'],
    env=env, capture_output=True, check=True, timeout=30)
(trial / 'runtime/build19-preflash/immediate-identity.txt').write_bytes(identity.stdout + identity.stderr)
assert identity.stdout.decode().splitlines() == preflash['identity']
files = preflash['files']
checked = subprocess.run(adb + ['shell', 'sha256sum ' + ' '.join(shlex.quote(row['path']) for row in files)],
                         env=env, capture_output=True, check=True, timeout=30)
(trial / 'runtime/build19-preflash/immediate-calibration-firmware.txt').write_bytes(checked.stdout + checked.stderr)
hashes = {line.split(None, 1)[1].strip(): line.split()[0] for line in checked.stdout.decode().splitlines()}
assert len(files) == 19 and all(hashes[row['path']] == row['after_sha256'] for row in files)
collector_state = subprocess.check_output(['systemctl', '--user', 'show', 'k50sv1-build19-first-boot.service',
                                          '--property=ActiveState', '--value'], text=True).strip()
assert collector_state == 'active'
tool = trial / 'build19-verification-project/work/k50sv1-bringup/tools/flash-tier-images.sh'
command = [str(tool), str(stage), str(receipt), '0123456789ABCDEF']
started = time.time()
with log.open('xb') as output:
    process = subprocess.run(command, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=1200)
result = dict(exit_code=process.returncode, started_epoch=started, finished_epoch=time.time(),
              command=command, tool_sha256=hashlib.sha256(tool.read_bytes()).hexdigest(),
              log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
              flash_receipt_sha256=hashlib.sha256(receipt.read_bytes()).hexdigest() if receipt.is_file() else None)
result_path.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
raise SystemExit(process.returncode)
