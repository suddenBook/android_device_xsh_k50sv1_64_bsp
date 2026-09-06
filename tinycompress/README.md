# Kernel audio headers for Tinycompress

The existing external/tinycompress module compiles its original two C sources
for ARM and ARM64. A one-line local integration patch selects this device's
k50_tinycompress_kernel_headers module; its source and installed
libtinycompress.so ABI remain unchanged.

The generic Lineage header module exports all generated ARM64 kernel headers
to both architectures. The actual third full-build attempt failed because
Bionic's 32-bit signal.h selected ARM64 asm/sigcontext.h. Changing its register
type would still expose the wrong signal-context layout to ARM clients.

This device generator runs the existing kernel headers_install flow, then
exports only sanitized sound/asound.h, sound/compress_params.h and
sound/compress_offload.h. Bionic supplies generic and per-ABI headers. Both
consumers therefore retain the current source kernel's compressed-audio ioctl
layouts without importing ARM64 signal context into ARM code.

The exact external/tinycompress change is retained in the bring-up work
repository at upstream/tinycompress-kernel-headers.patch, against
848ec3ad67cc414294d18776a2b4d644be95fd64. It is committed on a local source branch
and captured by the full Android repo manifest. No remote push is required.
A separate provider with the same installed filename was rejected by Android
Q's duplicate install-rule check even with module overrides, so it is not used.
