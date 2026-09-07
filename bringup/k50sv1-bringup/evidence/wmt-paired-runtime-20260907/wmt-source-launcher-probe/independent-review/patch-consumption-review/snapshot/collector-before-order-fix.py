"""Bind cold-boot kernel patch-download observations to the installed source pair."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phase', choices=['first-boot', 'normal-reboot'])
phase = parser.parse_args().phase
trial = Path(__file__).resolve().parent
out = trial / f'runtime/build19-{phase}-patch-consumption'
out.mkdir(exist_ok=False)
expected = json.loads((trial / 'build19-expected-installed.json').read_text())
early = trial / f'runtime/build19-{phase}-early'
boot = json.loads((early / 'early-complete.json').read_text())['identity'].splitlines()[0]
readback = json.loads((trial / f'runtime/build19-{phase}-readback/result.json').read_text())
assert readback['status'] == 'PASS' and readback['boot_id'] == boot and len(readback['rows']) == 30
adb = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
env = dict(os.environ, ADB_LIBUSB='1')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def shell(name, command):
    result = subprocess.run(adb + ['shell', command], env=env, capture_output=True, timeout=30)
    (out / (name + '.txt')).write_bytes(result.stdout + result.stderr)
    result.check_returncode()
    return result.stdout.decode()


identity = shell('identity', 'cat /proc/sys/kernel/random/boot_id; '
                 'getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted; '
                 'cat /proc/uptime').splitlines()
assert identity[:3] == [boot, expected['incremental'], '0']
observed_uptime = float(identity[3].split()[0])
modules = shell('modules', 'cat /proc/modules')
assert re.search(r'^wmt_drv\s', modules, re.M)
paths = ['/vendor/lib/modules/wmt_drv.ko', '/vendor/bin/wmt_launcher',
         '/vendor/firmware/ROMv2_lm_patch_1_0_hdr.bin', '/vendor/firmware/ROMv2_lm_patch_1_1_hdr.bin']
actual = dict((line.split(None, 1)[1].strip(), line.split()[0]) for line in
              shell('installed-hashes', 'sha256sum ' + ' '.join(map(shlex.quote, paths))).splitlines())
for path in paths[:2]:
    assert actual[path] == next(row['sha256'] for row in expected['rows'] if row['path'] == path)
preflash = json.loads((trial / 'runtime/build19-preflash/result.json').read_text())
product = trial / 'build-project/lineage-17.1/out/target/product/k50sv1_64_bsp'
firmware = []
for path in paths[2:]:
    data = (product / path.lstrip('/')).read_bytes()
    assert sha(data) == actual[path] == next(row['after_sha256'] for row in preflash['files'] if row['path'] == path)
    firmware.append(dict(path=path, sha256=sha(data), bytes=len(data), normal_header_bytes=28,
                         body_bytes=len(data) - 28, header_hex=data[:28].hex()))
source_tree = trial / 'wmt-paired-batch-kernel-work'
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source_tree, text=True).strip()
assert revision == expected['kernel_revision']
sources = []
base = 'drivers/misc/mediatek/connectivity/source/common/common_main/'
for relative in ['core/wmt_lib.c', 'core/wmt_ctrl.c', 'core/wmt_ic_soc.c', 'linux/wmt_dev.c']:
    path = source_tree / (base + relative)
    data = path.read_bytes()
    pinned = subprocess.check_output(['git', 'show', revision + ':' + base + relative], cwd=source_tree)
    assert data == pinned
    destination = out / 'source' / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    sources.append(dict(path=base + relative, sha256=sha(data), evidence=str(destination.relative_to(out))))
raw = (early / 'continuous-kmsg.txt').read_bytes()
records = []
for line in raw.decode(errors='replace').splitlines():
    match = re.match(r'\d+,(\d+),(\d+),[^;]*;(.*)', line)
    if match and int(match[2]) / 1e6 <= observed_uptime:
        records.append(dict(sequence=int(match[1]), seconds=int(match[2]) / 1e6,
                            message=match[3], raw=line))
assert records and records[0]['sequence'] == 0
assert all(b['sequence'] == a['sequence'] + 1 for a, b in zip(records, records[1:]))
start_re = re.compile(r'mtk_wcn_soc_normal_patch_dwn:normal patch download patch size\((\d+)\) fragNum\((\d+)\)')
done_re = re.compile(r'mtk_wcn_soc_normal_patch_dwn:wmt_core: patch dwn:(-?\d+) frag\((\d+), (\d+)\) (ok|fail)')
downloads, pending = [], None
for record in records:
    start, done = start_re.search(record['message']), done_re.search(record['message'])
    if start:
        assert pending is None, 'An earlier patch download has no terminal record'
        pending = dict(body_bytes=int(start[1]), expected_fragments=int(start[2]), start=record)
    if done:
        assert pending is not None, 'A terminal patch record has no start'
        assert int(done[1]) == 0 and done[4] == 'ok'
        assert int(done[2]) == pending['expected_fragments']
        downloads.append(dict(**pending, fragments=int(done[2]), final_fragment_bytes=int(done[3]), end=record))
        pending = None
assert len(downloads) >= 2 and pending is None
assert [row['body_bytes'] for row in downloads[:2]] == [row['body_bytes'] for row in firmware]
selected = [part['raw'] for row in downloads for part in (row['start'], row['end'])]
(out / 'patch-download-records.txt').write_text('\n'.join(selected) + '\n')
result = dict(status='PASS_OBSERVED_KERNEL_PATCH_DOWNLOAD', boot_id=boot, incremental=expected['incremental'],
              kernel_revision=revision, observed_uptime=observed_uptime, installed_sha256=actual,
              first_two_body_sizes_match_retained_firmware=True, firmware=firmware, downloads=downloads,
              source_files=sources, continuous_prefix_bytes=len(raw), continuous_prefix_sha256=sha(raw),
              source_inference='The source boot path requests srh_patch when its cache is empty. '
              'Normal records are published only by a matching accepted v2 reply; legacy metadata setters reject. '
              'The observed normal download function reads those accepted records and reports successful '
              'transfers of both expected firmware body sizes. This attributes kernel consumption to the '
              'installed source pair, independently of recycled userspace PIDs or wall-clock log conversion.',
              limits='Kernel transport completion records are observed; no bus-level byte capture or '
              'cold userspace session-ID attribution is claimed. Host paired tests separately cover exact '
              'record contents and stale-reply rejection.')
assert shell('final-identity', 'cat /proc/sys/kernel/random/boot_id; '
             'getprop ro.build.version.incremental; cat /proc/sys/kernel/tainted').splitlines() == identity[:3]
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print('PASS: same-boot source kernel completed the two expected normal firmware-body transfers')
