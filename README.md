# LineageOS 17.1 for XSH k50sv1_64_bsp

Android 10 device support for the XSH F212 / RUNSUI_B64 board, sold under a
falsified “S26 Ultra” identity. This tree describes the hardware verified on the
tested handset. Its Android compatibility properties do not identify genuine
Samsung or Google hardware and do not confer Play certification.

## Hardware

| Component | Verified configuration |
| --- | --- |
| Platform | MediaTek MT6755 BSP/ABI; MT6750-class E2 performance bin |
| CPU | Eight Cortex-A53 cores, up to approximately 1.5 GHz; arm64 with 32-bit application support |
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
| Kernel | Source-built Linux 3.18.119 with retained stock DT payloads |
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

See [BUILDING.md](BUILDING.md) for the required workspace layout, additional
application repositories, existing Android patches and release-signing tools.
The three device repositories alone are not a complete Android build input set.

## Release and installation

Download matching images and checksums from
[Releases](https://github.com/suddenBook/android_device_xsh_k50sv1_64_bsp/releases).
Follow [FLASHING.md](FLASHING.md) for the exact board, partition checks and clean
installation procedure. The first release contains `boot.img`, `recovery.img`,
`system.img`, `vendor.img` and the tested `logo.img`. It is a fastboot image
release; there is no recovery-installable OTA ZIP.

The release uses Tier 3: an Android `user` build signed with external release
keys, SELinux enforcing, and ADB disabled by default. USB defaults to MTP;
authenticated non-root debugging can be enabled in Settings. The bootloader
remains unlocked, verified boot and rollback protection are not provided, and
userdata is deliberately unencrypted. Signing does not change those properties.
Historical development keys are revoked; see [security/README.md](security/README.md).

## Tested status

The final Tier-3 images passed the clean-build signing and source-kernel ABI
gates and were flashed together with a userdata wipe. Runtime checks confirmed
SELinux enforcing, release properties, rejection of `adb root`, and successful
setup completion to the launcher. Authenticated diagnostic ADB was used during
acceptance checks and disabled at the end.

| Area | Observed result and scope |
| --- | --- |
| Display / graphics / input | Display, touch, accelerometer, 32-bit Surface and Mali EGL probes passed |
| Cameras / recording | Rear and front still capture, 1080p video with AAC audio, and changing screen-recorded frames were verified |
| Wi-Fi / Internet | Wi-Fi association, IPv4, DNS and HTTPS worked; Google application UI was exercised |
| Bluetooth audio | Stereo AAC capture at 44.1 kHz met the existing tone-frequency tolerance; the full controller run retained a failure in its late post-playback route check |
| GNSS | Start/status/stop callbacks and satellite reports observed; an outdoor position fix has not been accepted |
| Recovery / accessories | Display, touch and keys, USB-C analog headset audio/microphone/buttons, and read-only USB OTG storage were checked during bring-up |

## Known limitations

- The older Google setup wizard can fail with some modern Wi-Fi encryption
  modes. Skip Wi-Fi during setup and connect through Settings afterward. Setup
  can also remove its saved network and turn Wi-Fi off before completion.
- Play Store reports the device as uncertified. This is an accepted condition
  of the build.
- A rare launcher failure during a setup transition remains unresolved. The
  final normal setup-to-home transition completed successfully.
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
components for controlled investigation. Use the wrapper documented in
[BUILDING.md](BUILDING.md); Tier 3 requires its complete signing and verification
pipeline.
