"""Bind the WMT platform observation to one completed build-19 boot phase."""
import argparse
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phase', choices=['first-boot', 'normal-reboot'])
args = parser.parse_args()
trial = Path(__file__).resolve().parent
early = json.loads((trial / f'runtime/build19-{args.phase}-early/early-complete.json').read_text())
assert early['status'] == 'PASS'
subprocess.run([
    'python3', str(trial / 'capture-wmt-platform-state.py'), '--build', '19',
    '--output', str(trial / f'runtime/build19-{args.phase}-platform-state'),
    '--expected-boot-id', early['identity'].splitlines()[0],
], check=True)
