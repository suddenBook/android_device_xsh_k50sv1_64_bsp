"""Bind ordinary thermal callback execution to the normal boot's kernel stream."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
trial = Path(__file__).resolve().parent
out = trial / 'runtime/build19-thermal-background'
out.mkdir(exist_ok=False)
expected = json.loads((trial / 'build19-expected-installed.json').read_text())
early = json.loads((trial / 'runtime/build19-normal-reboot-early/early-complete.json').read_text())
boot_id = early['identity'].splitlines()[0]
module = next(row for row in expected['rows'] if row['path'] == '/vendor/lib/modules/wmt_drv.ko')
identity = subprocess.run(
    ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF', 'shell',
     'getprop ro.build.version.incremental; cat /proc/sys/kernel/random/boot_id; '
     'cat /proc/sys/kernel/tainted; sha256sum /vendor/lib/modules/wmt_drv.ko'],
    env=dict(os.environ, ADB_LIBUSB='1'), capture_output=True, check=True, timeout=30)
(out / 'identity.txt').write_bytes(identity.stdout + identity.stderr)
lines = identity.stdout.decode().splitlines()
assert lines[:3] == [expected['incremental'], boot_id, '0']
assert lines[3].split() == [module['sha256'], module['path']]
spec = importlib.util.spec_from_file_location('thermal_context', trial / 'wmt-thermal-read-probe/run.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
context = helper.save_source_context(trial / 'wmt-paired-batch-kernel-work', expected['kernel_revision'], out)
stream_path = trial / 'runtime/build19-normal-reboot-early/continuous-kmsg.txt'
stream = stream_path.read_bytes()
pattern = re.compile(r'wmt_dev_tm_temp_query:\[Thermal\] current_temp=0x([0-9a-fA-F]+)')
observed = [line for line in stream.decode(errors='replace').splitlines()
            if (match := pattern.search(line)) and int(match[1], 16) > 0]
(out / 'callback-lines.txt').write_text('\n'.join(observed) + '\n')
result = dict(status='PASS_OBSERVED_CALLBACK_EXECUTION' if observed else 'INCONCLUSIVE',
              boot_id=boot_id, kernel_revision=expected['kernel_revision'], module_sha256=module['sha256'],
              source_context=context, observed_nonzero_query_records=len(observed),
              caller_scope='Background thermal callbacks; not attributed to a particular sysfs read PID',
              source_stream=str(stream_path), source_stream_prefix_bytes=len(stream),
              source_stream_prefix_sha256=hashlib.sha256(stream).hexdigest(),
              callback_lines_sha256=hashlib.sha256((out / 'callback-lines.txt').read_bytes()).hexdigest(),
              source_excerpts_sha256=hashlib.sha256((out / 'source-excerpts.txt').read_bytes()).hexdigest(),
              limitations=['Ordinary callback execution only; no concurrent teardown or module unload claim',
                           'Sysfs read attribution remains separately reported',
                           'The continuous stream is closed and hashed separately before adoption'])
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(result['status'] + ': ' + str(len(observed)) + ' nonzero thermal callback records')
raise SystemExit(not observed)
