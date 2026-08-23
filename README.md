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
| 1 (default) | `userdebug` | permissive | unauthenticated root | development/test keys | first boot and complete log capture |
| 2 | `userdebug` | enforcing | unauthenticated root | development/test keys | policy validation with full diagnostics |
| 3 | `user` | enforcing | disabled (USB defaults to MTP) | committed private release keys | private daily-use images |

Run the build wrapper from the workspace with the desired tier:

```bash
K50SV1_BUILD_TIER=1 work/k50sv1-bringup/tools/run-lineage-build.sh
K50SV1_BUILD_TIER=2 work/k50sv1-bringup/tools/run-lineage-build.sh
K50SV1_BUILD_TIER=3 work/k50sv1-bringup/tools/run-lineage-build.sh
```

Tiers 1 and 2 build `boot.img`, `recovery.img`, `system.img`, and
`vendor.img` directly. Tier 3 uses a target-files package only as a temporary
release-signing intermediate, then publishes the same four standalone images
plus `SHA256SUMS`; it does not build or publish an OTA package. Recovery's
explicit sideload mode remains available, but normal Tier 3 Android boots do
not expose adbd.

Tier 1 intentionally retains policy/domain transitions and AVC logging while
allowing denials, so it is the correct first bring-up target. Do not treat a
successful permissive boot as evidence that Tier 2 is ready; promote only after
reviewing complete boot, radio, media, suspend/resume, and shutdown logs.

The Tier 3 private keys are intentionally committed for this owner's private
single-device workflow. They must be treated as publicly disclosed and must
never be reused for another device or a public ROM; see `security/README.md`.
