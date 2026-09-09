# LineageOS 17.1 for XSH k50sv1_64_bsp

Android 10 device support for the XSH F212 / RUNSUI_B64 board, sold under a
falsified “S26 Ultra” identity. This tree describes the hardware verified on the
tested handset. Product properties and fingerprints are generated from the real XSH device
and Lineage build. This does not confer Play certification.

## Hardware

| Component | Verified configuration |
| --- | --- |
| Platform | MediaTek MT6755 BSP/ABI; MT6750-class E2 performance bin |
| CPU | Eight Cortex-A53 cores; owner-selected 1.807 GHz big cluster, ARM64 and ARM32 userspace |
| GPU | Mali-T860, Midgard r29p0 driver; OpenGL ES 3.2 |
| Memory | 4 GiB LPDDR3 nominal |
| Storage | Micron S0J9F8 eMMC 5.1; 62,537,072,640-byte raw user area, 64 GB class |
| Display / touch | 720 × 1560 at 60 Hz; FT8057 five-point touchscreen |
| Cameras | Rear IMX145 driver, 8 MP class; front GC5025, 5 MP; HAL1 / Camera2 LEGACY |
| SIM / expansion | Two SIM slots, dual SIM dual standby; separate microSD slot |
| Audio / USB | Bottom speaker, earpiece, two physical microphone apertures; USB-C analog headset and USB OTG |
| Sensors / input | MIR3DA accelerometer, Hall/stylus-slot switch; passive capacitive stylus |
| Other fitted hardware | Rear flash LED and ERM vibrator |
| Battery | Cell marked 3.8 V, 12.16 Wh, 3200 mAh; charge curves remain uncalibrated |
| Kernel | Source-built Linux 3.18.140 with retained stock DT payloads; validation scope below |
| Partition layout | A-only static GPT, separate boot and recovery; F2FS userdata and ext4 cache |

There is no fitted fingerprint reader, NFC, infrared transmitter, wireless
charging, notification LED, 3.5 mm socket, ambient-light sensor, proximity sensor,
gyroscope or compass. The stylus has no pressure, hover, buttons or Bluetooth
capability. Unsupported stock declarations and their UI components are omitted.

## Sources

Place the three repositories in an Android source checkout as follows:

| Repository | Android checkout path |
| --- | --- |
| [Device configuration](https://github.com/suddenBook/android_device_xsh_k50sv1_64_bsp) | `device/xsh/k50sv1_64_bsp` |
| [Proprietary vendor files](https://github.com/suddenBook/android_vendor_xsh_k50sv1_64_bsp) | `vendor/xsh/k50sv1_64_bsp` |
| [Kernel source](https://github.com/suddenBook/android_kernel_xsh_k50sv1_64_bsp) | `kernel/xsh/k50sv1_64_bsp` |

Use the `lineage-17.1` branch of all three repositories. In the owner's
workspace they remain under `device/android_{device,vendor,kernel}_xsh_k50sv1_64_bsp`
and are linked into the Android checkout. Current build/import/replay tools and
logs live in the sibling `bringup/` repository (`bringup/BUILDING.md`). The Q
Soong integration needs the reviewed `ALLOW_BP_UNDER_SYMLINKS` backport for
this linked layout.

The extraction scripts accept `ANDROID_BUILD_TOP`; `extract-files.sh` also accepts
`--android-root ROOT`, and `setup-makefiles.sh` accepts an optional root argument.
Without an override they resolve the checkout link or the sibling `lineage-17.1`
workspace. Use `./extract-files.sh --android-root /path/to/lineage-17.1 /path/to/dump`.
Extraction, fixup or makefile-generation failure restores the
previous proprietary files and generated makefiles. `-n`/`-s` preserve unselected
blobs but still use this recovery mechanism. Standalone makefile generation
validates its temporary outputs before replacing the existing files.

The product requires the locally imported Google apps, Google WebView,
AppGallery and HMS Core. LineageSetupWizard owns initial setup; Google
SetupWizard is excluded. Chrome replaces Jelly and Photos replaces Gallery2.
AudioFX, Email and its Exchange2 service are omitted from this app set.

The owner deliberately selects 1.807 GHz, removes PPM thermal throttling at
boot completion, runs all cores at maximum while the display is on, and keeps
one little core in display-off standby. Preserve this policy during maintenance.

## Current bring-up and historical release

Android has been restored from SailfishOS, and Tier 1/2 runtime checks are
recorded. Linux 3.18.140 has passed both-tier compilation, module ABI and final-image
checks; stepwise handset testing has reached 3.18.140. See the
[current workspace handoff](../../bringup/k50sv1-bringup/notes/HANDOFF.md) for
image-bound results and remaining validation. The earlier v1.0.0 Tier-3 build
and its hardware captures describe their own revisions only.

The final enforcing checks cover all 121 effective Google/Huawei runtime
permissions, requested background and power exemptions, recovery/F2FS, and
MTK video capture and ordinary-app PixelCopy after the graphics policy fixes.

The factory LK reports userdata as ext4, while Android uses F2FS. Never use
`fastboot -w` or `fastboot format userdata`. For a clean install erase userdata,
metadata and cache explicitly, flash matching boot/recovery/system/vendor
images, and let Android's formattable F2FS fstab create `/data`. Instructions
for the current workspace are in `bringup/FLASHING.md`.

## Known limitations

- Play Store reports the device as uncertified. This is an accepted condition
  of the build.
- The HOME-transition receiver fix passes its host regression. The current
  workspace also records the fresh Android installation and owner-completed
  Lineage setup; the receiver edge cases are covered by the host test.
- Front-camera exposure still needs a confirmed lit, unobstructed scene;
  successful preview/JPEG delivery alone does not establish image quality.
- Google/Huawei authentication and synchronization remain untested. HMS
  secondary-dex AOT mitigated startup provider timeouts in repeated boots,
  but the original SCREEN_OFF ANR is not proven eliminated. The compilation
  cache may need rebuilding after application-data or dynamic-kit changes.
- Carrier calls and IMS/VoLTE have not completed home-carrier acceptance.
  Tier 3 omits the legacy ePDG tunnel and disables Wi-Fi calling; the remaining
  cellular IMS components do not establish carrier compatibility by themselves.
- Wi-Fi Direct local group lifecycle was exercised during bring-up. Peer group
  formation and an actual file transfer have not been accepted.
- Outdoor GNSS fixes, long unplugged standby, battery calibration and an
  intermittent Volume Up input issue remain open validation or repair items.

## Development tiers

| Tier | Variant | SELinux | Android-system ADB | Signing |
| --- | --- | --- | --- | --- |
| 1 | `userdebug` | Permissive | Unauthenticated root | Development keys |
| 2 | `userdebug` | Enforcing | Unauthenticated root | Development keys |
| 3 | `user` | Enforcing | Disabled by default; authenticated non-root when enabled | External release keys |

Tiers 1 and 2 are diagnostic configurations. They retain legacy Wi-Fi calling
components for controlled investigation. Use `bringup/build.sh` for the current diagnostic tiers. Tier 3 requires
future owner authorization and its separate signing workflow.
