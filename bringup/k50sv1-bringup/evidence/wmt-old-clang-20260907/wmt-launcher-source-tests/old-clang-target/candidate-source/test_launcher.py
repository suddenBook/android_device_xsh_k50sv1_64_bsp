#!/usr/bin/env python3
"""Run the actual MT6755 service against bounded host device/property adapters."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

CASES = [
    'full-service', 'late-driver', 'chip-fallback', 'unsupported-chip', 'open-denied',
    'old-kernel', 'bad-bind-limits', 'hif-failure', 'kill-failure', 'ready-failure',
    'thread-failure', 'power-default', 'power-retry', 'power-exhausted', 'stale-reply',
    'short-write', 'bad-request', 'read-failure', 'write-failure', 'write-interrupted',
    'poll-interrupted', 'optional-controls', 'read-expired', 'fw-late-start', 'fw-inflight-stop',
    'dump-retry-same', 'dump-retry-repeated', 'fw-enable-retry', 'fw-repeated-failure',
    'fw-disable-after-failure', 'fw-retry-toggle', 'fw-retry-create-failure',
    'fw-retry-shutdown-create-failure', 'fw-retry-late-start', 'fw-disable-retry',
]
FIRMWARE = {
    'ROMv2_lm_patch_1_0_hdr.bin': '7a58e99fdcab239f133be92da999f8733878617191bb1f5caa1096d91ad8e1a2',
    'ROMv2_lm_patch_1_1_hdr.bin': 'cb7ba98c5c73705eb03a6ec11b78a3b1cce6069132b1f267d50079f2b1b594fd',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firmware-dir', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--sanitizer', choices=['address', 'thread'], default='address')
    parser.add_argument('--case', choices=CASES, action='append')
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    firmware = args.firmware_dir.resolve()
    for name, sha in FIRMWARE.items():
        if digest(firmware / name) != sha:
            raise ValueError('Firmware input hash mismatch: ' + name)
    if list(firmware.glob('soc1_0_ram*')):
        raise ValueError('This service fixture expects the retained inventory with no ROM files')
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sanitizer = 'address,undefined' if args.sanitizer == 'address' else 'thread'
    compiler = [
        'clang', '-std=gnu11', '-D_GNU_SOURCE', '-g', '-O1', '-Wall', '-Wextra', '-Werror',
        '-fno-omit-frame-pointer', '-no-pie', '-fsanitize=' + sanitizer, '-pthread',
        '-I' + str(source / 'include'), '-I' + str(source / 'test-include'),
        *[str(source / name) for name in ['test_launcher.c', 'protocol.c', 'patch.c', 'firmware.c']],
        '-o', str(out / 'test'),
    ]
    sources = ['main.c', 'protocol.c', 'protocol.h', 'patch.c', 'patch.h', 'firmware.c',
               'firmware.h', 'test_launcher.c', 'test_launcher.py', 'include/linux/mtk_wmt_cmd.h',
               'test-include/android/log.h', 'test-include/cutils/properties.h']
    result = dict(compiler_argv=compiler, sanitizer=sanitizer,
                  source_sha256={name: digest(source / name) for name in sources},
                  firmware_sha256=FIRMWARE, cases=[],
                  boundary='Actual service, pthreads and firmware discovery; host device/property adapters')
    with (out / 'compile.log').open('wb') as log:
        compiled = subprocess.run(compiler, stdout=log, stderr=subprocess.STDOUT, check=False)
    result['compile_exit_code'] = compiled.returncode
    if not compiled.returncode:
        env = dict(os.environ, ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',
                   UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1',
                   TSAN_OPTIONS='halt_on_error=1')
        for case in args.case or CASES:
            try:
                run = subprocess.run([str(out / 'test'), case, str(firmware)],
                                     env=env, capture_output=True, timeout=15, check=False)
                code, stdout, stderr = run.returncode, run.stdout, run.stderr
            except subprocess.TimeoutExpired as error:
                code, stdout, stderr = None, error.stdout or b'', error.stderr or b''
            (out / (case + '.stdout')).write_bytes(stdout)
            (out / (case + '.stderr')).write_bytes(stderr)
            result['cases'].append(dict(case=case, exit_code=code, passed=code == 0))
            print(f'{case}: ' + ('PASS' if code == 0 else f'FAIL ({code})'), flush=True)
    result['passed'] = sum(row['passed'] for row in result['cases'])
    result['total'] = len(args.case or CASES)
    result['status'] = 'PASS' if not compiled.returncode and result['passed'] == result['total'] else 'FAIL'
    result['artifacts'] = {str(path.relative_to(out)): digest(path)
                           for path in sorted(out.iterdir()) if path.is_file()}
    (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    if compiled.returncode:
        print((out / 'compile.log').read_text())
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
