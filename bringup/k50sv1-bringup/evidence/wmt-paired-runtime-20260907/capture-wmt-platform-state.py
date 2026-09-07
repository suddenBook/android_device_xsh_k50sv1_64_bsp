"""Read the bound WMT platform device and its driver attributes without changing them."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', required=True, type=int, choices=[16, 17, 18, 19])
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--expected-boot-id', required=True)
args = parser.parse_args()
trial = Path(__file__).resolve().parent
manifest = trial / f'build{args.build}-expected-installed.json'
expected = json.loads(manifest.read_text())
assert expected['status'] == 'PASS'
module = next(row for row in expected['rows'] if row['path'] == '/vendor/lib/modules/wmt_drv.ko')
args.output.mkdir(parents=True, exist_ok=False)
records = []


def capture(name, command):
    run = subprocess.run(
        ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF', 'shell', command],
        env=dict(os.environ, ADB_LIBUSB='1'), capture_output=True, timeout=30)
    (args.output / (name + '.txt')).write_bytes(run.stdout)
    (args.output / (name + '.stderr.txt')).write_bytes(run.stderr)
    records.append(dict(name=name, command=command, exit_code=run.returncode,
                        stdout_sha256=hashlib.sha256(run.stdout).hexdigest(),
                        stderr_sha256=hashlib.sha256(run.stderr).hexdigest()))
    run.check_returncode()
    return run.stdout.decode().splitlines()


identity_command = ('getprop ro.build.version.incremental; cat /proc/sys/kernel/random/boot_id; '
                    'cat /proc/sys/kernel/tainted; getprop sys.boot_completed')
identity = capture('identity-before', identity_command)
assert identity == [expected['incremental'], args.expected_boot_id, '0', '1']
hashed = capture('module-hash', 'sha256sum ' + shlex.quote(module['path']))
assert len(hashed) == 1 and hashed[0].split() == [module['sha256'], module['path']]
loaded = capture('modules', 'cat /proc/modules')
assert len([row for row in loaded if row.startswith('wmt_drv ') and ' Live ' in row]) == 1
driver = '/sys/bus/platform/drivers/mtk_wmt'
capture('driver-listing', 'ls -l ' + driver)
state = capture('driver-state', '''driver=/sys/bus/platform/drivers/mtk_wmt
for item in "$driver"/*; do
    if [ -L "$item" ] && [ -L "$item/driver" ]; then
        printf 'bound\t%s\t%s\n' "${item##*/}" "$(readlink -f "$item/driver")"
    fi
done
for attribute in bind unbind; do
    if [ -e "$driver/$attribute" ]; then present=1; else present=0; fi
    printf 'attribute\t%s\t%s\n' "$attribute" "$present"
done
readlink -f "$driver/module"
''')
assert state.count('bound\t18070000.consys\t' + driver) == 1
bound = [row for row in state if row.startswith('bound\t')]
assert len(bound) == 1
module_link_present = '/sys/module/wmt_drv' in state
attributes = {row.split('\t')[1]: row.split('\t')[2] == '1'
              for row in state if row.startswith('attribute\t')}
assert attributes == dict(bind=args.build == 16, unbind=args.build == 16)
assert capture('identity-after', identity_command) == identity
result = dict(status='PASS' if module_link_present else 'FAIL',
              module_link_present=module_link_present,
              finding=None if module_link_present else 'platform_driver_probe in the built-in core overwrites driver.owner with NULL',
              build=args.build, boot_id=identity[1], incremental=identity[0], taint=0,
              kernel_revision=expected['kernel_revision'], module_sha256=module['sha256'],
              expected_manifest_sha256=hashlib.sha256(manifest.read_bytes()).hexdigest(),
              script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              bound_device='18070000.consys', driver=driver, attributes_present=attributes,
              commands=records, limitation='Read-only binding and attribute evidence; no probe failure or unload is exercised.')
(args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({key: result[key] for key in ['status', 'build', 'boot_id', 'bound_device', 'attributes_present']}))

raise SystemExit(0 if module_link_present else 1)
