"""Archive the measured paired WMT product/runtime result before source adoption."""
from pathlib import Path
import hashlib
import json
import shutil

trial = Path(__file__).resolve().parent
out = trial.parents[1] / 'k50sv1-bringup/evidence/wmt-paired-runtime-20260907'


def read(relative):
    return json.loads((trial / relative).read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


assert not out.exists()
inputs = read('build19-input-update.json')
expected = read('build19-expected-installed.json')
assert expected['kernel_revision'] == '4192fb6ae88e057bb2abb0f464cf6b4cb64697de'
assert expected['previous_native_files_identical_to_build17'] and len(expected['rows']) == 30
assert expected['new_native_source_paths'] == ['/vendor/bin/wmt_launcher']
ledger = read('build19-adoption-ledger.json')
assert ledger['status'] == 'PASS' and ledger['rows'] == 506
assert ledger['counts'] == dict(retained_unchanged=476, removed_paired_source_provider=29,
                                source_provider_factory_reference_retained=1)
assert ledger['build19_ledger_sha256'] == sha(trial / 'build19-adoption-ledger.tsv')
assert read('build19-process-result.json')['exit_code'] == 0
assert read('build19-stage-result.json')['status'] == 'PASS'
assert read('build19-preserved-stage-result.json')['status'] == 'PASS'
assert read('build19-flash-process-result.json')['exit_code'] == 0
source = trial.parents[1] / 'k50sv1-bringup/evidence/wmt-old-clang-20260907/source-validation.json'
assert sha(source) == inputs['source_validation_sha256']
validation = json.loads(source.read_text())
for component, revision in validation['revisions'].items():
    row = next(row for row in inputs['inputs']
               if row['repository'] == 'lineage-17.1/' + component + '/xsh/k50sv1_64_bsp')
    assert row['revision'] == revision and row['clean']
final = read('runtime/build19-final/result.json')
assert final['status'] == 'PASS' and final['taint'] == 0
assert final['temporary_probe_packages_removed'] and final['normal_log_property_restored']
assert final['source_launcher_exercise'] == 'PASS'
boot_ids, verifiers, startup = {}, {}, {}
for phase in ('first-boot', 'normal-reboot'):
    early = read(f'runtime/build19-{phase}-early/early-complete.json')
    assert early['status'] == 'PASS'
    boot_ids[phase] = early['identity'].splitlines()[0]
    stream = read(f'runtime/build19-{phase}-kernel-summary.json')
    path = trial / f'runtime/build19-{phase}-early/continuous-kmsg.txt'
    assert (path.parent / 'steps.json').is_file() and (path.parent / 'stop-streams').exists()
    assert stream['boot_id'] == boot_ids[phase] and stream['sha256'] == sha(path)
    assert stream['first_sequence'] == 0 and not stream['gaps']
    assert not stream['recognized_fault_signatures'] and len(stream['swap_activation']) == 1
    verifier = read(f'runtime/build19-{phase}-verify-result.json')
    summary = verifier['summary']
    assert summary['failed'] == summary['evidence_fatal'] == 0 and summary['passed'] > 0
    assert verifier['exit_code'] == (1 if summary['unread'] else 0)
    assert verifier['log_sha256'] == sha(trial / f'build19-{phase}-verify.log')
    verifiers[phase] = summary
    platform = read(f'runtime/build19-{phase}-platform-state/result.json')
    assert platform['status'] == 'PASS' and platform['boot_id'] == boot_ids[phase]
    assert platform['module_link_present'] is True
    assert platform['bound_device'] == '18070000.consys'
    assert platform['attributes_present'] == dict(bind=False, unbind=False)
    launcher = read(f'runtime/build19-source-launcher-{phase}/result.json')
    assert launcher['boot_id'] == boot_ids[phase]
    assert launcher['status'] in ('PASS', 'INCONCLUSIVE')
    assert launcher['checks']['capture_runtime']['status'] == 'PASS'
    startup[phase] = launcher['checks']['startup_attribution']
    consumption = read(f'runtime/build19-{phase}-patch-consumption/result.json')
    assert consumption['status'] == 'PASS_OBSERVED_KERNEL_PATCH_DOWNLOAD'
    assert consumption['boot_id'] == boot_ids[phase]
    assert consumption['kernel_revision'] == expected['kernel_revision']
    assert consumption['first_two_body_sizes_match_retained_firmware']
    sha_bytes = consumption['continuous_prefix_sha256']
    assert hashlib.sha256(path.read_bytes()[:consumption['continuous_prefix_bytes']]).hexdigest() == sha_bytes
assert len(set(boot_ids.values())) == 2 and final['boot_id'] == boot_ids['normal-reboot']
for phase in ('first-boot', 'normal-reboot', 'final'):
    data = read(f'runtime/build19-{phase}-readback/result.json')
    assert data['status'] == 'PASS'
    assert data['boot_id'] == boot_ids['first-boot' if phase == 'first-boot' else 'normal-reboot']
    assert data['receipt_sha256'] == expected['receipt_sha256']
    assert len(data['rows']) == 30 and all(row['matches'] for row in data['rows'])
exercise = read('runtime/build19-source-launcher-exercise/result.json')
assert exercise['status'] == 'PASS' and exercise['boot_id'] == final['boot_id']
assert exercise['checks']['exercise_runtime']['status'] == 'PASS'
assert exercise['cleanup']['status'] == 'PASS'
assert exercise['cleanup']['restored_property'] == exercise['original_fwlog_property']
radio = read('runtime/build19-radio-cycle/result.json')
assert radio['completed'] and radio['settings_restored']
assert not radio['new_faults'] and not radio['kernel_context_avcs']
gnss = read('runtime/build19-gnss/result.json')
for detail in ('idle-preparation', 'log-history-boundary', 'fixture-restoration'):
    assert read('runtime/build19-gnss/' + detail + '.json')['status'] == 'PASS'
isolation = read('runtime/build19-gnss-component-isolation/result.json')
assert isolation['status'] == isolation['cleanup']['status'] == 'PASS'
assert isolation['isolation']['status'] == 'PASS' and isolation['gnss_exit_code'] == 0
assert isolation['boot_id'] == final['boot_id'] and isolation['package_state_restored'] and isolation['roles_restored']
assert isolation['gnss_runner_sha256'] == sha(trial / 'run-build19-gnss.py')
assert final['gnss_component_fixture_restored']
assert 'started=true stopped=true' in gnss['summary'][0] and not gnss['new_faults']
assert read('runtime/build19-gnss/lifecycle.json')['status'] == 'PASS_PROBE_LIFECYCLE'
p2p = read('runtime/build19-p2p/result.json')
assert all(p2p[key] for key in ('probe_pass', 'p2p_ipv4_added', 'p2p_ipv4_removed'))
assert not p2p['new_faults']
adie = read('runtime/build19-adie-read/result.json')
assert adie['status'] == 'PASS'
assert adie['probe_sha256'] == read('runtime/build16-adie-read/result.json')['probe_sha256']
for result in (radio, gnss, p2p, adie):
    assert result['boot_id'] == final['boot_id']
thermal = read('runtime/build19-thermal-read/result.json')
assert thermal['status'] == 'PASS' and thermal['identity_after']['boot_id'] == final['boot_id']
background = read('runtime/build19-thermal-background/result.json')
assert background['status'] == 'PASS_OBSERVED_CALLBACK_EXECUTION'
assert background['boot_id'] == final['boot_id'] and background['observed_nonzero_query_records'] > 0
lines = (trial / 'runtime/build19-thermal-background/callback-lines.txt').read_text().splitlines()
continuous = (trial / 'runtime/build19-normal-reboot-early/continuous-kmsg.txt').read_text()
assert len(lines) == background['observed_nonzero_query_records']
assert all(line + '\n' in continuous for line in lines)
calibration = read('runtime/build19-final/calibration-firmware.json')
assert calibration['status'] == 'PASS' and len(calibration['files']) == 19
assert all(row['match'] for row in calibration['files'])
home = read('runtime/build19-initial-home/result.json')
assert home['setup_before'] == ['0', '0', '1'] and not home['manual_home_setter_called']
assert home['home_role_holders_before_setup'] == ['org.lineageos.setupwizard']
assert home['home_role_holders_after_setup'] == ['com.android.launcher3']
for relative in ('build19-launcher-product-policy.json',
                 'runtime/build19-initial-home/launcher-policy.json',
                 'runtime/build19-normal-reboot/launcher-policy.json',
                 'runtime/build19-final/launcher-policy.json'):
    assert read(relative)['status'] == 'PASS'

selected = [path for path in trial.glob('*19*') if path.is_file()]
selected += [trial / 'source-stack-wmt-command-v2-clang-flash-receipt.txt',
             trial / 'wmt-source-launcher-probe', trial / 'wmt-thermal-read-probe',
             trial / 'capture-wmt-platform-state.py', trial / 'run-wmt-adie-probe.py',
             trial / 'summarize-early-kernel.py', trial / 'collect-installed-readback.py',
             trial / 'preserve-build-verification-tools.py']
selected += list((trial / 'runtime').glob('build19-*'))
stage = Path(read('build19-stage-result.json')['stage'])
selected += [path for path in stage.iterdir() if path.is_file()]
artifacts, retained, seen = [], [], set()
out.mkdir()
for entry in selected:
    assert entry.exists(), entry
    for source_path in ([entry] if entry.is_file() else sorted(entry.rglob('*'))):
        if not source_path.is_file():
            continue
        relative = source_path.relative_to(trial)
        if relative in seen:
            continue
        seen.add(relative)
        row = dict(source=str(source_path), sha256=sha(source_path), bytes=source_path.stat().st_size)
        # Preserve large immutable logs and image/binary files at their current
        # paths; copy their complete hashes and every smaller raw result/source.
        if (source_path.suffix in ('.img', '.apk', '.o', '.so') or
                source_path.stat().st_size > 4 * 1024 * 1024):
            retained.append(row)
            continue
        destination = out / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_path, destination)
        assert sha(destination) == row['sha256']
        artifacts.append(dict(path=str(relative), **row))
