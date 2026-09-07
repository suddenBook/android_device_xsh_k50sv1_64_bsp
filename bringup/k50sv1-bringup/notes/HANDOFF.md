# Handoff

The phone runs **clean signed Tier 3 build24**, `eng.desmon.20260907.170801`,
with kernel `ef8238aca4c`, Linux 3.18.119 built
`Mon Sep 7 17:12:50 CEST 2026`. SELinux and privileged-permission enforcement
are active; user/debuggable0/secure1/adbsecure1 and root rejection pass live.
The separate diagnostic userdata fixture enabled authenticated UID-2000 ADB for
completed runtime testing. Final ADB disable passed with the same physical USB
device observed as MTP-only. Normal SetupWizard UI and local feature tests have
completed; peer/carrier/physical limits remain in the work-item list. [Release record](../evidence/device-review-20260907/tier3-release/README.md).
The preceding complete build21 baseline (`69faa749fff`, four images and a data
wipe) has **227 PASS, 0 FAIL, 3 carrier-IMS UNREAD**, with current-ROM predecessor
pstore checked. Multimedia,
networking and vold boundary results are bound by the [Tier-2 receipt](../evidence/device-review-20260907/tier2-live/receipt.json).
A setup-transition Trebuchet crash has a prepared one-line upstream patch;
the owner declined further upstream edits on 2026-09-07 because LineageOS 17.1
is frozen. It remains an accepted limitation; the patch is not applied.
Logo cert records are repaired and read back.
The normal Tier-3 transition did not repeat that crash. Google SetupWizard's
network page stayed stale despite validated Wi-Fi; normal Skip → Continue
completed setup. The owner accepts this old-app/new-encryption compatibility
limit and Play's expected uncertified state. SetupWizard later removed its own
network; normal Settings reconnection restored Wi-Fi and HTTPS browsing.
Kernel `ef8238aca4c` repairs WMT/STP module-exit lifetimes. Its 168 host cases,
381 module ABI pairs and actual five-module unload/reload pass. Hardware
off/on return `0`, session advances 1 → 2, and radio lifecycles recover on the
same untainted boot. [Build/runtime evidence](../evidence/device-review-20260907/wmt-lifecycle/README.md).
[Current review](../evidence/E-210.md), [remaining work](../workitems.md).

## Sources and reproduction

The three source repositories and first Tier-3 image release are now public.
All have `main` and `v1.0.0`; device/vendor retain their commit histories, while
kernel publishes the complete current-source snapshot because historical Git
objects were missing. [Release and publication receipt](../evidence/device-review-20260907/github-release/README.md).
The GitHub release includes all five required images, including the repaired
HarmonyOS logo, plus checksums, flashing instructions and original build
provenance. Their remote sizes and SHA-256 digests were verified.

| State | Location / revision |
|---|---|
| Installed kernel | `ef8238aca4c` (complete clean build24) |
| Installed device / vendor | `a76fb0b` / `65d7211` |
| Build-processed WFO JAR | `a038a13826575709270d6f16ce3697bde9fe6b024affc26e03b3971eb8904639` |
| Camera parameter library | `25fe4a83ce842d4b532a6f77ae223a8aa526652eb623d018b126f6aae2365f02` |
| Build-processed IMS APK | `d568e6482a7dba5e63ecef8ec8b1e8218211cd28dbf71d68324f2d77a9483fbd` |
| Maintained source repositories | `main` in `work/.capture-staging/device-review-20260907/{device,vendor,kernel}` and the matching build-workspace repositories; [adoption](../evidence/device-review-20260907/source/main-adoption.json) |
| Full build workspace | `work/.capture-staging/source-replacement-20260905/build-project/` |
| Tested build19 fallback | `work/.capture-staging/source-replacement-20260905/tier1-source-stack-20260907-wmt-command-v2-clang/` |

[Build19 provenance](../evidence/E-209.md) binds its stage, installed readback,
23 source-provider files, five source connectivity modules and raw runtime
results. Kernel and WMT launcher use a paired v2 command protocol and must be
installed together. The original 506-file vendor inventory remains immutable;
source replacements have a separate adoption ledger. Original and build-processed
APK/JAR bytes are different evidence categories.

Work under `work/`, preserve other agents' changes and commit each logical change.
The owner authorized publishing the device/vendor/kernel repositories and the
first Tier-3 device release on 2026-09-07; the earlier no-push rule continues
to apply outside that scope. Prefer primary AOSP/Linux guidance, then same-platform source,
then measured stock contracts. Android upstream changes require the owner's
agreement. Preserve the recorded font, base-APN typing and Tinycompress
header integration already present in the build inputs. All routine build,
flash, wipe and SetupWizard choices are delegated. Wait for all assigned code
reviews before the final build.

Use the full wrapper with explicit `K50SV1_BUILD_TIER` and stage/flash tools
from that build workspace. Product changes require a clean product output.
Kernel-only changes may clean only `KERNEL_OBJ` and reuse matching Android
outputs, but must repack boot/recovery and validate all five module ABIs.
Never reuse a relocated output's absolute Ninja graph blindly.

