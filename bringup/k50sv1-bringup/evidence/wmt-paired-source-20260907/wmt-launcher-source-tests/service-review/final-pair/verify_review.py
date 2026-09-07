#!/usr/bin/env python3
"""Bind the final read-only launcher/broker review to its exact sources."""
import ast
import hashlib
import json
from pathlib import Path
import runpy
import subprocess

TRIAL = Path('/home/desmond/Downloads/k50sv1_64_bsp/work/.capture-staging/source-replacement-20260905')
OUT = Path(__file__).resolve().parent
REVISIONS = {
    'launcher': ('wmt-launcher-device-work', '2cbfa92e64e2b01461de512e4feb2c5676406125'),
    'broker': ('wmt-command-v2-kernel-work', '857d2d0b238231ad931e342c6950c458dae99063'),
    'collector': ('wmt-fwlog-kernel-work', '75f4664c480ccbf64b764406776e8a3d88a3325b'),
}
COMMON = 'drivers/misc/mediatek/connectivity/source/common/common_main/'
FILES = {
    'launcher': ['wmt-launcher/' + name for name in (
        'main.c', 'protocol.c', 'protocol.h', 'include/linux/mtk_wmt_cmd.h',
        'firmware.c', 'firmware.h', 'patch.c', 'patch.h', 'Android.bp')],
    'broker': ['include/uapi/linux/mtk_wmt_cmd.h',
        'drivers/misc/mediatek/connectivity/common/wmt_build_in_adapter.c',
        COMMON + 'core/wmt_lib.c', COMMON + 'core/wmt_ctrl.c',
        COMMON + 'linux/wmt_dev.c', COMMON + 'platform/wmt_plat_alps.c'],
    'collector': [COMMON + 'linux/wmt_dbg.c', 'tools/testing/wmt-fwlog/run.py'],
}
FUNCTIONS = {
    ('launcher', 'wmt-launcher/main.c'): ['open_driver', 'check_chip', 'power_on',
        'set_firmware_log', 'stop_firmware_log', 'check_optional_controls',
        'send_frame', 'handle_command', 'command_loop', 'main'],
    ('launcher', 'wmt-launcher/protocol.c'): ['wmt_command_decode', 'wmt_reply_status', 'wmt_reply_list'],
    ('broker', COMMON + 'core/wmt_lib.c'): ['wmt_lib_cmd_finish', 'wmt_lib_cmd_expire',
        'wmt_lib_cmd_start', 'wmt_lib_cmd_disconnect', 'wmt_lib_cmd_shutdown',
        'wmt_lib_cmd_open', 'wmt_lib_cmd_close', 'wmt_lib_cmd_session',
        'wmt_lib_cancel_cmd', 'wmt_lib_send_cmd', 'wmt_lib_read_cmd',
        'wmt_lib_cmd_reply_prepare', 'wmt_lib_cmd_publish_rom', 'wmt_lib_write_cmd',
        'wmt_lib_poll_cmd', 'wmt_lib_get_rom_patch_info'],
    ('broker', COMMON + 'linux/wmt_dev.c'): ['wmt_dev_publish_patch_info',
        'wmt_dev_get_patch_info', 'WMT_unlocked_ioctl', 'WMT_compat_ioctl'],
    ('broker', COMMON + 'platform/wmt_plat_alps.c'): ['wmt_plat_set_dbg_mode'],
    ('collector', COMMON + 'linux/wmt_dbg.c'): ['wmt_dbg_fwinfor_trace_to', 'wmt_dbg_fwinfor_from_emi'],
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    return digest(path.read_bytes())


def git(repo, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=repo)


def record(path):
    return {'path': str(path), 'sha256': file_digest(path)}


def verify_integration(report, repositories, function):
    kernel = TRIAL / 'wmt-paired-batch-kernel-work'
    revision = '4192fb6ae88e057bb2abb0f464cf6b4cb64697de'
    assert git(kernel, 'rev-parse', 'HEAD').decode().strip() == revision
    assert not git(kernel, 'status', '--porcelain')
    for name in FILES['broker']:
        assert (kernel / name).read_bytes() == (repositories['broker'] / name).read_bytes()
    name = COMMON + 'linux/wmt_dbg.c'
    assert (kernel / name).read_bytes() == (repositories['collector'] / name).read_bytes()
    test = kernel / 'drivers/misc/mediatek/connectivity/source/common/test'
    tree = ast.parse((test / 'test_wmt_command_v2.py').read_text())
    groups = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'groups' for t in node.targets):
            groups = ast.literal_eval(node.value)
    assert groups
    paths = {'lib': COMMON + 'core/wmt_lib.c', 'dev': COMMON + 'linux/wmt_dev.c',
        'ctrl': COMMON + 'core/wmt_ctrl.c', 'util': 'mm/util.c',
        'adapter': 'drivers/misc/mediatek/connectivity/common/wmt_build_in_adapter.c'}
    summary = {'kernel_revision': revision, 'kernel_clean': True, 'host_runs': [],
        'complete_service_included': 'service_bridge.c includes the complete main.c with host syscall/property names',
        'ioctl_dispatch_scope': 'Unmodified relevant case blocks in a narrow dispatcher; HIF and power hardware are adapted.',
        'build18_blocking_findings': [], 'independent_test_rerun': False}
    for name in ['address-final', 'thread-final']:
        path = TRIAL / 'wmt-paired-integration-tests' / name / 'result.json'
        run = json.loads(path.read_text())
        assert run['revisions'] == {'kernel': revision, 'device': REVISIONS['launcher'][1]}
        assert run['status'] == 'PASS' and run['compile_exit_code'] == 0
        assert run['passed'] == run['total'] == 6
        for source, expected in run['kernel_source_sha256'].items():
            assert file_digest(kernel / source) == expected
        for source, expected in run['device_source_sha256'].items():
            assert file_digest(repositories['launcher'] / source) == expected
        for artifact, expected in run['harness_sha256'].items():
            assert file_digest(Path(artifact)) == expected
        for artifact, expected in run['artifacts'].items():
            assert file_digest(path.parent / artifact) == expected
        fixture = (path.parent / 'broker.c').read_text()
        bodies = []
        for group, names in groups.items():
            for symbol in names:
                body, line = function((kernel / paths[group]).read_text(), symbol)
                assert fixture.count(body) == 1
                bodies.append({'path': paths[group], 'symbol': symbol,
                    'start_line': line, 'sha256': digest(body.encode())})
        summary['host_runs'].append({**record(path), 'passed': 6, 'total': 6,
            'kernel_source_hashes_checked': len(run['kernel_source_sha256']),
            'device_source_hashes_checked': len(run['device_source_sha256']),
            'harness_hashes_checked': len(run['harness_sha256']),
            'artifact_hashes_checked': len(run['artifacts']),
            'complete_functions_byte_identity': bodies,
            'boundary': run['boundary']})
    harness = TRIAL / 'wmt-paired-integration-tests/service_bridge.c'
    before = harness.with_name('service_bridge-before-close-expectation.c')
    assert before.read_text().replace('assert(result == -ECANCELED);',
        'assert(result == -ECONNRESET);', 1) != harness.read_text()
    expected_change = ('if (is_mode("close-pending")) {\n'
                       '        assert(result == -ECANCELED);')
    assert before.read_text().replace(expected_change,
        expected_change.replace('-ECANCELED', '-ECONNRESET'), 1) == harness.read_text()
    summary['initial_fixture_correction'] = {'old': record(before), 'final': record(harness),
        'change': 'Only close-pending expectation changed from ECANCELED to ECONNRESET, matching wmt_lib_cmd_disconnect.',
        'initial_result': record(TRIAL / 'wmt-paired-integration-tests/address-first/result.json'),
        'production_changed': False}
    path = TRIAL / 'wmt-launcher-source-tests/android-compile-final/result.json'
    android = json.loads(path.read_text())
    assert android['status'] == 'PASS' and android['device_revision'] == REVISIONS['launcher'][1]
    for source, expected in android['source_sha256'].items():
        assert file_digest(repositories['launcher'] / 'wmt-launcher' / source) == expected
    for row in android['rows']:
        assert row['exit_code'] == 0
        for artifact, expected in row['artifacts'].items():
            assert file_digest(path.parent / row['arch'] / artifact) == expected
    summary['android_compile'] = {**record(path), 'architectures': [r['arch'] for r in android['rows']],
        'source_binary_command_log_hashes_checked': True, 'boundary': android['limitation']}
    path = TRIAL / 'wmt-paired-integration-tests/arm64-final/result.json'
    target = json.loads(path.read_text())
    assert target['status'] == 'PASS' and target['kernel_revision'] == revision
    for row in target['rows']:
        assert row['exit_code'] == 0 and file_digest(kernel / row['source']) == row['source_sha256']
        for field, hash_field in [('object', 'object_sha256'), ('command_file', 'command_sha256'), ('log', 'log_sha256')]:
            assert file_digest(Path(row[field])) == row[hash_field]
    summary['arm64_compile'] = {**record(path), 'passed_objects': len(target['rows']),
        'source_object_command_log_hashes_checked': True, 'boundaries': target['limitations']}
    report['paired_integration'] = summary


