# Source launcher runtime evidence probe

This directory prepares handset evidence collection for the new source-built
`/vendor/bin/wmt_launcher` and its paired `wmt_drv.ko`. Preparation and validation
here are offline only. Build18 stopped during compilation; use the completed
successor build number, currently build19, after its clean build, flash, early
collection and 30-file readback have passed. The script does not build or flash.

Run one probe at a time while the root operator owns ADB. The handset must already
have root ADB, completed boot and working Wi-Fi. It must remain on the same boot
throughout a run. Output must be a new directory; failed runs are preserved.

```bash
TRIAL=/home/desmond/Downloads/k50sv1_64_bsp/work/.capture-staging/source-replacement-20260905
python3 "$TRIAL/wmt-source-launcher-probe/run.py" capture --build 19 --phase first-boot \
  --output "$TRIAL/runtime/build19-source-launcher-first-boot"
python3 "$TRIAL/wmt-source-launcher-probe/run.py" capture --build 19 --phase normal-reboot \
  --output "$TRIAL/runtime/build19-source-launcher-normal-reboot"
python3 "$TRIAL/wmt-source-launcher-probe/run.py" exercise --build 19 --phase normal-reboot \
  --output "$TRIAL/runtime/build19-source-launcher-exercise"
```

`--build N` derives `buildN-expected-installed.json`, `buildN-input-update.json`,
`runtime/buildN-PHASE-early/`, and `runtime/buildN-PHASE-readback/result.json`.
Explicit `--expected-manifest`, `--build-inputs`, `--early-dir` and
`--readback-result` override those locations. The expected manifest uses the
30-file source-launcher schema prepared by `collect-build18-expected.py`.
Its kernel revision must match the clean frozen inputs; device/vendor revisions
are recorded from those inputs and can change for later builds. No launcher or
kernel commit is hardcoded. The known factory launcher SHA is always rejected.

`capture` checks the build incremental, boot ID, untainted kernel, independent
30-file raw readback, loaded module and init properties. It separately hashes
the current module, launcher pathname and `/proc/PID/exe`, checks a unique PID,
stable `/proc` starttime, exact service command line, TIDs, and one open
`/dev/stpwmt` fd. `wmt_loader` state is recorded; this oneshot service need not
stay running. Both ready properties and `wmt_launcher=running` are required.

The early continuous log prefix is copied and checked for replacement/truncation.
Only source-launcher records bearing the current PID are used. A retained ready
session, accepted `srh_patch` for that session with positive transaction ID,
`result=0 records=2`, and power completion establish startup attribution. Thread
scheduling can place the power-completion log before the ready or reply log.
Missing early records make startup attribution **INCONCLUSIVE**, while runtime
identity remains separately reportable. Enlarging log buffers after startup
cannot recover lines already evicted; the script never clears logs.

`exercise` records the exact original fwlog property and PID/TIDs, starts its own
same-boot continuous logcat and `/dev/kmsg` readers, and then:

1. Establishes the current source session from retained logs. If those records
   are missing, it exits without property or signal changes. For a deliberate
   recovery of this evidence gap, rerun with `--establish-session` and a new
   output directory. This first uses the guarded SIGTERM/init restart below to
   obtain an observable session; the subsequent exercise compares against it.
2. Sets fwlog `no` to establish a settled main-thread baseline, then `yes` and
   waits for one additional stable TID. Existing repeated mode=1 driver records
   tied to that worker provide separate evidence of bounded ioctl re-entry.
3. Sets fwlog `no`, waits for the extra TID to disappear while the original
   process stays healthy, records elapsed time, and verifies traffic through
   `wlan0` using four pings and advancing RX/TX packet counters.
4. Enables fwlog again, verifies a worker, checks the original PID/starttime/
   executable/hash again inside the signal command, and sends **SIGTERM** to
   that positive PID. Init automatically restarts the service. The script
   requires the old process to disappear, a new PID/starttime, a larger source
   session and power completion on the same boot, then verifies Wi-Fi traffic.
   The replacement need not search patches when the chip is already powered.

Android 10 init here implements `ctl.stop` through `Service::Stop()` /
`StopOrReset()` and `KillProcessGroup(SIGKILL)`. It does not supply the desired
SIGTERM cleanup exercise. Accordingly this script never uses `ctl.stop` or
device SIGKILL. Transient ready=`no`, stopped and restarting states are recorded
when observed; polling can miss these brief states and does not require them.

The final mode=0 subcheck requires an existing `wmt_plat_set_dbg_mode` kernel log
from the **old main TID**, within the signal-to-old-process-disappearance device
uptime window. Its source interpretation is tied to the expected kernel revision
and clean implementation files, copied into the evidence. `--kernel-tree`
defaults to the build project's kernel checkout. Missing source binding or
missing correctly attributed driver records make that subcheck INCONCLUSIVE.
This is evidence of the existing driver write/read log at that instant; it is
not an independent read of the final mode after the replacement worker starts.

Every property/signal mutation is followed by `finally` restoration of the exact
original fwlog value and verification of a healthy running source launcher.
An original empty value is restored as `""`; Android properties cannot delete
the key or distinguish a previously absent key from an empty one. Cleanup may
use `ctl.start wmt_launcher` only if the service is stopped and needs recovery.
It does not issue a routine stop/start. Failure details, command stdout/stderr,
continuous logs and cleanup status survive independently in `result.json`.
Host-side adb log readers receive terminate during cleanup; no device-wide
process kill, firmware/calibration write, module unload or EEPROM conclusion is
part of this probe. As with any finally handler, host loss or forced script
termination can prevent cleanup; the recorded original property supports manual
recovery in that case.

Exit codes: **0 PASS**, **1 FAIL**, **2 INCONCLUSIVE**. The overall status includes
the optional log-evidence subchecks; inspect `checks.exercise_runtime` to see
whether the actual worker/restart/traffic sequence completed when a mode log was
unavailable. `--timeout` defaults to 90 seconds per transition and is limited to
5–180 seconds. `--ping-target` accepts an IPv4 peer, default `1.1.1.1`; supply a
reachable local peer if the test network does not route that address.

Offline validation uses synthetic manifests, logs and mocked cleanup. It blocks
all subprocess launches while the fixtures run:

```bash
python3 "$TRIAL/wmt-source-launcher-probe/offline_validate.py"
```

These fixtures validate parser decisions and cleanup bookkeeping. They do not
establish any handset outcome; a later root-owned runtime run is still required.
