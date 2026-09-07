#!/usr/bin/env python3
"""Verify the four-line compatibility diff and retained actual-Soong evidence."""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

TRIAL = Path('/home/desmond/Downloads/k50sv1_64_bsp/work/.capture-staging/source-replacement-20260905')
REPO = TRIAL / 'wmt-launcher-device-work'
SOURCE = REPO / 'wmt-launcher'
TARGET = TRIAL / 'wmt-launcher-source-tests/old-clang-target'
OUT = Path(__file__).resolve().parent
BASE = '2cbfa92e64e2b01461de512e4feb2c5676406125'
UNITS = ('main', 'firmware', 'protocol', 'patch')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def sha(path):
    return digest(path.read_bytes())


def git(*arguments):
    return subprocess.check_output(['git', *arguments], cwd=REPO)


def record(path):
    return {'path': str(path), 'sha256': sha(path)}


initial = json.loads((OUT / 'initial-review.json').read_text())
report = {'status': 'PASS', 'findings_confidence_at_least_80': [],
    'scope': 'Four initializer lines and actual old-Clang compile/code-generation equivalence only.',
    'base_revision': BASE, 'head_at_review': git('rev-parse', 'HEAD').decode().strip(),
    'git_status_at_review': git('status', '--porcelain').decode(),
    'initial_review': record(OUT / 'initial-review.json'),
    'source_files': [], 'changed_initializer_lines': 4, 'compile_rows': [],
    'semantics': 'The first aggregate subobject is now explicitly braced/designated; recursively omitted members retain zero values. Existing atomic_init calls and all subsequent operations are unchanged.',
    'boundaries': {'production_edited_by_reviewer': False, 'full_product_build': False,
        'compiler_executed_by_reviewer': False, 'independent_strip_executed': True,
        'new_functional_tests': False, 'old_failure_and_archive656_edited': False}}
expected_changes = {}
for row in initial['recommended_changes']:
    expected_changes.setdefault(row['path'], []).append((row['old'], row['new']))
for item in initial['sources']:
    path = item['path']
    old = git('show', BASE + ':' + path)
    assert digest(old) == item['sha256']
    expected = old.decode()
    for before, after in expected_changes.get(path, []):
        assert expected.count(before) == 1
        expected = expected.replace(before, after, 1)
    actual = (REPO / path).read_bytes()
    assert actual == expected.encode(), path
    destination = OUT / 'candidate-sources' / path.removeprefix('wmt-launcher/')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(actual)
    report['source_files'].append({'path': path, 'baseline_sha256': digest(old),
        'candidate_sha256': digest(actual), 'changed': old != actual,
        'snapshot': str(destination.relative_to(OUT))})
assert set(git('diff', '--name-only', BASE).decode().splitlines()) == set(expected_changes)
diff = git('diff', BASE, '--', *expected_changes)
(OUT / 'reviewed-change.diff').write_bytes(diff)
report['diff'] = record(OUT / 'reviewed-change.diff')

original = (TARGET / 'original-main-command.txt').read_text()
assert original.strip() == (OUT / 'original-main-soong-command.txt').read_text().strip()
arguments = shlex.split(original)
assert arguments.pop(0) == 'PWD=/proc/self/cwd'
assert arguments[0] == 'prebuilts/clang/host/linux-x86/clang-r353983c1/bin/clang'
report['original_soong_command'] = record(TARGET / 'original-main-command.txt')
report['command_comparison'] = {
    'candidate': 'All compiler arguments match original Soong order and values except source/include and output/dependency paths.',
    'baseline': 'Same remapping to the frozen baseline; the sole additional compiler option is -Wno-error=missing-braces.',
    'leading_environment_assignment': 'PWD=/proc/self/cwd is a shell environment assignment, not a compiler argument.',
    'working_directory': str(TRIAL / 'build-project/lineage-17.1'),
    'gnu11_vndk29_target_warnings_optimization_preserved': True}
