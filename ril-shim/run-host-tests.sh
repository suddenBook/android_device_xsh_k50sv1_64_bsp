#!/usr/bin/env bash

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINEAGE_ROOT="$(cd "${HERE}/../../../.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/k50sv1-ril-shim-test.XXXXXX)"
cleanup() {
    find "${TEST_DIR}" -mindepth 1 -depth -delete
    rmdir "${TEST_DIR}"
}
trap cleanup EXIT

CC_BIN="${CC:-cc}"
"${CC_BIN}" \
    -std=gnu11 \
    -D_GNU_SOURCE \
    -DRIL_SHLIB \
    -DANDROID_MULTI_SIM \
    -DSIM_COUNT=2 \
    -Wall -Wextra -Werror \
    -I"${LINEAGE_ROOT}/hardware/ril/include" \
    "${HERE}/test_radio_capability.c" \
    -ldl -pthread \
    -o "${TEST_DIR}/test_radio_capability"

"${TEST_DIR}/test_radio_capability"
