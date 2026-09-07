"""Pair actual kernel broker/dispatch/consumers with complete source launcher."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kernel', required=True, type=Path)
parser.add_argument('--device', required=True, type=Path)
parser.add_argument('--firmware', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--sanitizer', choices=['address', 'thread'], default='address')
args = parser.parse_args()
here = Path(__file__).resolve().parent
kernel, device, firmware = args.kernel.resolve(), args.device.resolve(), args.firmware.resolve()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
source = device / 'wmt-launcher'
test = kernel / 'drivers/misc/mediatek/connectivity/source/common/test'
sys.path.insert(0, str(test))
spec = importlib.util.spec_from_file_location('pair_source', test / 'test_wmt_command_v2.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


revisions = {}
for label, repository in [('kernel', kernel), ('device', device)]:
    assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=repository).strip()
    revisions[label] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repository, text=True).strip()
sources = {name: (kernel / path).read_text() for name, path in module.PATHS.items()}
assert sources['uapi'].encode() == (source / 'include/linux/mtk_wmt_cmd.h').read_bytes()
generated = module.build_fixture(sources)
assert generated.count('int main(int argc, char **argv)') == 1
generated = generated.replace('int main(int argc, char **argv)',
                              'int original_fixture_entry(int argc, char **argv)')
(out / 'broker.c').write_text(generated + '\n' + (here / 'broker_bridge.c').read_text())
expected_sha = {
    'ROMv2_lm_patch_1_0_hdr.bin': '7a58e99fdcab239f133be92da999f8733878617191bb1f5caa1096d91ad8e1a2',
    'ROMv2_lm_patch_1_1_hdr.bin': 'cb7ba98c5c73705eb03a6ec11b78a3b1cce6069132b1f267d50079f2b1b594fd',
}
fixture = out / 'factory'
fixture.mkdir()
records = []
for name, expected in expected_sha.items():
    assert digest(firmware / name) == expected
    shutil.copy2(firmware / name, fixture / name)
    header = (firmware / name).read_bytes()[:28]
    assert header[23] == 0 and header[24] >> 4 == 2
    records.append((header[24] & 15, name, [0, *header[25:28]], header[:15].decode()))
records.sort()
assert [r[0] for r in records] == [1, 2]
(out / 'expected_firmware.h').write_text(
    'static const char *expected_names[] = {' + ','.join(json.dumps(r[1]) for r in records) + '};\n' +
    'static const unsigned char expected_addresses[2][4] = {' +
    ','.join('{' + ','.join(map(str, r[2])) + '}' for r in records) + '};\n' +
    'static const char *expected_version = ' + json.dumps(records[0][3]) + ';\n')
(out / 'empty').mkdir()
shutil.copytree(fixture, out / 'all-rom')
for kind in range(5):
    header = bytearray(32)
    header[25:28] = bytes([0x21, 0x32, 0x40])
    header[31] = kind
    (out / 'all-rom' / f'soc1_0_ram_integration_{kind}.bin').write_bytes(header)
sanitizer = 'address,undefined' if args.sanitizer == 'address' else 'thread'
command = ['clang', '-D_GNU_SOURCE', '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
           '-Wno-unused-function', '-Wno-unused-parameter', '-Wno-pointer-sign', '-Wno-macro-redefined',
           '-fno-omit-frame-pointer', '-no-pie', '-pthread', '-fsanitize=' + sanitizer,
           '-I' + str(source), '-I' + str(source / 'include'), '-I' + str(source / 'test-include'),
           '-I' + str(out), str(out / 'broker.c'), str(here / 'service_bridge.c'),
           *[str(source / name) for name in ['protocol.c', 'patch.c', 'firmware.c']],
           '-o', str(out / 'test')]
compiled = subprocess.run(command, capture_output=True)
(out / 'compile.log').write_bytes(compiled.stdout + compiled.stderr)
result = dict(revisions=revisions, compiler=command, sanitizer=sanitizer,
              compile_exit_code=compiled.returncode, cases=[],
              kernel_source_sha256={module.PATHS[name]: digest(kernel / module.PATHS[name]) for name in sources},
              device_source_sha256={str(p.relative_to(device)): digest(p) for p in sorted(source.rglob('*')) if p.is_file()},
              firmware_sha256=expected_sha, expected_patch_metadata=records,
              harness_sha256={str(p): digest(p) for p in [Path(__file__), here / 'service_bridge.c', here / 'broker_bridge.c',
                  test / 'test_wmt_command_v2.py', test / 'wmt_command_v2_host.c', test / 'test_wmt_buffers.py']},
              boundary='Actual full userspace source, broker, VFS cases and metadata consumers; host allocation/user-copy/completion/property/hardware adapters; no RF or real kernel scheduling claim.')
if not compiled.returncode:
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',
               UBSAN_OPTIONS='halt_on_error=1', TSAN_OPTIONS='halt_on_error=1')
    for name in ['factory', 'cancel-first', 'duplicate', 'missing-firmware', 'all-rom', 'close-pending']:
        folder = out / ('empty' if name == 'missing-firmware' else 'all-rom' if name == 'all-rom' else 'factory')
        try:
            run = subprocess.run([str(out / 'test'), name, str(folder)], env=env, capture_output=True, timeout=15)
            code, stdout, stderr = run.returncode, run.stdout, run.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = None, error.stdout or b'', error.stderr or b''
        (out / (name + '.stdout')).write_bytes(stdout)
        (out / (name + '.stderr')).write_bytes(stderr)
        result['cases'].append(dict(case=name, exit_code=code, passed=code == 0))
        print(name + ': ' + ('PASS' if code == 0 else 'FAIL ' + str(code)), flush=True)
else:
    print((out / 'compile.log').read_text(), flush=True)
result['passed'] = sum(row['passed'] for row in result['cases'])
result['total'] = 6
result['status'] = 'PASS' if result['passed'] == 6 and not compiled.returncode else 'FAIL'
result['artifacts'] = {str(path.relative_to(out)): digest(path) for path in sorted(out.rglob('*')) if path.is_file()}
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
raise SystemExit(result['status'] != 'PASS')
