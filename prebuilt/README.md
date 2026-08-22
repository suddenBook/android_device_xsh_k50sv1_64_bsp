# Prebuilt boot artifacts

- `kernel`: compressed Stock arm64 Linux 3.18.119 kernel payload
- `dtb/stock.dtb`: exact 68,438-byte Android DT table from Stock boot header v2
- `recovery_dtbo`: exact 39,063-byte recovery DTBO payload

Do not replace `dtb/stock.dtb` with a raw FDT while using the Stock LK selection
path. It is the sole `BOARD_PREBUILT_DTBIMAGE_DIR` input, so Q's concatenation
step reproduces the exact table and tracks it as a build/target-files dependency.

After each build, unpack boot and recovery images and verify their header
addresses plus these payload hashes before flashing.
