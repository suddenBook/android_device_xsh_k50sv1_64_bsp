"""Bind the original vendor inventory to build19 without rewriting its old ledger."""
from pathlib import Path
import collections
import csv
import hashlib
import io
import json

trial = Path(__file__).resolve().parent
assert json.loads((trial / 'build19-stage-result.json').read_text())['status'] == 'PASS'
expected = json.loads((trial / 'build19-expected-installed.json').read_text())
assert expected['status'] == 'PASS'
output = trial / 'build19-adoption-ledger.tsv'
result_path = trial / 'build19-adoption-ledger.json'
assert not output.exists() and not result_path.exists()
original = trial.parents[1] / 'k50sv1-bringup/evidence/vendor-source-inventory-20260905/per-file-adoption.tsv'
reader = csv.DictReader(io.StringIO(original.read_text()), delimiter='\t')
fields = list(reader.fieldnames) + ['build19_installed_sha256']
rows = list(reader)
assert len(rows) == 506
row = next(row for row in rows if row['source_path'] == 'vendor/bin/wmt_launcher')
assert row['current_payload'] == 'retained_unchanged'
factory = trial / 'wmt-launcher-vendor-work/proprietary/vendor/bin/wmt_launcher'
factory_sha = hashlib.sha256(factory.read_bytes()).hexdigest()
assert factory_sha == row['sha256'] == expected['factory_launcher_sha256']
row.update(assessment='reviewed_paired_source_protocol',
           source_or_reason='MT6755 startup/firmware contract E-201; paired v2 source and reviews '
           'E-207/E-208; product/runtime successor E-209',
           current_payload='source_provider_factory_reference_retained',
           current_provider='device/xsh/k50sv1_64_bsp/wmt-launcher (build19)')
product = trial / 'build-project/lineage-17.1/out/target/product/k50sv1_64_bsp'
for row in rows:
    path = product / row['current_install_path']
    assert path.is_file(), row['current_install_path']
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    row['build19_installed_sha256'] = digest
    if row['current_payload'] == 'retained_unchanged':
        assert digest == row['sha256'], row['source_path']
launcher = next(row for row in rows if row['source_path'] == 'vendor/bin/wmt_launcher')
launcher_expected = next(row for row in expected['rows'] if row['path'] == '/vendor/bin/wmt_launcher')
assert launcher['build19_installed_sha256'] == launcher_expected['sha256'] != factory_sha
counts = dict(collections.Counter(row['current_payload'] for row in rows))
assert counts == dict(retained_unchanged=476, removed_paired_source_provider=29,
                      source_provider_factory_reference_retained=1)
with output.open('x') as stream:
    writer = csv.DictWriter(stream, fieldnames=fields, delimiter='\t', lineterminator='\n')
    writer.writeheader()
    writer.writerows(rows)
result = dict(status='PASS', rows=506, counts=counts, build_incremental=expected['incremental'],
              build_receipt_sha256=expected['receipt_sha256'],
              original_ledger_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),
              build19_ledger_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
              original_factory_launcher_retained_in_repository=True,
              original_factory_launcher_selected_for_product=False,
              source_launcher=launcher,
              scope='All original 506 inventory entries are mapped to actual clean product files. '
              '476 retained product payloads match their recorded original hashes. '
              'This is product provenance; real-feature claims remain in their runtime evidence.')
result_path.write_text(json.dumps(result, indent=2) + '\n')
print('PASS: 506 original files accounted for; 476 original product payloads unchanged, 30 source replacements')
