import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
ADB = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
ENV = dict(os.environ, ADB_LIBUSB='1')
DEV = '/dev/block/platform/mtk-msdc.0/11230000.msdc0/by-name/userdata'
LABEL = sys.argv[1]
ORDER = sys.argv[2:]
FILL_BYTES = int(os.environ.get('FSBENCH_FILL_BYTES', '0'))
assert FILL_BYTES in (0, 48 * 1024**3)
PIN_CPU = os.environ.get('FSBENCH_PIN_CPU', '')
assert PIN_CPU in ('', '4')
AFFINITY = ' --cpus_allowed=' + PIN_CPU if PIN_CPU else ''
OUT = ROOT / LABEL
OUT.mkdir(exist_ok=False)

def run(name, command, timeout=7200):
    result = subprocess.run(ADB + ['shell', command], env=ENV, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=timeout)
    (OUT / (name + '.txt')).write_text(result.stdout)
    (OUT / (name + '.stderr')).write_text(result.stderr)
    result.check_returncode()
    return result.stdout

def require_unmounted():
    state = run('current-state', 'getprop ro.bootmode; cat /proc/mounts')
    assert state.startswith('recovery\n'), state
    assert not any('mmcblk0p30 ' in line or '/by-name/userdata ' in line
                   or ' /data ' in line or ' /mnt/fsbench ' in line
                   for line in state.splitlines()), state

snapshot = ('uname -a; cat /proc/sys/kernel/random/boot_id; cat /proc/mounts; '
            'cat /sys/devices/system/cpu/online; '
            'cat /sys/block/mmcblk0/queue/scheduler; '
            'cat /sys/block/mmcblk0/queue/read_ahead_kb; '
            'for c in /sys/devices/system/cpu/cpu[0-7]/cpufreq; do '
            'printf "%s " "$c"; cat "$c/scaling_governor" "$c/scaling_cur_freq"; done; '
            'for z in /sys/class/thermal/thermal_zone*; do '
            'printf "%s " "$z"; cat "$z/type" "$z/temp"; done; '
            'cat /sys/block/mmcblk0/stat; df -k /mnt/fsbench')
require_unmounted()
run('queue-policy', 'set -e; echo deadline > /sys/block/mmcblk0/queue/scheduler; '
    'echo 128 > /sys/block/mmcblk0/queue/read_ahead_kb; mkdir -p /mnt/fsbench')
metadata = {'started_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'label': LABEL, 'order': ORDER, 'device': DEV,
            'scope': 'Fresh format with optional filler; recovery psync QD1; not app or endurance testing',
            'filler_bytes': FILL_BYTES,
            'pinned_cpu': PIN_CPU or None,
            'rounds': []}

for index, fs in enumerate(ORDER, 1):
    assert fs in ('f2fs', 'ext4')
    prefix = f'{index:02d}-{fs}'
    require_unmounted()
    print(prefix, 'format', flush=True)
    start = time.monotonic()
    formatter = (f'/system/bin/make_f2fs -g android {DEV}' if fs == 'f2fs' else
                 f'/system/bin/mke2fs -F -t ext4 -b 4096 -O quota {DEV}')
    run(prefix + '-format', formatter)
    format_seconds = time.monotonic() - start
    options = 'noatime,nosuid,nodev,' + ('nodiscard' if fs == 'f2fs' else 'noauto_da_alloc')
    run(prefix + '-mount', f'mount -t {fs} -o {options} {DEV} /mnt/fsbench')
    try:
        if FILL_BYTES:
            run(prefix + '-empty', snapshot)
            print(prefix, 'fill', FILL_BYTES, 'bytes', flush=True)
            filler = run(prefix + '-fill',
                f'/tmp/fio --name=fill --filename=/mnt/fsbench/filler.bin --size={FILL_BYTES} '
                '--rw=write --bs=1048576 --ioengine=psync --direct=1 --end_fsync=1 '
                '--fallocate=none --clocksource=clock_gettime --output-format=json' + AFFINITY)
            filled = json.loads(filler)['jobs'][0]
            assert filled['error'] == 0 and filled['write']['io_bytes'] == FILL_BYTES
        run(prefix + '-before', snapshot)
        print(prefix, 'fio', flush=True)
        output = run(prefix + '-fio', '/tmp/fio /tmp/io-comparison.fio --output-format=json' + AFFINITY)
        result = json.loads(output)
        assert len(result['jobs']) == 6, result.keys()
        assert all(job['error'] == 0 for job in result['jobs']), result['jobs']
        run(prefix + '-after', snapshot)
        run(prefix + '-sync', 'sync')
    finally:
        run(prefix + '-unmount', 'umount /mnt/fsbench')
    require_unmounted()
    checker = (f'/system/bin/fsck.f2fs --dry-run {DEV}' if fs == 'f2fs' else
               f'LD_LIBRARY_PATH=/tmp/ext4-libs:/system/lib64 /tmp/e2fsck -f -n {DEV}')
    check = run(prefix + '-fsck', checker)
    assert '[Fail]' not in check and '[ASSERT]' not in check, check
    metadata['rounds'].append({'index': index, 'fs': fs,
                               'format_seconds': format_seconds,
                               'elapsed_seconds': time.monotonic() - start,
                               'job_errors': [job['error'] for job in result['jobs']]})
    (OUT / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(prefix, 'PASS', round(time.monotonic() - start, 1), 'seconds', flush=True)
    time.sleep(15)

run('final-dmesg', 'dmesg')
metadata['finished_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
(OUT / 'metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
