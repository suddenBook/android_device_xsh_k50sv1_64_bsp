# Prebuilt boot artifacts

- `kernel`: compressed Stock arm64 Linux 3.18.119 kernel payload
- `dtb`: exact 68,438-byte Android DT table from Stock boot header v2
- `recovery_dtbo`: exact 39,063-byte recovery DTBO payload

Do not replace `dtb` with a concatenated raw FDT while using the Stock LK
selection path. `BOARD_MKBOOTIMG_ARGS` supplies this table explicitly, so
`BOARD_INCLUDE_DTB_IN_BOOTIMG` must remain unset.

After each build, unpack boot and recovery images and verify their header
addresses plus these payload hashes before flashing.
