"""Preserve the full verifier's actual exit status and raw phase evidence."""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
import time

trial = Path(__file__).resolve().parent
phase, = sys.argv[1:]
assert phase in ('first-boot', 'normal-reboot')
early = trial / f'runtime/build19-{phase}-early/early-complete.json'
assert json.loads(early.read_text())['status'] == 'PASS'
assert json.loads((trial / 'runtime/build19-initial-home/result.json').read_text())['status'] == 'PASS'
tool = trial / 'build-project/work/k50sv1-bringup/tools/verify-post-flash.sh'
stage = trial / 'tier1-source-stack-20260907-wmt-command-v2-clang'
receipt = trial / 'source-stack-wmt-command-v2-clang-flash-receipt.txt'
capture = trial / f'runtime/build19-{phase}'
command = [str(tool), '0123456789ABCDEF', str(stage), str(receipt), str(capture),
           'cu-slot0-cmcc-slot1',
           'preflash-predecessor' if phase == 'first-boot' else 'lineage-predecessor']
if phase == 'normal-reboot':
    prior = trial / 'runtime/build19-first-boot/pstore/FAULT-SHA256SUMS'
    assert prior.is_file()
    command.append(str(prior))
log = trial / f'build19-{phase}-verify.log'
started = time.time()
with log.open('xb') as output:
    process = subprocess.run(command, env=dict(os.environ, ADB_LIBUSB='1',
                             PYTHONDONTWRITEBYTECODE='1'),
                             stdout=output, stderr=subprocess.STDOUT, timeout=900)
text = log.read_text(errors='replace')
summary = re.findall(r'== summary: (\d+) passed, (\d+) failed, (\d+) unread, '
                     r'(\d+) evidence-fatal, (\d+) informational ==', text)
result = dict(exit_code=process.returncode, phase=phase, command=command,
              started_epoch=started, finished_epoch=time.time(),
              verifier_sha256=hashlib.sha256(tool.read_bytes()).hexdigest(),
              log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
              capture=str(capture), summary=None)
if len(summary) == 1:
    result['summary'] = dict(zip(['passed', 'failed', 'unread', 'evidence_fatal',
                                 'informational'], map(int, summary[0])))
(trial / f'runtime/build19-{phase}-verify-result.json').write_text(
    json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2), flush=True)
raise SystemExit(process.returncode)
