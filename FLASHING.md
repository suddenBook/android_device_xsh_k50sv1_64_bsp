# Installing v1.0.0

This release is for the **XSH `k50sv1_64_bsp` board with its original partition
layout and stock bootloader/modem firmware**. It contains the final LineageOS
17.1 / Android 10 Tier-3 build: `user`, release-signed, SELinux enforcing, and
ADB disabled by default. The device must already have an unlocked bootloader.

## Downloads

Download these five images and `SHA256SUMS` from the same
[v1.0.0 release](https://github.com/suddenBook/android_device_xsh_k50sv1_64_bsp/releases/tag/v1.0.0):

| File | Partition | Bytes |
| --- | --- | ---: |
| `boot.img` | `boot` | 8,408,198 |
| `recovery.img` | `recovery` | 14,636,170 |
| `system.img` | `system` | 1,901,736,540 |
| `vendor.img` | `vendor` | 162,988,276 |
| `logo.img` | `logo` | 8,388,608 |

`logo.img` contains the owner's HarmonyOS boot graphic, with the repaired
factory certificate records preserved. It matches the image read back from
the tested handset. This remains LineageOS; the graphic does not change the OS.

Boot and recovery include the required DT payloads. There is no separate DTBO,
vbmeta or userdata image to flash for this release. This is a fastboot image
release, not a recovery-installable OTA ZIP. Existing modem, bootloader and
device calibration partitions are retained.

## Clean installation

**This procedure erases all user data, apps and accounts. Back up first.**
Use Android platform-tools, connect only the target phone, and enter its
bootloader fastboot mode. If USB debugging is enabled and authorized,
`adb reboot bootloader` can do this; otherwise use the device's boot menu.

From the directory containing all downloads, verify the hashes:

```sh
sha256sum --check SHA256SUMS
fastboot devices
fastboot getvar product
```

All five checksum results must be `OK`, and the product must be
`k50sv1_64_bsp`. Stop if either check fails. Run the following in Bash; `set -e`
stops the sequence if any operation fails:

```sh
set -e
fastboot erase userdata
fastboot erase metadata
fastboot erase cache
fastboot flash boot boot.img
fastboot flash recovery recovery.img
fastboot flash system system.img
fastboot flash vendor vendor.img
fastboot flash logo logo.img
fastboot reboot
```

Check that each erase/flash succeeds. If the bootloader does not support an
erase command, stop; do not guess a partition size or substitute another
device's image. The first boot creates the unencrypted F2FS userdata filesystem.
Keep the bootloader unlocked for this custom build.

## First boot and known limits

ADB starts disabled. Enable Developer options and USB debugging in Settings
only if needed. Google and Huawei applications are already included; no
additional GApps flash is required.

The old Google setup wizard can fail with some modern Wi-Fi encryption modes.
Skip that step and join the network through Settings after setup. Play Store
device uncertification is a known condition of this build. Carrier calls/IMS,
long unplugged standby, outdoor GNSS fixes and peer Wi-Fi Direct transfer have
not all completed acceptance testing; see [README.md](README.md) for the tested
scope. Do not interpret release publication as verification of those cases.
