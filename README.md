# LineageOS device tree for k50sv1_64_bsp

Android 10 / LineageOS 17.1 bring-up for the XSH F212/RUNSUI_B64 board sold
under a falsified `S26 Ultra` identity.

Verified baseline:

- MT6755 BSP/ABI, MT6750-class E2 performance bin
- arm64 with 32-bit secondary ABI; 4 GiB LPDDR3
- legacy A-only GPT; separate boot/recovery; no dynamic partitions or AVB
- Stock Linux 3.18.119 prebuilt kernel and Android DT table
- 720x1560 at 60 Hz; FT8057 touch; IMX145 + GC5025 HAL1 cameras
- MIR3DA accelerometer and functional Hall/stylus-slot switch
- two physical microphone apertures, one bottom speaker, earpiece and USB OTG
- no fingerprint, notification LED, NFC, 3.5 mm jack, light, proximity,
  compass, or gyroscope hardware

The authoritative evidence and AOSP decisions are maintained in
`../../../../work/k50sv1-bringup/`. Stock declarations are treated as hints,
not hardware proof.

The first bring-up intentionally omits Stock fingerprint and S Pen UI stacks,
identity spoofing, ADUPS FOTA, and engineering applications. The Hall input is
kept for diagnostics, but its unused wake key is explicitly suppressed.

## Build tiers

`K50SV1_BUILD_TIER` selects one of three deliberately separate configurations:

| Tier | Variant | SELinux | Android-system ADB | Signing | Intended use |
| --- | --- | --- | --- | --- | --- |
| 1 | `userdebug` | permissive | unauthenticated root | development/test keys | first boot and complete log capture |
| 2 | `userdebug` | enforcing | unauthenticated root | development/test keys | policy validation with full diagnostics |
| 3 | `user` | enforcing | not exposed by default (USB defaults to MTP) | rotated external release keys | private daily-use images; no verified boot or data encryption |

Tier 3 deliberately does not provide Wi-Fi calling. The extracted ePDG tunnel
embeds strongSwan 5.1.2, so the release tier filters its complete legacy
binary/library/config closure and both tunnel services, then resolves
`config_device_wfc_ims_available=false`. Tiers 1 and 2 retain it only for
controlled diagnostics while a modern source-compatible implementation is
developed. The MediaTek WFO HAL, IMSA/VoLTE daemons and WFC-named RIL build
flags remain on every tier because they are independently proven load-bearing
for cellular VoLTE; this is not a global IMS disable.

Run the build wrapper from the workspace with the desired tier:

```bash
K50SV1_BUILD_TIER=1 work/k50sv1-bringup/tools/run-lineage-build.sh
K50SV1_BUILD_TIER=2 work/k50sv1-bringup/tools/run-lineage-build.sh
K50SV1_BUILD_TIER=3 \
K50SV1_RELEASE_KEYS_DIR=/secure/path/outside/this/workspace \
    work/k50sv1-bringup/tools/run-lineage-build.sh
```

Tiers 1 and 2 build `boot.img`, `recovery.img`, `system.img`, and
`vendor.img` directly. Tier 3 uses a target-files package only as a temporary
release-signing intermediate, then publishes the same four standalone images
plus `SHA256SUMS`; it does not build or publish an OTA package. Recovery's
explicit sideload mode remains available, but normal Tier 3 Android boots do
not expose ADB in the default USB configuration. Authenticated non-root ADB can
still be enabled deliberately in Developer options.

Tier 1 intentionally retains policy/domain transitions and AVC logging while
allowing denials, so it is the correct first bring-up target. Do not treat a
successful permissive boot as evidence that Tier 2 is ready; promote only after
reviewing complete boot, radio, media, suspend/resume, and shutdown logs.

The old committed Tier 3 keyset is revoked. New Tier 3 builds require a rotated
external key directory and publish only non-secret certificate identities in
their provenance. See `security/README.md`.
