# Adopted F2FS storage decision

`/data` uses corrected F2FS; `/cache` stays ext4 and the unused 32 MiB metadata
partition stays unused. This is the normal source build, with unencrypted data,
flush barriers, crash recovery and background GC retained. The current
[fstab](../../../lineage-17.1/device/xsh/k50sv1_64_bsp/rootdir/etc/fstab.mt6755)
owns the mount options. The owner accepted the measured sequential-write
tradeoff for the existing Android features and random/synchronous-write benefits.

The donor is `f2fs-stable/linux-3.18.y` commit
`7dcbebc5490b10bb5b9e136918fa56bf9dcfed32` (2019-07-30), also the exact source
[merged into AOSP android-3.18](https://android.googlesource.com/kernel/common/+/a00cecdaef2e83258821321419609189bde08342).
Subsequent quota and atomic-write correctness fixes are included. The old donor
does not provide modern F2FS compression or current kernel security maintenance.

The adopted v2 handset trial passed native first-boot formatting, recovery
factory reset, the inline-mmap quota regression and offline fsck. Checked file
contents and acknowledged transactions survived normal reboot and SysRq reset
during WAL/FULL and DELETE/FULL SQLite writes. The native DELETE/FULL trace
observed 12 successful F2FS atomic BEGIN/COMMIT pairs and no rollback-journal
opens, against 12 journal opens on ext4. These are software-reset results;
physical power loss and endurance were not tested.
[Durability](../evidence/f2fs-runtime-20260905/v2-durability/summary.json),
[SQLite atomic path](../evidence/f2fs-runtime-20260905/sqlite-atomic/summary.json),
[offline fsck](../evidence/f2fs-runtime-20260905/quota-mmap-after-v2-fsck.txt).

One paired v2 sample at each occupancy used the same recovery kernel, fio,
CPU placement, scheduler and flush policy. After 48 GiB of actual filler writes,
F2FS improved durable-random and mixed IOPS by 13.4% and 12.1%, and p99 sync
latency by 41%; sequential writes were 9.1% slower. Both filesystems retained
long p99.9 stalls. The fresh pair also traded write speed for read speed.
This establishes those workloads, not general app speed or battery savings.
[Method, raw results and occupancy](../evidence/f2fs-runtime-20260905/benchmarks/summary.json).

The Android Q formatter rejects a 32 MiB F2FS image. Its cache-sized trial
reserved 92 MiB, including GC reserve, with no demonstrated cache workload
benefit; that supports retaining ext4 there. The userdata-sized trial reserved
926 MiB including GC reserve. Do not count GC reserve twice, infer encryption
from a filesystem capability bit or add `nobarrier` to improve a benchmark.
[Host layout evidence](../evidence/f2fs-20260905/mkfs/results.json).

Storage adoption is complete. Future correctness changes need affected I/O and
recovery checks. App-start comparisons, aged filesystems, power and wear remain
optional studies, not unfinished adoption gates. Latest installed images and
build instructions are in [HANDOFF](HANDOFF.md).
