# Source Tinycompress for the K50

The device module compiles the existing external/tinycompress sources for
both ARM and ARM64. It installs libtinycompress.so with that same ELF SONAME.
No implementation or installed vendor ABI is renamed, and no source snapshot
or precompiled library is copied into this directory.

The upstream Lineage module exports all generated ARM64 kernel headers to
both architectures. During the actual third full-build attempt, Bionic's
32-bit signal.h selected the generated ARM64 asm/sigcontext.h and failed on
its 128-bit register type. Changing that type would still expose the wrong
signal-context layout to an ARM client.

The device header module runs the existing kernel headers_install flow, then
exports only its sanitized sound/asound.h, sound/compress_params.h and
sound/compress_offload.h. Bionic supplies the remaining generic and per-ABI
headers. Both consumers therefore retain the current source kernel's compressed
audio ioctl layouts without importing its ARM64 signal context into ARM code.
Kernel header and exporter-script changes invalidate the generated output.

The module uses the same two C sources, include directory, compiler warnings,
shared dependencies and upstream NOTICE. The K50 does not enable Lineage's
optional extended-compress-format flag. Selecting libtinycompress_k50 in the
product avoids compiling/installing the upstream module as a second provider.
The ordinary four-image build and subsequent ELF/handset audio checks validate
the actual installed output.
