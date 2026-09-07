#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'usage: %s ANDROID_NDK_ROOT [OUTPUT]\n' "$0" >&2
    exit 2
fi

NDK_ROOT="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${2:-$SCRIPT_DIR/out/sensor-probe}"
CC="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang"

if [[ ! -x "$CC" ]]; then
    printf 'compiler not found: %s\n' "$CC" >&2
    exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"

"$CC" \
    -std=c11 \
    -O2 \
    -fPIE \
    -pie \
    -Wall \
    -Wextra \
    -Werror \
    "$SCRIPT_DIR/sensor_probe.c" \
    -landroid \
    -llog \
    -o "$OUTPUT"

file "$OUTPUT"
sha256sum "$OUTPUT"
