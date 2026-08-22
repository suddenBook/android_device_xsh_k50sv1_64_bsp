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
