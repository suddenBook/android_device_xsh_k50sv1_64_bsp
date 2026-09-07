"""Recompile frozen source launcher for Android API29 using the recorded target commands."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
trial = Path(__file__).resolve().parent
repository = trial / 'wmt-launcher-device-work'
source = repository / 'wmt-launcher'
baseline = trial / 'wmt-launcher-source-tests/android-compile-first'
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=repository).strip()
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repository, text=True).strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


rows = []
for arch in ['arm64', 'arm']:
    directory = out / arch
    directory.mkdir()
    command = json.loads((baseline / arch / 'command.json').read_text())
    command[command.index('-o') + 1] = str(directory / 'wmt_launcher')
    (directory / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    compiled = subprocess.run(command, capture_output=True)
    (directory / 'compile.log').write_bytes(compiled.stdout + compiled.stderr)
    if not compiled.returncode:
        elf = subprocess.run(['readelf', '-h', '-d', '-Ws', str(directory / 'wmt_launcher')], capture_output=True, check=True)
        (directory / 'elf.txt').write_bytes(elf.stdout + elf.stderr)
    rows.append(dict(arch=arch, exit_code=compiled.returncode,
                     artifacts={p.name: digest(p) for p in sorted(directory.iterdir()) if p.is_file()}))
result = dict(status='PASS' if all(r['exit_code'] == 0 for r in rows) else 'FAIL',
              device_revision=revision, rows=rows,
              source_sha256={str(p.relative_to(source)): digest(p) for p in sorted(source.rglob('*')) if p.is_file()},
              limitation='Standalone Android API29 linkage; only ARM64 selected in product; full clean Soong build and runtime remain required.')
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(result['status'] + ': final source ARM64 and ARM compilation/linkage', flush=True)
raise SystemExit(result['status'] != 'PASS')