def main():
    report = {
        'status': 'PASS', 'new_findings_confidence_at_least_80': [],
        'scope': 'Independent final launcher and v2 broker source review; collector is a required separately reviewed dependency.',
        'revisions': {}, 'source_files': [], 'source_functions': [], 'verified_evidence': [],
        'resolved_initial_findings': [
            {'id': 'SVC1', 'status': 'resolved by all three pinned commits',
             'reason': 'Launcher repeats finite drains, joins the log worker before final disable, and kernel ioctl propagates collector errors.'},
            {'id': 'SVC2', 'status': 'resolved',
             'reason': 'Read-side EAGAIN and ETIMEDOUT continue with the current bound session; other transport failures stop the loop.'},
        ],
        'review_contracts': [
            'The exported and userspace UAPI headers are byte-identical; frame header/session sizes are 32, records are 264, ioctl is 0xc020a040.',
            'Startup binds before HIF/kill-clear/readiness/power; a separate power thread leaves command delivery runnable.',
            'One owner per open file description, built-in monotonic session IDs, per-session transaction IDs and expiry checks reject stale delivery and replies.',
            'The writer parses one private copy, checks identity and deadline under the broker mutex, publishes a complete cache under its lock, then wakes the producer.',
            'Normal records cover sequences 1..count; ROM permits zero records and optional types 0..4; existing accepted ROM records remain immutable.',
            'Launcher version properties publish only after a complete accepted write; stale writes do not publish.',
            'Legacy metadata setters are rejected on native and compat paths; the launcher exclusively uses tagged v2 lists/status replies.',
            'Firmware logging uses one finite collector snapshot per ioctl, and positive disable return 1 is accepted as success.',
            'Optional controls cache only successful state, retry unchanged requests after failure, reap failed workers before reuse, and retain final disable after failed replacement creation.',
            'Shutdown unbinds before joining the power worker and joins the log worker before final disable and file close.',
        ],
        'boundaries': [
            'This final review performed source inspection and evidence/hash verification; it did not rerun the already passing author suites.',
            'Recorded broker/userspace host integration and standalone target compiles were independently hash-checked; linked product build and handset adoption remain separate checks.',
            'Collector and firmware helper implementation were authored in this branch of work; their source identities are dependencies here, not claimed as an independent implementation audit.',
            'Target is the MT6755 little-endian SoC/BTIF product and its retained firmware inventory; synthetic ROM cases do not establish real ROM-file behavior.',
        ],
    }
    repositories = {}
    for label, (name, revision) in REVISIONS.items():
        repo = TRIAL / name
        assert git(repo, 'rev-parse', 'HEAD').decode().strip() == revision
        assert not git(repo, 'status', '--porcelain')
        repositories[label] = repo
        report['revisions'][label] = {'repository': str(repo), 'commit': revision, 'clean': True}
        for name in FILES[label]:
            data = (repo / name).read_bytes()
            assert git(repo, 'show', revision + ':' + name) == data
            destination = OUT / 'sources' / label / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            report['source_files'].append({'component': label, 'path': name,
                'sha256': digest(data), 'snapshot': str(destination.relative_to(OUT))})
    function = runpy.run_path(str(repositories['collector'] / 'tools/testing/wmt-fwlog/run.py'))['function']
    for (label, name), names in FUNCTIONS.items():
        source = (repositories[label] / name).read_text()
        for symbol in names:
            body, line = function(source, symbol)
            report['source_functions'].append({'component': label, 'path': name,
                'symbol': symbol, 'start_line': line, 'end_line': line + body.count('\n') - 1,
                'sha256': digest(body.encode())})
    left = repositories['launcher'] / 'wmt-launcher/include/linux/mtk_wmt_cmd.h'
    right = repositories['broker'] / 'include/uapi/linux/mtk_wmt_cmd.h'
    assert left.read_bytes() == right.read_bytes()
    report['uapi_byte_identity_sha256'] = file_digest(left)

    kernel_path = TRIAL / 'wmt-command-v2-tests/final-validation.json'
    kernel = json.loads(kernel_path.read_text())
    assert kernel['commit'] == REVISIONS['broker'][1]
    for name, expected in kernel['source_sha256'].items():
        assert file_digest(repositories['broker'] / name) == expected
    for check in kernel['checks']:
        assert file_digest(Path(check['result'])) == check['result_sha256']
    report['verified_evidence'].append({**record(kernel_path),
        'source_hashes_checked': len(kernel['source_sha256']), 'result_hashes_checked': len(kernel['checks'])})

    optional_path = TRIAL / 'wmt-launcher-source-tests/optional-retry/result.json'
    optional = json.loads(optional_path.read_text())
    assert optional['commit'] == REVISIONS['launcher'][1]
    report['verified_evidence'].append(record(optional_path))
    for name in ['candidate-address', 'candidate-thread']:
        path = optional_path.parent / name / 'result.json'
        run = json.loads(path.read_text())
        assert run['status'] == 'PASS' and run['passed'] == run['total']
        assert file_digest(path) == optional['verification'][name]['result_sha256']
        for name, expected in run['source_sha256'].items():
            assert file_digest(repositories['launcher'] / 'wmt-launcher' / name) == expected
        for name, expected in run['artifacts'].items():
            assert file_digest(path.parent / name) == expected
        report['verified_evidence'].append({**record(path), 'passed': run['passed'],
            'total': run['total'], 'source_hashes_checked': len(run['source_sha256']),
            'artifact_hashes_checked': len(run['artifacts'])})
    for name in ['host-final', 'host-tsan-final']:
        path = TRIAL / 'wmt-command-v2-tests' / name / 'result.json'
        run = json.loads(path.read_text())
        assert run['passed'] == run['total']
        for name, expected in run['source_sha256'].items():
            assert file_digest(repositories['broker'] / name) == expected
        assert file_digest(path.parent / 'fixture.c') == run['fixture_sha256']
        report['verified_evidence'].append({**record(path), 'passed': run['passed'],
            'total': run['total'], 'source_hashes_checked': len(run['source_sha256']),
            'fixture_hash_checked': True})
    initial = OUT.parent / 'review.json'
    report['initial_review'] = record(initial)
    report['collector_validation'] = record(TRIAL / 'wmt-fwlog-tests/final-validation.json')
    verify_integration(report, repositories, function)
    report['review_markdown'] = record(OUT / 'review.md')
    path = OUT / 'review.json'
    path.write_text(json.dumps(report, indent=2) + '\n')
    artifacts = [p for p in OUT.rglob('*') if p.is_file() and p.name != 'artifact-sha256.json']
    manifest = OUT / 'artifact-sha256.json'
    manifest.write_text(json.dumps({'files': [{'path': str(p.relative_to(OUT)),
        'sha256': file_digest(p)} for p in sorted(artifacts)]}, indent=2) + '\n')
    print(json.dumps({'status': 'PASS', 'review_sha256': file_digest(path),
        'artifact_sha256': file_digest(manifest), 'source_files': len(report['source_files']),
        'source_functions': len(report['source_functions'])}, indent=2))


if __name__ == '__main__':
    main()
