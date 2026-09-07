# MT6755 launcher source candidate

This service targets this product's MT6755 SoC, BTIF and current firmware
inventory. The `wmt_launcher` vendor module replaces the retained executable
under the existing init service and SELinux domain. The candidate requires the
paired version-2 command broker and bounded firmware-log ioctl; full product
build and handset validation remain required before adoption.

Startup keeps the product's `-p /vendor/firmware/ -o 1` invocation. It waits for
`vendor.connsys.driver.ready=yes`, verifies the cached or queried chip ID, binds
a command session, selects HIF `0x23`, clears the kill flag and publishes launcher
readiness before the power worker starts. `-o 1` uses the original scalar power
argument 2; `-o 0` uses 1. A failed attempt is followed by cleanup, with at most
20 attempts. The command loop runs separately so patch searches can satisfy a
blocked power operation. Readiness describes the service, not a completed
firmware download.

The command broker must negotiate the exact version-2 limits. Each reply carries
its session and transaction identity and contains the complete normal or ROM
metadata set. Legacy untagged writes and metadata-setter ioctls are not used.
Expired reads can retry; expired replies are discarded without publishing
properties. Unknown commands receive a tagged `-EOPNOTSUPP` reply. In particular,
the old executable did not implement `update_patch_version`, and this service
does not claim support for that separate optional producer.

Shutdown withdraws the command session before joining the power worker. Firmware
logging uses repeated bounded ioctl passes in a separate worker; stopping joins
that worker before the final disable, including when it has not started yet.
Dynamic dump input is zero-padded to the kernel's 109-byte copy requirement.
Failed dynamic dump values remain pending for the next ordinary poll iteration.
If logging is still requested after its worker exits, the service joins that
worker before attempting one replacement in that iteration. A failed join
prevents reuse; a failed thread start can retry on a later iteration. Shutdown
still issues the final disable if the old worker was joined but its replacement
could not start. These optional failures do not stop command processing.
Normal, Wi-Fi and Bluetooth version properties are published only after the
kernel accepts metadata. Normal patch version selection is deterministic by
sequence, instead of the old directory-order, pre-validation publication.

The contract comes from offline analysis of the retained launcher ELF, paired source kernel and
existing MT6755 firmware headers. Its detailed addresses and input hashes are
recorded in the bring-up work repository's E-201 evidence. The decoder preserves
the original low-eight-bit firmware match, 15-byte published build version,
sequence/address interpretation and 264-byte metadata layout. It rejects
malformed counts, invalid sequences and duplicate/inconsistent metadata sets.

`test_patch.c` invokes the actual decoder using the two original
`ROMv2_lm_patch_1_0_hdr.bin` and `ROMv2_lm_patch_1_1_hdr.bin` files, in that order.
Seventeen test groups cover these headers and reversed sequence order, firmware
byte distinctions, all short-header sizes, malformed count/sequence values,
duplicate and incomplete sets, metadata bounds and build-version extraction.
Compile `patch.c` and `test_patch.c` together with ASan/UBSan, then pass the two
firmware paths. The first hash-bound result is retained in the trial directory
at `wmt-launcher-source-tests/patch-first/result.json`.

`README_protocol.md` covers the wire format and 18 codec test groups.
`README_firmware.md` covers filesystem failure handling and 60 firmware cases,
including synthetic ROM headers because this product has no ROM patch files.
`test_launcher.py --firmware-dir /path/to/vendor/firmware --output /new/output`
runs the complete service with actual pthreads and filesystem discovery against
bounded host device/property adapters. Thirty-five service cases pass ASan/UBSan,
and seventeen selected cases pass TSan. These adapters assert independent
literal ioctl numbers and wire identities. They cover normal/empty-ROM/unknown
commands, chip and readiness failures, old kernels, power retries and exhaustion,
copy/transport errors, stale replies, read expiry, optional controls and firmware
worker stop ordering. Kernel broker and firmware-log source tests remain separate
evidence; a passing host adapter is not proof of the paired kernel behavior.

The ten optional-retry cases use the complete `main.c` and real pthread creation
and joins. They cover unchanged dynamic dump values, repeated failures, firmware
log recovery, property toggles, replacement thread failure, disable retry and a
late-starting replacement. They assert at most one dynamic dump attempt or
replacement worker per ordinary poll iteration and no reuse or final disable
before the previous thread is joined. The original `ceeee48` source fails eight recovery assertions;
its existing disable-after-failure and disable-retry behaviors pass. Those raw
baseline results and the passing candidate runs are retained under
`wmt-launcher-source-tests/optional-retry/`.

The preceding service revision compiled and linked against Android API 29 for
ARM64 and ARM. Only ARM64 is selected by this product; ARM compilation checks
the shared ioctl layout. The optional-retry revision requires its final target
rebuild before integration. Build artifacts and raw test results are hash-bound
in the trial's `wmt-launcher-source-tests/`. No real version-2 handset execution has occurred
at this candidate stage.
