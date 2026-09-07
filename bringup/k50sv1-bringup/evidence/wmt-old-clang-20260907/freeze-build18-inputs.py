"""Freeze the reviewed kernel, source launcher, vendor recipe and evidence for build18."""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import time

trial = Path(__file__).resolve().parent
project = trial / 'build-project'
root = trial.parents[2]
output = trial / 'build18-input-update.json'
assert not output.exists()


def git(repository, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=repository, text=True).strip()


def clean(repository):
    assert not git(repository, 'status', '--porcelain', '--untracked-files=all'), repository


status = subprocess.check_output(['systemctl', '--user', 'show', 'k50sv1-build18.service',
                                 '--property=ActiveState', '--value'], text=True).strip()
assert status not in ('active', 'activating')
validation_path = root / 'work/k50sv1-bringup/evidence/wmt-paired-source-20260907/source-validation.json'
validation = json.loads(validation_path.read_text())
assert validation['status'] == 'SOURCE_AND_REVIEW_PASS'
sources = dict(kernel=trial / 'wmt-paired-batch-kernel-work',
               device=trial / 'wmt-launcher-device-work', vendor=trial / 'wmt-launcher-vendor-work')
for component, repository in sources.items():
    clean(repository)
    assert git(repository, 'rev-parse', 'HEAD') == validation['revisions'][component]
    for path, digest in validation['changed_file_sha256'][component].items():
        if digest is None:
            assert not (repository / path).exists()
        else:
            assert hashlib.sha256((repository / path).read_bytes()).hexdigest() == digest
clean(root / 'work')
previous = json.loads((trial / 'build17-input-update.json').read_text())
for row in previous['inputs']:
    repository = project / row['repository']
    clean(repository)
    assert git(repository, 'rev-parse', 'HEAD') == row['revision'], row['repository']
preserved = json.loads((trial / 'build17-preserved-stage-result.json').read_text())
assert preserved['status'] == 'PASS'
changes = []
updates = [('work', root / 'work', git(root / 'work', 'rev-parse', 'HEAD'))]
updates.extend(('lineage-17.1/' + component + '/xsh/k50sv1_64_bsp', repository,
                validation['revisions'][component]) for component, repository in sources.items())
for relative, source, revision in updates:
    repository = project / relative
    before = git(repository, 'rev-parse', 'HEAD')
    subprocess.run(['git', 'fetch', '--no-tags', str(source), revision], cwd=repository, check=True)
    subprocess.run(['git', 'merge', '--ff-only', revision], cwd=repository, check=True)
    clean(repository)
    assert git(repository, 'rev-parse', 'HEAD') == revision
    changes.append(dict(repository=relative, previous=before, updated=revision, clean=True))
inputs = [dict(repository=row['repository'], revision=git(project / row['repository'], 'rev-parse', 'HEAD'), clean=True)
          for row in previous['inputs']]
output.write_text(json.dumps(dict(epoch=time.time(), changes=changes, inputs=inputs,
                  source_validation_sha256=hashlib.sha256(validation_path.read_bytes()).hexdigest()), indent=2) + '\n')
environment = dict(os.environ, K50SV1_BUILD_TIER='1', PYTHONDONTWRITEBYTECODE='1')
with (trial / 'build18-prebuild-source-gates.log').open('xb') as log:
    subprocess.run([str(project / 'work/k50sv1-bringup/tools/apply-upstream-patches.sh'), '--check'],
                   cwd=project, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
with (trial / 'build18-prebuild-source-state.txt').open('xb') as state:
    subprocess.run([str(project / 'work/k50sv1-bringup/tools/capture-build-input-state.sh'),
                    '--repo-manifest', str(trial / 'build18-prebuild-repo-manifest.xml')],
                   cwd=project, env=environment, stdout=state, check=True, timeout=300)
print('PASS: build18 reviewed inputs frozen and full source preflight passed', flush=True)
