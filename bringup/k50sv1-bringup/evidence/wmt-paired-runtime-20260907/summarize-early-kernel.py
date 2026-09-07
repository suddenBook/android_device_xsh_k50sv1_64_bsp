from pathlib import Path
import hashlib
import json
import re
import sys

trial = Path(__file__).resolve().parent
build, phase = sys.argv[1:]
assert build.isdigit() and phase in ['first-boot', 'normal-reboot', 'radio-reboot']
directory = trial / f'runtime/build{build}-{phase}-early'
path = directory / 'continuous-kmsg.txt'
data = path.read_bytes()
records = []
for line in data.decode(errors='replace').splitlines():
    match = re.match(r'\d+,(\d+),(\d+),[^;]*;(.*)', line)
    if match:
        records.append((int(match[1]), int(match[2]), match[3]))
assert records
gaps = [(a[0], b[0]) for a, b in zip(records, records[1:]) if b[0] != a[0] + 1]
faults = [dict(sequence=n, seconds=t / 1e6, text=line) for n, t, line in records
          if re.search(r'\bWARNING:|\bBUG:|\bOops:|\bUnable to handle|\bKernel panic', line)]
swap = [dict(sequence=n, seconds=t / 1e6, text=line) for n, t, line in records
        if re.search(r'Adding \d+k swap on', line)]
result = dict(boot_id=(directory / 'identity.txt').read_text().splitlines()[0],
              sha256=hashlib.sha256(data).hexdigest(), records=len(records),
              first_sequence=records[0][0], last_sequence=records[-1][0],
              first_seconds=records[0][1] / 1e6, last_seconds=records[-1][1] / 1e6,
              gaps=gaps, recognized_fault_signatures=faults, swap_activation=swap,
              scope='Continuous captured kernel records and named signature checks; not an exhaustive fault oracle')
(trial / f'runtime/build{build}-{phase}-kernel-summary.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
raise SystemExit(bool(gaps or faults or records[0][0] != 0))