target_result = json.loads((TARGET / 'result.json').read_text())
assert target_result['status'] == 'PASS' and len(target_result['rows']) == 8
strip_result = json.loads((OUT / 'independent-strip/result.json').read_text())
assert strip_result['all_four_stripped_objects_byte_identical']
strip_rows = {(r['label'], r['unit']): r for r in strip_result['rows']}
for row in target_result['rows']:
    label, unit = row['label'], Path(row['file']).stem
    assert label in ('baseline', 'candidate') and unit in UNITS
    assert row['exit_code'] == 0
    prefix = TARGET / 'baseline-source' if label == 'baseline' else SOURCE
    assert sha(prefix / row['file']) == row['source_sha256']
    if label == 'baseline':
        assert (prefix / row['file']).read_bytes() == git('show', BASE + ':wmt-launcher/' + row['file'])
    expected = [a.replace('device/xsh/k50sv1_64_bsp/wmt-launcher', str(prefix)) for a in arguments]
    expected[expected.index('-MF') + 1] = str(TARGET / label / (unit + '.d'))
    expected[expected.index('-o') + 1] = str(TARGET / label / (unit + '.o'))
    expected[-1] = str(prefix / row['file'])
    if label == 'baseline':
        expected.append('-Wno-error=missing-braces')
    command_path = TARGET / label / (unit + '.command.json')
    assert json.loads(command_path.read_text()) == expected, (label, unit)
    raw = TARGET / label / (unit + '.o')
    stripped = TARGET / label / (unit + '.stripped.o')
    independent = OUT / 'independent-strip' / (label + '-' + unit + '.o')
    raw_hash, stripped_hash = sha(raw), sha(stripped)
    assert stripped_hash == row['stripped_object_sha256']
    assert raw_hash == strip_rows[label, unit]['raw_sha256']
    assert stripped_hash == strip_rows[label, unit]['stripped_sha256']
    assert independent.read_bytes() == stripped.read_bytes()
    log = TARGET / label / (unit + '.log')
    text = log.read_text()
    warning_count = text.count('[-Wmissing-braces]')
    assert warning_count == (3 if unit == 'main' else 1 if unit == 'firmware' else 0) if label == 'baseline' else not text
    report['compile_rows'].append({'label': label, 'unit': unit, 'exit_code': 0,
        'source_sha256': row['source_sha256'], 'command': record(command_path),
        'raw_object': record(raw), 'stripped_object': record(stripped),
        'independent_strip_sha256': sha(independent), 'log': record(log),
        'missing_braces_warnings': warning_count})
report['object_comparison'] = {}
for unit in UNITS:
    before = TARGET / 'baseline' / (unit + '.stripped.o')
    after = TARGET / 'candidate' / (unit + '.stripped.o')
    assert before.read_bytes() == after.read_bytes()
    report['object_comparison'][unit] = {'debug_stripped_byte_identical': True,
        'stripped_sha256': sha(after),
        'raw_byte_identical': (TARGET / 'baseline' / (unit + '.o')).read_bytes() ==
                              (TARGET / 'candidate' / (unit + '.o')).read_bytes()}
report['raw_object_limit'] = 'Raw objects contain differing source/debug paths and are not byte-identical; all four complete objects become byte-identical after independently repeated --strip-debug.'
report['target_result'] = record(TARGET / 'result.json')
report['independent_strip'] = record(OUT / 'independent-strip/result.json')
provenance = json.loads((TARGET / 'provenance.json').read_text())
previous = json.loads((TARGET / 'provenance-before-objcopy-path-fix.json').read_text())
assert provenance['original_result'] == target_result
assert provenance['objcopy'] == '/usr/bin/llvm-objcopy'
assert {k for k in set(provenance) | set(previous) if provenance.get(k) != previous.get(k)} == {
    'objcopy', 'external_dependencies', 'replay_first_failure'}
assert [r for r in provenance['external_dependencies'] if r not in previous['external_dependencies']] == [
    {'path': '/usr/bin/llvm-objcopy', 'sha256': sha(Path('/usr/bin/llvm-objcopy'))}]
assert all(r in provenance['external_dependencies'] for r in previous['external_dependencies'])
for dependency in provenance['external_dependencies']:
    assert sha(Path(dependency['path'])) == dependency['sha256']