summary = dict(status='PAIRED_SOURCE_BUILD_AND_RUNTIME_PASS', source_adoption_approved=True,
               incremental=expected['incremental'], revisions=validation['revisions'], boot_ids=boot_ids,
               raw_verifiers=verifiers, readback_files_per_phase=30,
               checked_readback_phases=['first-boot', 'normal-reboot', 'final'],
               changes_from_build17=expected['changes_from_build17'],
               startup_attribution=startup, source_launcher_exercise='PASS',
               source_bound_kernel_patch_downloads='PASS_BOTH_BOOT_PHASES',
               cleanup_status='PASS', calibration_firmware_unchanged=19,
               gnss_component_fixture_restored=True,
               original_vendor_inventory_entries=506, unchanged_retained_product_payloads=476,
               source_replacement_entries=30,
               sysfs_callback_attribution=thermal['callback_execution_evidence'],
               attributed_sysfs_callback_reads=thermal['attributed_callback_reads'],
               observed_background_thermal_records=background['observed_nonzero_query_records'],
               limits=['Raw full-verifier unread conditions remain recorded; no home-network IMS claim',
                       'GNSS callbacks do not establish positioning',
                       'No physical module unload, Enforcing mode, or Bluetooth audio measurement',
                       'No real ROM-patch files on this product; synthetic ROM tests remain host evidence',
                       'Existing mode logs prove driver writes/reads at their recorded instants, not an independent final MMIO read'],
               artifacts=artifacts, retained_artifacts=retained)
(out / 'runtime.json').write_text(json.dumps(summary, indent=2) + '\n')
print(f'PASS: archived {len(artifacts)} files and {len(retained)} retained artifact hashes')
