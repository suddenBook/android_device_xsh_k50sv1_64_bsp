"""Capture one read-only A-die ioctl, its exact binary and bounded kernel output."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys

trial = Path(__file__).resolve().parent
build, = sys.argv[1:]
assert build in ('15', '16')
out = trial / f'runtime/build{build}-adie-read'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')
expected = json.loads((trial / f'build{build}-expected-installed.json').read_text())
remote = '/data/local/tmp/k50-wmt-adie-probe'
probe = trial / 'wmt-adie-probe/wmt-adie-probe'


def run(label, args, timeout=35, check=True):
    result = subprocess.run(adb + args, env=env, capture_output=True, text=True,
                            timeout=timeout)
    (out / (label + '.txt')).write_text(result.stdout + result.stderr)
    if check:
        result.check_returncode()
    return result


def shell(label, command, **kwargs):
    return run(label, ['shell', command], **kwargs)


identity = shell('identity', 'getprop ro.build.version.incremental; '
                 'cat /proc/sys/kernel/random/boot_id; cat /proc/sys/kernel/tainted; '
                 'cat /proc/uptime; settings get global wifi_on; settings get global bluetooth_on').stdout.splitlines()
assert identity[0] == expected['incremental'] and identity[2] == '0'
assert identity[-2:] == ['1', '1']
module = next(row for row in expected['rows'] if row['path'] == '/vendor/lib/modules/wmt_drv.ko')
assert shell('module-hash', 'sha256sum ' + module['path']).stdout.split()[0] == module['sha256']
shell('kernel-before', 'dmesg')
shell('remote-path-unused', 'test ! -e ' + remote)
copied = False
try:
    run('push', ['push', str(probe), remote])
    copied = True
    probe_hash = hashlib.sha256(probe.read_bytes()).hexdigest()
    assert shell('probe-hash', 'sha256sum ' + remote).stdout.split()[0] == probe_hash
    shell('probe-mode', 'chmod 755 ' + remote)
    executed = shell('probe-result', remote, timeout=90, check=False)
    response = json.loads(executed.stdout)
finally:
    if copied:
        shell('probe-cleanup', 'rm ' + remote)
final = shell('final-identity', 'cat /proc/sys/kernel/random/boot_id; '
              'cat /proc/sys/kernel/tainted; cat /proc/uptime').stdout.splitlines()
after = shell('kernel-after', 'dmesg').stdout
start, end = float(identity[3].split()[0]), float(final[2].split()[0])
interval = []
for line in after.splitlines():
    match = re.match(r'\[\s*(\d+\.\d+)\]', line)
    if match and start <= float(match[1]) <= end:
        interval.append(line)
faults = [line for line in interval if re.search(
    r'\bWARNING:|\bBUG:|\bOops:|\bUnable to handle|\bKernel panic', line)]
result = dict(status='PASS' if executed.returncode == 0 and response['status'] == 'PASS'
              and final[:2] == [identity[1], '0'] and interval and not faults else 'FAIL',
              build=build, boot_id=identity[1], incremental=identity[0],
              probe_sha256=probe_hash, module_sha256=module['sha256'], response=response,
              exit_code=executed.returncode, kernel_interval=[start, end],
              kernel_records=len(interval), recognized_fault_signatures=faults,
              final_identity=final)
(out / 'kernel-interval.txt').write_text('\n'.join(interval) + '\n')
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
raise SystemExit(result['status'] != 'PASS')
