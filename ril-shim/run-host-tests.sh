#!/usr/bin/env bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Pass the Android checkout when running from a standalone device repository.
LINEAGE_ROOT="${1:-${ANDROID_BUILD_TOP:-$(cd "${HERE}/../../../.." && pwd)}}"
[[ $# -le 1 && -f "${LINEAGE_ROOT}/hardware/ril/include/telephony/ril.h" ]] || {
    echo "Usage: $0 [Android source root]" >&2
    exit 2
}
TEST_DIR="$(mktemp -d /tmp/k50sv1-ril-shim-test.XXXXXX)"
cleanup() {
    find "${TEST_DIR}" -mindepth 1 -depth -delete
    rmdir "${TEST_DIR}"
}
trap cleanup EXIT

CC_BIN="${CC:-cc}"
COMMON_CFLAGS=(
    -std=gnu11
    -D_GNU_SOURCE
    -DRIL_SHLIB
    -DANDROID_MULTI_SIM
    -DSIM_COUNT=2
    -Wall -Wextra -Werror
    -I"${LINEAGE_ROOT}/hardware/ril/include"
)

"${CC_BIN}" \
    "${COMMON_CFLAGS[@]}" \
    -fPIC -shared \
    -Wl,-z,relro,-z,now \
    -Wl,-soname,libfake-mtk-rilproxy.so \
    "${HERE}/fake_rilproxy.c" \
    -o "${TEST_DIR}/libfake-mtk-rilproxy.so"

"${CC_BIN}" \
    "${COMMON_CFLAGS[@]}" \
    "${HERE}/test_attach_apn_hooks.c" \
    -Wl,--export-dynamic \
    -ldl -pthread \
    -o "${TEST_DIR}/test_attach_apn_hooks"

"${CC_BIN}" \
    "${COMMON_CFLAGS[@]}" \
    "${HERE}/test_radio_capability.c" \
    -ldl -pthread \
    -o "${TEST_DIR}/test_radio_capability"

LD_LIBRARY_PATH="${TEST_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" \
    "${TEST_DIR}/test_attach_apn_hooks"
"${TEST_DIR}/test_radio_capability"
