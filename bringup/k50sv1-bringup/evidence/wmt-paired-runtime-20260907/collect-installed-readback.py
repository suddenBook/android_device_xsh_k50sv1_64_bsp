"""Read back files against a frozen completed-build manifest."""
from pathlib import Path
import json
import os
import re
import subprocess
import sys

trial = Path(__file__).resolve().parent
build, phase = sys.argv[1:]
assert build.isdigit() and re.fullmatch(r'[a-z-]+', phase)
expected = json.loads((trial / f'build{build}-expected-installed.json').read_text())
out = trial / f'runtime/build{build}-{phase}-readback'
out.mkdir(exist_ok=False)
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')

def shell(command):
    run = subprocess.run(adb + ['shell', command], env=env, capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stderr
    return run.stdout

identity = shell('cat /proc/sys/kernel/random/boot_id; getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted')
(out / 'identity.txt').write_text(identity)
assert identity.splitlines()[1:] == [expected['incremental'], '0'], identity
for row in expected['rows']:
    assert re.fullmatch(r'/[A-Za-z0-9_./@+-]+', row['path'])
readback = shell('sha256sum ' + ' '.join(row['path'] for row in expected['rows']))
(out / 'sha256sum.txt').write_text(readback)
hashes = {line.split()[1]: line.split()[0] for line in readback.splitlines()}
rows = [{**row, 'readback_sha256': hashes.get(row['path']),
         'matches': hashes.get(row['path']) == row['sha256']} for row in expected['rows']]
result = dict(status='PASS' if all(row['matches'] for row in rows) else 'FAIL',
              boot_id=identity.splitlines()[0], receipt_sha256=expected['receipt_sha256'], rows=rows)
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(f"{result['status']}: {sum(row['matches'] for row in rows)}/{len(rows)} installed files")
raise SystemExit(result['status'] != 'PASS')
