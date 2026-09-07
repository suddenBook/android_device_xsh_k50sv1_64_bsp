"""Retain matching verification tools and the relative host dependencies they use."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys

trial = Path(__file__).resolve().parent
build, = sys.argv[1:]
assert build.isdigit()
stage_result = json.loads((trial / f'build{build}-stage-result.json').read_text())
assert stage_result['status'] == 'PASS'
stage = Path(stage_result['stage'])
source = trial / 'build-project'
destination = trial / f'build{build}-verification-project'
assert not destination.exists()
source_tools = source / 'work/k50sv1-bringup/tools'
target_tools = destination / 'work/k50sv1-bringup/tools'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_checked(src, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    expected = digest(src)
    assert digest(dst) == expected, dst
    return expected


files = []
for path in sorted(source_tools.rglob('*')):
    if not path.is_file() or '__pycache__' in path.parts:
        continue
    relative = path.relative_to(source_tools)
    files.append(dict(path=str(relative), sha256=copy_checked(path, target_tools / relative)))
assert files
(trial / f'build{build}-frozen-tools-manifest.json').write_text(
    json.dumps(dict(status='PASS', files=files), indent=2) + '\n')
host = []
for name in ['out/host/linux-x86/bin/simg2img', 'out/host/linux-x86/lib64/libc++.so']:
    sha = copy_checked(source / 'lineage-17.1' / name, destination / 'lineage-17.1' / name)
    host.append(dict(relative=name, sha256=sha))
(trial / f'build{build}-verification-host-tools.json').write_text(json.dumps(host, indent=2) + '\n')
baseline = Path('work/k50sv1-bringup/evidence/E-074-console-SHA256SUMS.txt')
copy_checked(source / baseline, destination / baseline)
log = trial / f'build{build}-preserved-stage-verification.log'
with log.open('xb') as output:
    result = subprocess.run([str(target_tools / 'verify-stage-contract.sh'), str(stage)],
                            stdout=output, stderr=subprocess.STDOUT, timeout=300,
                            env=dict(os.environ, K50SV1_BUILD_TIER='1', PYTHONDONTWRITEBYTECODE='1'))
summary = dict(status='PASS' if result.returncode == 0 else 'FAIL',
               exit_code=result.returncode, tools_copied=len(files), stage=str(stage),
               log_sha256=digest(log), preserved_project=str(destination))
(trial / f'build{build}-preserved-stage-result.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
raise SystemExit(result.returncode)
