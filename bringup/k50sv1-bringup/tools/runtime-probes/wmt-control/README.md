# Native WMT rejection probe

`reject.c` checks the installed source kernel through the real `/dev/stpwmt`
ioctls. Its 18 requests contain invalid counts, sequences, ROM types,
unterminated metadata names, invalid user pointers or malformed dynamic-dump
values. The repaired code rejects each before changing stored metadata or the
platform dump table. It does not submit valid replacement metadata, firmware,
power-control, reset or assertion requests.

Compile with the installed Android NDK for ARM64 and ARM, using API 29:

```sh
aarch64-linux-android29-clang -O2 -Wall -Wextra -Werror reject.c -o reject-arm64
armv7a-linux-androideabi29-clang -O2 -Wall -Wextra -Werror reject.c -o reject-arm
```

The pointer-sized command definitions deliberately exercise the native and
compat ioctl entry points. Their 264-byte metadata layout and offsets match
`common_main/core/include/wmt_lib.h`; command encodings and the 109-byte dump
input match `common_main/linux/wmt_dev.c`.

Before running either copy, bind the device's installed `wmt_drv.ko` SHA-256 to
the source-module digest and source revision in the completed build's receipt.
Capture boot ID, taint, WMT service PID/properties and a kernel
stream across both runs, then confirm the same identity, no new fault and
working Wi-Fi traffic afterward. Keep the native output and executable hashes
with the receipt. These checks complement the source-function sanitizer and
concurrency fixtures; they do not inject real allocation failures or kernel
thread races. The [current review](../../../evidence/E-210.md) identifies tested
bundles; each new probe run needs its own bound evidence.
