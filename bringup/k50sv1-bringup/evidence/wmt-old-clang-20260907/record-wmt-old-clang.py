"""Preserve failed build18 and the independently reviewed initializer-only repair."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

trial = Path(__file__).resolve().parent
root = trial.parents[2]
evidence = root / 'work/k50sv1-bringup/evidence'
out = evidence / 'wmt-old-clang-20260907'
assert not out.exists()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(path, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=path, text=True).strip()


previous_path = evidence / 'wmt-paired-source-20260907/source-validation.json'
previous = json.loads(previous_path.read_text())
assert previous['status'] == 'SOURCE_AND_REVIEW_PASS'
repositories = dict(kernel=trial / 'wmt-paired-batch-kernel-work',
                    device=trial / 'wmt-launcher-device-work',
                    vendor=trial / 'wmt-launcher-vendor-work')
revisions = {name: git(path, 'rev-parse', 'HEAD') for name, path in repositories.items()}
for name, path in repositories.items():
    assert not git(path, 'status', '--porcelain', '--untracked-files=all'), name
    if name != 'device':
        assert revisions[name] == previous['revisions'][name]
device = repositories['device']
assert git(device, 'rev-parse', 'HEAD^') == previous['revisions']['device']
assert git(device, 'diff', '--numstat', 'HEAD^', 'HEAD').splitlines() == [
    '1\t1\twmt-launcher/firmware.c', '3\t3\twmt-launcher/main.c']
target = trial / 'wmt-launcher-source-tests/old-clang-target'
compiled = json.loads((target / 'result.json').read_text())
replayed = json.loads((target / 'replay-final/result.json').read_text())
review_path = trial / 'wmt-launcher-source-tests/old-clang-review/final-review.json'
review = json.loads(review_path.read_text())
assert compiled['status'] == replayed['status'] == review['status'] == 'PASS'
assert review['findings_confidence_at_least_80'] == []
assert review['head_at_review'] == revisions['device']
assert review['original_failure_log_unchanged']
for row in json.loads((review_path.parent / 'final-artifact-sha256.json').read_text())['files']:
    assert sha(review_path.parent / row['path']) == row['sha256']
for path, digest in json.loads((target / 'artifact-sha256.json').read_text()).items():
    assert sha(target / path) == digest, path
assert len(compiled['rows']) == len(replayed['rows']) == 8
assert all(compiled['debug_stripped_object_identical'].values())
for row in compiled['rows']:
    name = Path(row['file']).stem
    assert row['exit_code'] == 0
    assert sha(target / row['label'] / (name + '.stripped.o')) == row['stripped_object_sha256']
    if row['label'] == 'candidate':
        assert sha(device / 'wmt-launcher' / row['file']) == row['source_sha256']
        assert (target / 'candidate' / (name + '.log')).stat().st_size == 0
failed = json.loads((trial / 'build18-process-result.json').read_text())
assert failed['exit_code'] == 1
assert json.loads((trial / 'build18-stage-result.json').read_text())['status'] == 'FAIL'
assert not (trial / 'build18-flash-process-result.json').exists()
changed = {}
for component, paths in previous['changed_file_sha256'].items():
    changed[component] = {}
    for path, digest in paths.items():
        source = repositories[component] / path
        current = sha(source) if source.exists() else None
        if component != 'device' or path not in ('wmt-launcher/main.c', 'wmt-launcher/firmware.c'):
            assert current == digest, (component, path)
        changed[component][path] = current

out.mkdir()
(out / 'initializer-compatibility.patch').write_text(git(device, 'diff', 'HEAD^', 'HEAD') + '\n')
selected = ['wmt-launcher-source-tests/old-clang-target', 'wmt-launcher-source-tests/old-clang-review',
            'build18-process-result.json', 'build18-stage-result.json', 'build18-input-update.json',
            'build18-prebuild-source-gates.log', 'build18-prebuild-source-state.txt',
            'build18-prebuild-repo-manifest.xml', 'supervise-build18.py', 'prepare-build18-stage.py',
            'freeze-build18-inputs.py', 'record-wmt-old-clang.py']
artifacts = []
retained = []
for relative in selected:
    path = trial / relative
    assert path.exists(), path
    paths = [path] if path.is_file() else sorted(path.rglob('*'))
    for source in paths:
        if not source.is_file() or '__pycache__' in source.parts:
            continue
        row = dict(source=str(source), sha256=sha(source), bytes=source.stat().st_size)
        if source.suffix == '.o':
            retained.append(row)
            continue
        destination = out / source.relative_to(trial)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        assert sha(destination) == row['sha256']
        artifacts.append(dict(path=str(destination.relative_to(out)), **row))
log = trial / 'full-build-18-clean.log'
retained.append(dict(source=str(log), sha256=sha(log), bytes=log.stat().st_size))
validation = dict(status='SOURCE_AND_REVIEW_PASS', revisions=revisions, changed_file_sha256=changed,
                  prior_evidence='E-207', prior_source_validation_sha256=sha(previous_path),
                  compatibility_review_sha256=sha(review_path),
                  compile_result_sha256=sha(target / 'result.json'),
                  replay_result_sha256=sha(target / 'replay-final/result.json'),
                  compatibility_scope='Exactly four nested zero initializers in two launcher C files; '
                  'all four Q target translation units compile with original Werror flags and '
                  'all four original/candidate debug-stripped objects are byte-identical.',
                  prior_functional_tests='E-207 results bind the parent device revision; not rerun. '
                  'The initializer-only change is covered by complete target object equivalence and independent review.',
                  full_clean_build=False, installed=False, runtime_pending=True,
                  failed_build=18, next_build=19, last_installed_build=17,
                  factory_launcher_sha256=previous['factory_launcher_sha256'],
                  uapi_sha256=previous['uapi_sha256'])
(out / 'source-validation.json').write_text(json.dumps(validation, indent=2) + '\n')
(out / 'archive.json').write_text(json.dumps(dict(status='PASS', artifacts=artifacts,
    retained_artifacts=retained, source_validation_sha256=sha(out / 'source-validation.json'),
    note='The full failed build log and compiled objects remain in their hashed staging locations. '
    'Original argv, diagnostics, source/header snapshots, dependency hashes and all reviews are copied.'), indent=2) + '\n')
print(f'PASS: build18 failure and reviewed build19 candidate archived; {len(artifacts)} copies', flush=True)
