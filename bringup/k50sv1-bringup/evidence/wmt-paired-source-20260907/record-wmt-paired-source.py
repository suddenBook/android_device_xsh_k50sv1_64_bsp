"""Verify and archive the reviewed build18 source pair before the product freeze."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

trial = Path(__file__).resolve().parent
root = trial.parents[2]
work = root / 'work/k50sv1-bringup'
out = work / 'evidence/wmt-paired-source-20260907'
assert not out.exists()
repositories = dict(kernel=trial / 'wmt-paired-batch-kernel-work',
                    device=trial / 'wmt-launcher-device-work',
                    vendor=trial / 'wmt-launcher-vendor-work')
revisions = dict(kernel='4192fb6ae88e057bb2abb0f464cf6b4cb64697de',
                 device='2cbfa92e64e2b01461de512e4feb2c5676406125',
                 vendor=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repositories['vendor'], text=True).strip())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(relative):
    return json.loads((trial / relative).read_text())


for name, repository in repositories.items():
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=repository).strip()
    assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repository, text=True).strip() == revisions[name]
broker = load('wmt-command-v2-tests/final-validation.json')
for path, sha in broker['source_sha256'].items():
    assert digest(repositories['kernel'] / path) == sha
for row in broker['checks']:
    assert digest(Path(row['result'])) == row['result_sha256']
collector = load('wmt-fwlog-tests/final-validation.json')
for row in collector['changed_files']:
    assert digest(repositories['kernel'] / row['path']) == row['sha256']
for row in collector['host_runs']:
    assert digest(Path(row['path'])) == row['sha256']
optional = load('wmt-launcher-source-tests/optional-retry/result.json')
assert optional['status'] == 'PASS' and optional['commit'] == revisions['device']
for path, sha in optional['owned_source_sha256'].items():
    assert digest(repositories['device'] / path) == sha
for row in optional['verification'].values():
    assert digest(Path(row['result_path'])) == row['result_sha256']
for name, count, key in [('patch-first', 17, 'source_sha256'), ('protocol-second', 18, 'sources')]:
    data = load('wmt-launcher-source-tests/' + name + '/result.json')
    assert data['passed'] == data['total'] == count
    for path, sha in data[key].items():
        assert digest(repositories['device'] / 'wmt-launcher' / path) == sha
firmware = load('wmt-launcher-source-tests/firmware-validation.json')
assert firmware['test_result']['passed'] == 60 and firmware['test_result']['failed'] == 0
assert digest(Path(firmware['test_result']['path'])) == firmware['test_result']['sha256']
for row in firmware['owned_sources']:
    assert digest(Path(row['path'])) == row['sha256']
pair_review_path = 'wmt-launcher-source-tests/service-review/final-pair/review.json'
pair_review = load(pair_review_path)
assert digest(trial / pair_review_path) == '0d55d2efccf11fbaa0b9918f2755b38acc74ab637bfff33e611ef1e4b36ee256'
assert pair_review['status'] == 'PASS' and not pair_review['new_findings_confidence_at_least_80']
for row in pair_review['source_files']:
    repo = repositories['device' if row['component'] == 'launcher' else 'kernel']
    assert digest(repo / row['path']) == row['sha256']
collector_review_path = 'wmt-fwlog-tests/independent-review/result.json'
collector_review = load(collector_review_path)
assert digest(trial / collector_review_path) == '54c5dd16f20e1c06982aa40f7408d6e9e15eec45d3947d74b268a93c5150297f'
assert collector_review['status'] == 'PASS'
assert collector_review['findings'] == []
for path, sha in collector_review['review_artifacts_sha256'].items():
    assert digest(trial / 'wmt-fwlog-tests/independent-review' / path) == sha
assert collector_review['extra_tests']['passed'] == collector_review['extra_tests']['total'] == 4
for name in ['address-final', 'thread-final']:
    data = load('wmt-paired-integration-tests/' + name + '/result.json')
    assert data['status'] == 'PASS' and data['passed'] == data['total'] == 6
    assert data['revisions'] == {key: revisions[key] for key in ['kernel', 'device']}
    for component in ['kernel', 'device']:
        for path, sha in data[component + '_source_sha256'].items():
            assert digest(repositories[component] / path) == sha
    for path, sha in data['artifacts'].items():
        assert digest(trial / 'wmt-paired-integration-tests' / name / path) == sha
compiled = load('wmt-paired-integration-tests/arm64-final/result.json')
assert compiled['status'] == 'PASS' and compiled['kernel_revision'] == revisions['kernel']
assert len(compiled['rows']) == 9
for row in compiled['rows']:
    assert digest(repositories['kernel'] / row['source']) == row['source_sha256']
    assert digest(Path(row['object'])) == row['object_sha256']
android = load('wmt-launcher-source-tests/android-compile-final/result.json')
assert android['status'] == 'PASS' and android['device_revision'] == revisions['device']
for path, sha in android['source_sha256'].items():
    assert digest(repositories['device'] / 'wmt-launcher' / path) == sha

# Only the recipe drops the factory launcher; factory evidence bytes remain.
factory = repositories['vendor'] / 'proprietary/vendor/bin/wmt_launcher'
assert digest(factory) == '70b5224af4276eef4a27a405919e5a147b24739569b3a24f5ee1cb8d3cd9a2a7'
vendor_diff = subprocess.check_output(['git', 'diff', 'af72cc5', revisions['vendor']], cwd=repositories['vendor'], text=True)
assert '-    vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/wmt_launcher:$(TARGET_COPY_OUT_VENDOR)/bin/wmt_launcher \\' in vendor_diff

selected = [
    'wmt-command-v2-design', 'wmt-command-v2-tests/final-validation.json',
    'wmt-command-v2-tests/host-final', 'wmt-command-v2-tests/host-tsan-final',
    'wmt-command-v2-tests/init-first', 'wmt-command-v2-tests/shutdown-first',
    'wmt-command-v2-tests/callback-first', 'wmt-command-v2-tests/legacy-second',
    'wmt-command-v2-tests/arm64-final', 'wmt-command-v2-tests/uapi-layout',
    'wmt-fwlog-tests/final-validation.json', 'wmt-fwlog-tests/artifact-sha256.json',
    'wmt-fwlog-tests/second-large-address', 'wmt-fwlog-tests/first-small-address',
    'wmt-fwlog-tests/first-small-thread', 'wmt-fwlog-tests/baseline-small-address',
    'wmt-fwlog-tests/arm64-first', 'wmt-fwlog-tests/independent-review',
    'wmt-fwlog-tests/fwlog-collector.patch',
    'wmt-launcher-source-tests/patch-first', 'wmt-launcher-source-tests/protocol-second',
    'wmt-launcher-source-tests/firmware-validation.json', 'wmt-launcher-source-tests/firmware-contract.json',
    'wmt-launcher-source-tests/firmware-artifact-sha256.json', 'wmt-launcher-source-tests/firmware-first-address',
    'wmt-launcher-source-tests/firmware-run.py', 'wmt-launcher-source-tests/firmware-discovery.patch',
    'wmt-launcher-source-tests/optional-retry', 'wmt-launcher-source-tests/service-review',
    'wmt-launcher-source-tests/android-compile-final', 'wmt-paired-integration-tests',
    'compile-wmt-integrated-batch.py', 'compile-launcher-android.py', 'record-wmt-paired-source.py',
]
allowed = {'.json', '.md', '.py', '.c', '.h', '.patch', '.log', '.txt', '.stdout', '.stderr'}
artifacts = []
out.mkdir()
for relative in selected:
    path = trial / relative
    assert path.exists(), path
    candidates = [path] if path.is_file() else sorted(path.rglob('*'))
    for source_path in candidates:
        if not source_path.is_file() or source_path.suffix not in allowed or '__pycache__' in source_path.parts:
            continue
        destination = out / source_path.relative_to(trial)
        if destination.exists():
            assert digest(destination) == digest(source_path)
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination)
        assert digest(destination) == digest(source_path)
        artifacts.append(dict(path=str(destination.relative_to(out)), source=str(source_path),
                              bytes=destination.stat().st_size, sha256=digest(destination)))

changed = {}
canonical = dict(kernel=root / 'lineage-17.1/kernel/xsh/k50sv1_64_bsp',
                 device=root / 'lineage-17.1/device/xsh/k50sv1_64_bsp',
                 vendor=root / 'lineage-17.1/vendor/xsh/k50sv1_64_bsp')
for component, repository in repositories.items():
    base = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=canonical[component], text=True).strip()
    names = subprocess.check_output(['git', 'diff', '--name-only', base, revisions[component]], cwd=repository, text=True).splitlines()
    changed[component] = {name: digest(repository / name) if (repository / name).exists() else None for name in names}
source_validation = dict(status='SOURCE_AND_REVIEW_PASS', revisions=revisions,
                         changed_file_sha256=changed, factory_launcher_sha256=digest(factory),
                         uapi_sha256=broker['uapi_sha256'],
                         review_sha256={pair_review_path: digest(trial / pair_review_path),
                                        collector_review_path: digest(trial / collector_review_path)},
                         results=dict(broker_address=74, broker_thread=5, lifecycle=61,
                                      decoder=17, codec=18, firmware=60, service_address=35, service_thread=17,
                                      fwlog_address=52, fwlog_thread=3, fwlog_independent_address=4,
                                      paired_address=6, paired_thread=6,
                                      arm64_kernel_objects=9, android_architectures=2),
                         installed=False, full_clean_build=False, runtime_pending=True,
                         owner_fix_evidence='E-206', limitations=['Host adapters do not establish hardware scheduling or radio operation',
                           'ROM firmware cases use synthetic headers; product retains no ROM files',
                           'The v2 kernel and launcher must be installed as a pair'])
(out / 'source-validation.json').write_text(json.dumps(source_validation, indent=2) + '\n')
(out / 'archive.json').write_text(json.dumps(dict(status='PASS', artifacts=artifacts,
                 source_validation_sha256=digest(out / 'source-validation.json'),
                 note='Text, source, commands and raw diagnostics are archived byte-for-byte. Compiled objects/binaries and original firmware stay in their hashed staging or vendor locations.'), indent=2) + '\n')
print('PASS: reviewed source pair and ' + str(len(artifacts)) + ' artifact copies archived', flush=True)
