"""Read the WMT thermal zone on the already verified build-19 normal boot."""
from pathlib import Path
import json
import subprocess

trial = Path(__file__).resolve().parent
normal = json.loads((trial / 'runtime/build19-normal-reboot-early/early-complete.json').read_text())
assert normal['status'] == 'PASS'
boot_id = normal['identity'].splitlines()[0]
subprocess.run([
    'python3', str(trial / 'wmt-thermal-read-probe/run.py'),
    '--build', '19', '--expected-manifest', str(trial / 'build19-expected-installed.json'),
    '--kernel-repo', str(trial / 'wmt-paired-batch-kernel-work'),
    '--output', str(trial / 'runtime/build19-thermal-read'),
    '--expected-boot-id', boot_id,
], check=True)
