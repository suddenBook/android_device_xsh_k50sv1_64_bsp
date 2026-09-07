#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
probe_ndk=/home/desmond/Android/Sdk/ndk/30.0.15729638
probe_cc="$probe_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang"
"$probe_cc" --version > compiler-version.txt
"$probe_cc" -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror -fPIE -pie \
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wl,-z,relro,-z,now \
    wmt_adie_probe.c -o wmt-adie-probe
sha256sum wmt_adie_probe.c build.sh wmt-adie-probe > SHA256SUMS
readelf -h -l -d -V wmt-adie-probe > elf-report.txt
file wmt-adie-probe
