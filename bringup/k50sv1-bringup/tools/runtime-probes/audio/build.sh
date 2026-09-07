#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

probe_ndk="${ANDROID_NDK_ROOT:-/home/desmond/Android/Sdk/ndk/30.0.15729638}"
probe_compiler="$probe_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang"
"$probe_compiler" --version > compiler-version.txt
"$probe_compiler" -std=c11 -O2 -Wall -Wextra -Werror -fPIE -pie \
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 \
    -Wl,-z,relro,-z,now aaudio_silence_probe.c -laaudio -o aaudio-silence-probe
sha256sum aaudio_silence_probe.c build.sh aaudio-silence-probe > SHA256SUMS
file aaudio-silence-probe
readelf -h -l -d -V aaudio-silence-probe > elf-report.txt
cat SHA256SUMS
