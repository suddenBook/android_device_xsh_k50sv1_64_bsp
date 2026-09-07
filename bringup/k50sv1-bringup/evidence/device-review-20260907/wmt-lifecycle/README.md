# WMT module exit

Kernel `ef8238aca4c` fixes reachable teardown defects found while preparing
WI-012's module unload/reload check. Its clean kernel/module build and actual
five-module unload/reload **pass** on Tier 2, boot `6dd1a776-776a-4753-936f-7c4260f41f6c`.
The earlier build21 kernel `69faa749fff` was inspected but was not unloaded.

Exit now withdraws proc/display/bridge producers, drains private debug work and
display power work, joins BTM before final hardware-off, then runs library
prepare → STP teardown → library finish. STP/debug timers and log work are
joined before their objects are freed. Partial initialization uses the same
owned-resource sequence. Failed hardware-off retains the unconfirmed power
state so retry reaches hardware; ordinary function-off return semantics stay
unchanged. STP netlink registration and outgoing sends share lifecycle locking,
re-registration restores this kernel's cleared operation count, and recipient
compaction retains every live listener.

The [host receipt](host-results.json) records **168/168** actual-source cases,
with ASan/UBSan and leak checks: outer/debug 76, power/library helper 14,
library initialization 27, operation pool 16, bridge callbacks 19, STP teardown
10 and netlink 6. Original functions and isolated omitted repairs produce the
expected failures, including late debug work, lost power-off retries, BTM use
after library clearing, unjoined STP resources, closed netlink count corruption
and dropped listeners. Host adapters model kernel API contracts; these counts
do not substitute for the separate hardware evidence below.

The [build receipt](build-receipt.json) binds a clean kernel-only iteration
on complete build21 Android output: five module ABIs pass 381 symbol-version
pairs. Boot/recovery ramdisks, DTB/DTBO and 940 non-module vendor entries match
the parent; only the kernels and WMT module payload change. Boot, recovery
and vendor were flashed together without wiping data. Image-length boot and
recovery readbacks and all five installed module hashes match.

The [runtime receipt](runtime-receipt.json) records zero references before each
ordinary unload, all five modules and eight node/proc paths absent, hardware
power-off returning `0`, and WMT exit completed. Loading only the parent and
running the normal loader lets init restore all four children. Launcher session
advances **1 → 2**, accepts two patch records and completes power initialization
on attempt 1. This is a privileged Tier-2 diagnostic operation; the AOSP `su`
domain is permissive despite global Enforcing.

After reload, Wi-Fi reconnects with unchanged factory MAC/calibration and 3/3
external pings, Bluetooth discovers three devices and shuts down without a
crash, and P2P forms/removes its group. GNSS's isolated two-minute run reports
123 status callbacks, up to 17 satellites and complete start/stop callbacks;
there is no indoor fix. The first GNSS run exceeded its five-second stop-callback
window while another GMS GPS request was recorded; the driver subsequently
closed successfully. Android's [stop callback](https://developer.android.com/reference/android/location/GnssStatus.Callback#onStopped())
tracks the GNSS system, so another client's request matters to this measurement.
The retry temporarily excludes that requester and restores its original app-op
modes. Final boot ID is unchanged, taint is zero, fault
signature matches are zero, and all 59 AVC records across overlapping captures
belong to six already-reviewed refusal classes.

The [patch series](../source/revisions.json) includes production changes and
reproducible tests. Private inspection/results are under
`work/.capture-staging/device-review-20260907/{radio-review/module-lifecycle,policy-review/wmt-lib-lifecycle}`.
The ordering follows the kernel's documented [workqueue teardown contracts](https://docs.kernel.org/core-api/workqueue.html),
checked against this tree's actual workqueue, timer, proc and generic-netlink
implementations.