Tier 1: permissive, root/insecure adb. Tier 2: enforcing, root/insecure adb.
Tier 3: signed user build, enforcing, adb off by default, no legacy WFC tunnel.
Tier 2 has passed local runtime validation; carrier IMS remains conditional.
The complete Tier-3 release passes its build/signing/artifact gates, non-root
boot, local runtime checks and final observed ADB-off state. Build22 compiled but
failed actual PRESIGNED verification: the gate incorrectly rejected CTS fixtures,
and JNI/DEX processing damaged three APK signatures. See the
[release repair](../evidence/device-review-20260907/presigned-apks/README.md).
Build23 passes actual APK verification but failed on incorrect property-gate
assumptions. The [property repair](../evidence/device-review-20260907/property-layout/README.md)
passes both the actual independently re-signed archive and formal clean build24.
All four build24 images are flashed. Six fresh Tier-3
identities have passed the keyset validator. Their directory
is private, wholly Git-ignored and outside the build project; published keys
remain revoked. Signing does not add AVB,
hardware attestation or rollback protection. Data is unencrypted by owner choice.

For a planned release runtime fixture, `K50SV1_FLASH_REBOOT=0` leaves the
verified flash in fastboot and records `operation.reboot=deferred`. The normal
default remains automatic reboot. The rooted Tier-1/2 verifier still requires
the receipt's successful reboot; its checks are not relaxed for a deferred run.

OS flashing owns boot/recovery/system/vendor. Logo has a separate authorized
repair path. Preserve bootloader, modem, NVRAM, nvdata, protect and calibration
partitions. Factory inputs are read-only and have a 37-file checksum manifest.
Wipes of userdata/metadata/cache are discretionary and must be recorded.

## Measurements and current boundaries

Select USB adb serial `0123456789ABCDEF`; network adb may name the same phone.
Compare boot IDs before treating transports as different devices. Capture early
kernel logs, then activate camera/video, audio, graphics/WebView, Wi-Fi and BT
before a feature-policy conclusion. Absence of a previously cached permissive
AVC is not proof that Enforcing will work. Pstore belongs to the preceding boot.

Tier 2 passes Wi-Fi IPv4 traffic, Bluetooth discovery/shutdown, P2P group
creation/removal, WebView rendering and GNSS start/status/stop (122 callbacks,
20 satellites reported, zero fixes indoors). The repaired autofocus/flashlight drivers pass live. Current camera
lists contain 12 rear and 11 front modes, with matching default/encoded JPEGs
at 3264×2448 and 2560×1920; the prior Snap old-size fallback checks also pass.
Real video/audio, sensors, 32-bit Surface readback and Mali EGL drawing pass.
Dynamic recording fully decodes 336 frames, with 288 distinct frame hashes.
Current Tier-3 Snap shutter samples are rear 570/633 ms and front 327 ms; these do
not establish a latency distribution, dark-scene result or hardware ceiling.
Tier 3 also fully decodes 188 frames of 1080p/AAC camera video and 227 dynamic
screenrecord frames (187 distinct), and passes GNSS start/status/stop with 120
callbacks and no indoor position fix. Five probe APKs and five test media files
were removed. Screen timeout is 121000 ms, charging stay-awake is 0, Bluetooth
is OFF, and both subscription data settings remain OFF.
Trebuchet is the normal HOME; Niagara is absent. Completed owner tests
of recovery display/touch/keys need not be repeated as open tasks.

The SIM fixture is CU 46001 in slot 0 and CMCC 46000 in slot 1, roaming in the
Netherlands; visited networks can change and slot 1 lacks LTE. Ten device IMS
APNs use 3GPP+IWLAN mask 512903. Current roaming observations are not a home-IMS
pass. No arbitrary call or emergency test is authorized by a missing destination.
Keep the NVRAM ABI property `ro.vendor.mtk_eccci_c2k=1`, SAP/VSIM consumers and
cellular dependencies of the ePDG-capable RIL flag; names alone do not prove
physical CDMA or unused services. See [IMS](vowifi-feasibility.md).

USB prevents normal suspend. Measure standby unplugged, screen off, with network
adb disconnected and natural Doze entry. For i2c-4 compare IRQ120's all-CPU count
in `/proc/stat` within one boot. Battery `charge_counter` is integer UI SOC times
nominal capacity, not measured energy; hardware CAR requires signed decoding
and reset tracking. The cell is 3200 mAh nominal; usable capacity and donor
OCV/resistance curves remain uncalibrated.

Before vold maintenance, verify the installed nvdata/protect fstab entries
carry notrim. Do not run it on the build19 fallback, which lacks those flags.
The original build19 kernel's `/proc/mtk_battery_cmd/current_cmd` read stops
charging. The installed review kernel fixes this; 100 repeated reads preserve
the control flag and charger state. Tier 2's installed notrim flags and actual
/data+/cache-only maintenance pass. A separate open-only probe in the vold domain
opens /data and receives EACCES for all three calibration stores. Its deliberate
denials are isolated after the positive feature capture; no trim is sent to them.

Retain the owner's screen-on PPM boost/screen-off release, disabled CPUSETS,
and the complete BBLPM radio-off predicate. On a recurring Volume Up fault,
capture `kpd_hw` and `kpd:`/`GUARDED` logs before recovery or reboot. A successful
short key test does not explain an intermittent fault.

Detailed physical and product facts live in [hardware](hardware-verification.md),
[source providers](aosp-source-migration.md), [policy](sepolicy.md) and
[F2FS](f2fs-feasibility.md). Keep only current decisions and remaining tests here.
