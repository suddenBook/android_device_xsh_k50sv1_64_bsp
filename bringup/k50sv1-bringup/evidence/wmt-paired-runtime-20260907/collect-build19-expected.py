"""Bind handset readback paths to the completed clean stage and product output."""
from pathlib import Path
import hashlib
import json

trial = Path(__file__).resolve().parent
stage = trial / 'tier1-source-stack-20260907-wmt-command-v2-clang'
out = trial / 'build-project/lineage-17.1/out/target/product/k50sv1_64_bsp'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fields(path):
    values = [line.split('=', 1) for line in path.read_text().splitlines()]
    assert all(len(row) == 2 for row in values)
    result = dict(values)
    assert len(result) == len(values)
    return result


assert json.loads((trial / 'build19-stage-result.json').read_text())['status'] == 'PASS'
assert json.loads((trial / 'build19-process-result.json').read_text())['exit_code'] == 0
receipt_path = stage / 'K50SV1-BUILD-RECEIPT'
receipt = fields(receipt_path)
assert receipt['build.clean_output'] == 'true'
assert digest(receipt_path) == digest(out / receipt_path.name)
state_path = stage / receipt['source_state.file']
assert digest(state_path) == receipt['source_state.sha256']
state = fields(state_path)
inputs = json.loads((trial / 'build19-input-update.json').read_text())['inputs']
expected_kernel = next(row['revision'] for row in inputs if row['repository'] == 'lineage-17.1/kernel/xsh/k50sv1_64_bsp')
assert state['repo.kernel.head'] == expected_kernel
assert state['repo.kernel.dirty'] == 'false'

providers = json.loads((trial / 'build19-native-providers.json').read_text())
assert providers['status'] == 'PASS' and providers['native_file_count'] == 23
assert providers['build_receipt_sha256'] == digest(receipt_path)
rows = []
for provider in providers['native_providers']:
    path = '/' + provider['installed']
    assert digest(out / path.lstrip('/')) == provider['sha256']
    rows.append(dict(path=path, sha256=provider['sha256'], kind='native_source'))

baseline = json.loads((trial / 'build17-expected-installed.json').read_text())
for row in baseline['rows']:
    if row['kind'] == 'native_source':
        continue
    path = out / row['path'].lstrip('/')
    current = dict(row, sha256=digest(path))
    if row['kind'] == 'source_kernel_module':
        assert current['sha256'] == receipt['kernel.module.' + path.stem + '.installed_sha256']
    rows.append(current)
assert len(rows) == len({row['path'] for row in rows}) == 30
old = {row['path']: row for row in baseline['rows']}
launcher = json.loads((trial / 'runtime/build17-wmt-launcher-identity.json').read_text())
assert launcher['status'] == 'PASS' and launcher['original_elf_unchanged']
assert launcher['path'] == '/vendor/bin/wmt_launcher' and launcher['path'] not in old
old[launcher['path']] = dict(path=launcher['path'], sha256=launcher['sha256'], kind='factory_native')
assert set(old) == {row['path'] for row in rows}
changes = [dict(path=row['path'], before_sha256=old[row['path']]['sha256'],
                after_sha256=row['sha256'], kind=row['kind'])
           for row in rows if row['sha256'] != old[row['path']]['sha256']]
result = dict(status='PASS', incremental=receipt['build.incremental'],
              kernel_revision=state['repo.kernel.head'], receipt_sha256=digest(receipt_path),
              previous_native_files_identical_to_build17=all(
                  row['sha256'] == old[row['path']]['sha256'] for row in rows
                  if row['kind'] == 'native_source' and row['path'] != launcher['path']),
              new_native_source_paths=[launcher['path']],
              factory_launcher_sha256=launcher['sha256'],
              changes_from_build17=changes, rows=rows)
(trial / 'build19-expected-installed.json').write_text(json.dumps(result, indent=2) + '\n')
print(f"PASS: 30 expected installed hashes; {len(changes)} differ from build17", flush=True)