replay = {'runner': record(TARGET / 'replay.py'), 'provenance': record(TARGET / 'provenance.json'),
    'external_dependencies_verified': len(provenance['external_dependencies']),
    'preserved_inputs': [], 'rows': []}
generated = Path(provenance['generated_header_directory'])
for directory in ('baseline-source', 'candidate-source', 'generated-include'):
    for path in sorted((TARGET / directory).rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(TARGET / directory)
        data = path.read_bytes()
        if directory == 'baseline-source':
            assert data == git('show', BASE + ':wmt-launcher/' + str(relative))
        elif directory == 'candidate-source':
            assert data == (SOURCE / relative).read_bytes()
        else:
            assert data == (generated / relative).read_bytes()
        replay['preserved_inputs'].append(record(path))
replay_result = json.loads((TARGET / 'replay-final/result.json').read_text())
assert replay_result['status'] == 'PASS' and len(replay_result['rows']) == 8
for row in replay_result['rows']:
    label, unit = row['label'], Path(row['file']).stem
    assert row['exit_code'] == 0 and row['original_object_matches']
    original = json.loads((TARGET / label / (unit + '.command.json')).read_text())
    expected = [a.replace(provenance['source_directories'][label], str(TARGET / (label + '-source')))
        .replace(provenance['generated_header_directory'], str(TARGET / 'generated-include')) for a in original]
    for flag, suffix in (('-o', '.o'), ('-MF', '.d')):
        expected[expected.index(flag) + 1] = str(TARGET / 'replay-final' / label / (unit + suffix))
    command = TARGET / 'replay-final' / label / (unit + '.command.json')
    assert json.loads(command.read_text()) == expected
    raw = TARGET / 'replay-final' / label / (unit + '.o')
    stripped = TARGET / 'replay-final' / label / (unit + '.stripped.o')
    assert sha(stripped) == row['stripped_object_sha256']
    assert stripped.read_bytes() == (TARGET / label / (unit + '.stripped.o')).read_bytes()
    replay['rows'].append({'label': label, 'unit': unit, 'command': record(command),
        'raw_object': record(raw), 'stripped_object': record(stripped),
        'log': record(TARGET / 'replay-final' / label / (unit + '.log'))})
replay['result'] = record(TARGET / 'replay-final/result.json')
replay['first_attempt'] = {'provenance': record(TARGET / 'provenance-before-objcopy-path-fix.json'),
    'artifacts': [record(p) for p in sorted((TARGET / 'replay-first').rglob('*')) if p.is_file()],
    'explanation': 'The first replay used the Q-bundled objcopy and stopped on its stripped-object hash difference; selecting the actual original /usr/bin/llvm-objcopy changes only postprocessing, not compilation.',
    'independent_confirmation': record(OUT / 'independent-strip/replay-first-normalization.json')}
normalization = json.loads((OUT / 'independent-strip/replay-first-normalization.json').read_text())
assert sha(Path(normalization['raw_source'])) == normalization['raw_sha256']
assert sha(OUT / 'independent-strip/replay-first-main.o') == normalization['normalized_sha256']
assert normalization['normalized_sha256'] == report['object_comparison']['main']['stripped_sha256']
replay['reviewer_executed_replay'] = False
report['preserved_source_header_replay'] = replay
assert sha(Path(initial['build_failure']['log'])) == initial['build_failure']['sha256']
report['original_failure_log_unchanged'] = True
report['review_markdown'] = record(OUT / 'final-review.md')
path = OUT / 'final-review.json'
path.write_text(json.dumps(report, indent=2) + '\n')
manifest_path = OUT / 'final-artifact-sha256.json'
files = [p for p in OUT.rglob('*') if p.is_file() and p != manifest_path]
manifest_path.write_text(json.dumps({'files': [{'path': str(p.relative_to(OUT)),
    'sha256': sha(p)} for p in sorted(files)]}, indent=2) + '\n')
print(json.dumps({'status': 'PASS', 'review_sha256': sha(path),
    'artifact_sha256': sha(manifest_path), 'source_files': len(report['source_files']),
    'compile_rows': len(report['compile_rows']), 'identical_object_pairs': 4}, indent=2))
