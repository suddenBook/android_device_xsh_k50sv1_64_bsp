"""Retain early launcher logs across the normal reboot; restore the knob afterward."""
from pathlib import Path
import hashlib
import json
import os
import shlex
import subprocess

trial = Path(__file__).resolve().parent
out = trial / 'runtime/build19-normal-log-preparation'
out.mkdir(exist_ok=False)
expected = json.loads((trial / 'build19-expected-installed.json').read_text())
first = json.loads((trial / 'runtime/build19-first-boot-early/early-complete.json').read_text())
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')
key = 'persist.logd.size.main'


def shell(name, command):
    process = subprocess.run(adb + ['shell', command], env=env, capture_output=True, timeout=30)
    (out / (name + '.txt')).write_bytes(process.stdout + process.stderr)
    process.check_returncode()
    return process.stdout.decode()


identity = shell('identity', 'cat /proc/sys/kernel/random/boot_id; '
                 'getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted').splitlines()
assert identity == [first['identity'].splitlines()[0], expected['incremental'], '0']
original = shell('original-property', 'getprop ' + key).rstrip('\r\n')
state = dict(status='PREPARED', property=key, original=original, desired='64M',
             original_empty=original == '', first_boot_id=identity[0],
             limitation='An original absent/empty Android property can only be restored as an empty value.')
(out / 'result.json').write_text(json.dumps(state, indent=2) + '\n')
# Record the installed Q source contract without changing the product checkout.
android = trial / 'build-project/lineage-17.1'
sources = []
for relative in ['system/core/logd/README.property', 'system/core/liblog/properties.cpp',
                 'system/core/rootdir/init.rc']:
    path = android / relative
    sources.append(dict(path=relative, sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
state['source_contract'] = sources
try:
    shell('set-property', 'setprop ' + key + ' ' + shlex.quote(state['desired']))
    assert shell('prepared-property', 'getprop ' + key).strip() == state['desired']
except BaseException as error:
    state['status'] = 'FAIL'
    state['error'] = repr(error)
    try:
        shell('failed-prepare-restore', 'setprop ' + key + ' ' + shlex.quote(original))
        assert shell('failed-prepare-restored', 'getprop ' + key).rstrip('\r\n') == original
        state['failed_prepare_cleanup'] = 'PASS'
    except BaseException as cleanup_error:
        state['failed_prepare_cleanup'] = repr(cleanup_error)
    (out / 'result.json').write_text(json.dumps(state, indent=2) + '\n')
    raise
state['status'] = 'PASS'
(out / 'result.json').write_text(json.dumps(state, indent=2) + '\n')
print('PASS: main log buffer property prepared for the normal reboot; original value saved')
