The Build19 source-launcher runtime evidence matches frozen run.py c60e1cf9c96154f9a47119920eb8f7fa930045fa9781f8d1434816159b2eb069. This readout passes. The first-boot and normal-reboot capture startup attribution correctly remains INCONCLUSIVE; their installed source identity and runtime checks pass.

| Capture | Status | Boot ID | PID / starttime ticks | Installed readback |
| --- | --- | --- | --- | --- |
| First boot | INCONCLUSIVE for startup attribution | 5707e604-68f3-4f50-ab7f-0aa6e0fb23e6 | 328 / 1145 | 30/30 |
| Normal reboot | INCONCLUSIVE for startup attribution | 617ecc06-c2fc-404f-9af7-57a370fc85ce | 324 / 378 | 30/30 |
| Exercise | PASS | 617ecc06-c2fc-404f-9af7-57a370fc85ce | 324 → 7434 → 8123 | 30/30 |

The source launcher SHA is 6103fbf135289d76648e94cc8b289004ada106e0c4395765b340e6a78bf4b96c; the live executable through /proc/PID/exe matches it in every snapshot. The module SHA is 33e0d8cd95db22ded488539fd5c24e77aa4b7866cb3382cf6e0f9d707e5e868f. The build incremental is eng.desmon.20260907.053434, kernel revision 4192fb6ae88e057bb2abb0f464cf6b4cb64697de, device revision c270801a1f214b3c56b16efda5742eb0947b0c37. Each snapshot has the expected command line and exactly one /dev/stpwmt descriptor.

The initial PID 324 session is unknown. A guarded SIGTERM established PID 7434, starttime 15908, session 2. The fwlog/SIGTERM exercise then produced PID 8123, starttime 17272, session 3 in the same boot. Both signals checked the old PID starttime, actual executable path and source ELF SHA before sending SIGTERM; both exited 0. Old /proc/324/stat and /proc/7434/stat returned ENOENT. Those two observations are the only nonzero commands among all 196 recorded commands.

| Controlled restart | Native ready ns | Native power ns | Conservative birth bound ns | Subsequent upper bound ns |
| --- | --- | --- | --- | --- |
| Establish session 2, PID 7434 | 159101226239 | 159130203086 | 159090000000 | 161010000000 |
| Exercise session 3, PID 8123 | 172739491394 | 172760234086 | 172730000000 | 174640000000 |

The native log reader discarded the entire 128-byte historical frame before controlled restarts. The final binary stream is 9512 bytes with 51 complete frames. Each process slice and whole-frame prefix SHA matches the final binary stream. Raw clock observations show persist.logd.timestamp=m, ro.logd.timestamp empty, CLK_TCK=100 and the same boot ID. Both native ready records exceed the conservative next-tick birth bound, and both power completions report attempt 1. No new srh_patch transaction is claimed for these warm restarts. The short ready=no/stopped/restarting transitions were not observed.

The fwlog cycle kept PID 7434/starttime 15908 healthy: main-only [7434] → [7434, 7670] → [7434]. All ending states have three consecutive samples. The worker is first absent at uptime 166.22 and stable through 167.51; the disable window began at 165.19. The recorded 2.383950756 seconds includes property I/O, ADB polling and stabilization, so it is not exact pthread_join latency. A second worker, 7925, was present before the exercise SIGTERM.

| Existing kernel mode evidence | Bound task | Window, uptime seconds | Observed records |
| --- | --- | --- | --- |
| Enable/re-entry mode 1 | Worker TID 7670 | 163.02–164.70 | 16; 163.111771–164.614794 |
| fwlog-cycle disable mode 0 | Old main TID 7434 | 165.19–167.51 | sequence 14217 at 166.116824 |
| SIGTERM final disable mode 0 | Old main TID 7434 | 172.56–173.33 | sequence 14310 at 172.724874 |

Both source copies match the frozen kernel Git blobs. The observed wmt_plat_set_dbg_mode lines are the source's write/read logs; they are not an independent final register-state readback.

| Wi-Fi check | Replies | Loss | RX/TX counter delta | RTT min/avg/max/mdev, ms |
| --- | --- | --- | --- | --- |
| After fwlog cycle | 4/4 | 0% | +6 / +4 | 19.919 / 22.835 / 31.012 / 4.729 |
| After SIGTERM restart | 4/4 | 0% | +4 / +6 | 18.488 / 21.883 / 27.424 / 3.413 |

Both commands explicitly used wlan0 to reach 1.1.1.1 from 192.168.1.251/24.

Cleanup restored the original empty fwlog value exactly: original and restored raw output are each one newline. PID 8123/starttime 17272 remained running, both ready properties were yes, taint was 0, and the final task listing was exactly one line, 8123. Before/after proc stat records also show one thread. The final snapshot spans uptime 177.14–177.88 and the probe finished at 2026-09-07T04:26:38.667837+00:00. No recovery ctl.start was used. Both host collectors were deliberately terminated with recorded exit -15 and empty stderr; these are host reader exits.

This cleanup conclusion applies to that snapshot. Later root-owned device tests and final global timestamp/log-buffer restoration are outside this readout. Empty property value and absent property key cannot be distinguished by getprop. Cold startup/session/patch attribution is still insufficient in the two capture results; no firmware, calibration, EEPROM, module-unload or broader subsystem claim is added.

The readout independently verified 425 fixed input files, every recorded file byte count/SHA reference, all raw process snapshots and TID samples, binary frame boundaries/session clocks, kernel mode lines, ping statistics and cleanup. It ran no ADB command and made no product changes. Detailed evidence and limits are in runtime-readout.json; input-sha256.json records every checked input. Only this new report directory was written.

Direct evidence: [exercise result](../../runtime/build19-source-launcher-exercise/result.json), [native binary log](../../runtime/build19-source-launcher-exercise/exercise-logcat.bin), [kernel log](../../runtime/build19-source-launcher-exercise/exercise-kmsg.txt), [original fwlog value](../../runtime/build19-source-launcher-exercise/0013-original-fwlog-property.stdout), [restored fwlog value](../../runtime/build19-source-launcher-exercise/0144-finally-fwlog-readback.stdout), [cleanup task list](../../runtime/build19-source-launcher-exercise/0152-finally-process-tids.stdout), [cleanup final service state](../../runtime/build19-source-launcher-exercise/0154-finally-process-state-after.stdout).
