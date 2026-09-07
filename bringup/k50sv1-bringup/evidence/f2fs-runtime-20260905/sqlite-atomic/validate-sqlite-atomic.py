import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent
OUT = ROOT / 'sqlite-atomic'
ADB = ['/home/desmond/Android/Sdk/platform-tools/adb', '-s', '0123456789ABCDEF']
ENV = dict(os.environ, ADB_LIBUSB='1')
REMOTE = '/data/local/tmp/fs-atomic-f2fs-numeric'

def shell(command, timeout=60):
    return subprocess.run(ADB + ['shell', command], env=ENV, capture_output=True, timeout=timeout)

def save(name, command, timeout=60):
    p = shell(command, timeout)
    (OUT / name).write_bytes(p.stdout)
    (OUT / (name + '.stderr')).write_bytes(p.stderr)
    p.check_returncode()
    return p.stdout.decode(errors='replace')

def wait_android(label, old=None):
    start = time.monotonic()
    captured = False
    while time.monotonic() - start < 360:
        time.sleep(2)
        try:
            p = shell('getprop sys.boot_completed; cat /proc/sys/kernel/random/boot_id; getprop ro.build.version.incremental', 10)
        except subprocess.TimeoutExpired:
            continue
        lines = p.stdout.splitlines()
        if p.returncode or len(lines) < 3 or lines[1] == old:
            continue
        if lines[2] != b'eng.desmon.20260905.134458':
            continue
        if not captured:
            save(label + '-early-dmesg.txt', 'dmesg')
            captured = True
        if lines[0] == b'1':
            (OUT / (label + '-boot.txt')).write_bytes(p.stdout)
            return time.monotonic() - start
    raise RuntimeError(label + ' Android boot timed out')

wait_android('initial')
save('f2fs-identity.txt', 'id; getprop ro.build.version.incremental; cat /proc/mounts')
save('prepare.txt', f'mkdir -p {REMOTE}; touch {REMOTE}/.nomedia')
q = subprocess.run(ADB + ['shell', f'strace -v -s 160 -e raw=ioctl -e trace=openat,close,ioctl,fdatasync,pwrite64,ftruncate -o {REMOTE}/trace.txt /system/bin/sqlite3 {REMOTE}/test.db'],
                   input=(OUT / 'workload.sql').read_bytes(), env=ENV, capture_output=True, timeout=60)
(OUT / 'f2fs-output.txt').write_bytes(q.stdout)
(OUT / 'f2fs-stderr.txt').write_bytes(q.stderr)
q.check_returncode()
assert q.stdout.splitlines() == [b'delete', b'ok', b'3|10|10|12288'], q.stdout
trace = save('f2fs-trace.txt', f'cat {REMOTE}/trace.txt')
starts = [x for x in trace.splitlines() if 'ioctl(' in x and ', 0xf501,' in x]
commits = [x for x in trace.splitlines() if 'ioctl(' in x and ', 0xf502,' in x]
assert len(starts) >= 10 and len(starts) == len(commits), (starts, commits)
assert all(x.rstrip().endswith('= 0') for x in starts + commits)
print('Native SQLite F2FS atomic BEGIN/COMMIT observed:', len(commits), flush=True)

sql = '.bail on\nPRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;\n'
sql += 'CREATE TABLE commits(tx INTEGER PRIMARY KEY);\n'
for tx in range(1, 10001):
    sql += f"BEGIN IMMEDIATE; UPDATE atomic_test SET value={tx}; INSERT INTO commits VALUES({tx}); COMMIT; SELECT 'ACK={tx}';\n"
(OUT / 'writer.sql').write_text(sql)
subprocess.run(ADB + ['push', str(OUT / 'writer.sql'), REMOTE + '/writer.sql'], env=ENV, check=True, stdout=subprocess.DEVNULL)
old = shell('cat /proc/sys/kernel/random/boot_id').stdout.strip()
writer = subprocess.Popen(ADB + ['shell', f'/system/bin/sqlite3 {REMOTE}/test.db < {REMOTE}/writer.sql'], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
acks = []
with (OUT / 'writer-acks.txt').open('wb') as log:
    for line in writer.stdout:
        log.write(line)
        if line.startswith(b'ACK='):
            acks.append(int(line[4:].strip()))
        if acks and acks[-1] >= 300:
            reset = shell('echo b > /proc/sysrq-trigger', 20)
            (OUT / 'reset-command.txt').write_bytes(reset.stdout + reset.stderr)
            break
    else:
        raise RuntimeError('Writer ended before reset point')
    for line in writer.stdout:
        log.write(line)
        if line.startswith(b'ACK=') and line[4:].strip().isdigit():
            acks.append(int(line[4:].strip()))
writer.wait(timeout=30)
seconds = wait_android('forced', old)
state = save('post-reset.txt', f'/system/bin/sqlite3 {REMOTE}/test.db "PRAGMA integrity_check; SELECT count(*),min(tx),max(tx) FROM commits; SELECT count(*),min(value),max(value),sum(length(payload)) FROM atomic_test;"').splitlines()
assert state[0] == 'ok', state
count, lo, hi = map(int, state[1].split('|'))
assert lo == 1 and count == hi and count >= max(acks), (state, acks[-1])
assert state[2] == f'3|{hi}|{hi}|12288', state
summary = {'mode':'SQLite DELETE/FULL with F2FS batch atomic writes', 'successful_atomic_begin_commit_pairs_in_trace':len(commits), 'last_acknowledged_transaction':max(acks), 'recovered_transactions':count, 'all_acknowledged_transactions_retained':True, 'three_row_state_matches_commit_log':True, 'sqlite_integrity':'ok', 'forced_reset_boot_seconds':seconds, 'writer_transport_exit':writer.returncode, 'reset_transport_exit':reset.returncode, 'scope':'One active-writer software reset; not physical power-loss or endurance proof'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('SQLite atomic interrupted-write recovery PASS', summary, flush=True)
subprocess.run(ADB + ['reboot', 'recovery'], env=ENV, check=True)
for _ in range(100):
    time.sleep(2)
    p = shell('getprop ro.bootmode; cat /proc/mounts', 10)
    if p.returncode == 0 and p.stdout.startswith(b'recovery\n'):
        break
else:
    raise RuntimeError('Recovery did not boot')
assert b' /data ' not in p.stdout and b'mmcblk0p30 ' not in p.stdout
check = save('offline-fsck.txt', '/system/bin/fsck.f2fs --dry-run /dev/block/platform/mtk-msdc.0/11230000.msdc0/by-name/userdata', 180)
assert '[Fail]' not in check and '[ASSERT]' not in check, check
summary['post_reset_offline_fsck_clean'] = True
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('Atomic-write recovery offline fsck PASS', flush=True)
