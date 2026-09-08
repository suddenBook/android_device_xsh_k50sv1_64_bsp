#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(mktemp -d /tmp/k50sv1-power-shim-test.XXXXXX)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT
CC_BIN="${CC:-cc}"
COMMON_FLAGS=(-std=gnu11 -D_GNU_SOURCE -Wall -Wextra -Werror -O2)

"${CC_BIN}" "${COMMON_FLAGS[@]}" -fPIC -fvisibility=hidden -shared \
    -DK50SV1_POWER_SHIM_HOST_TEST -Wl,-z,global,-z,relro,-z,now \
    "${HERE}/k50sv1_power_shim.c" -ldl -pthread -o "${TEST_DIR}/shim.so"
for fixture in normal missing-scalar missing-pair; do
    extra_flags=()
    [[ "${fixture}" != missing-scalar ]] || extra_flags=(-DOMIT_SCALAR)
    [[ "${fixture}" != missing-pair ]] || extra_flags=(-DOMIT_PAIR)
    "${CC_BIN}" "${COMMON_FLAGS[@]}" "${extra_flags[@]}" -fPIC -shared \
        -Wl,-soname,libpowerhal.so -Wl,-z,relro,-z,now \
        "${HERE}/fake_powerhal.c" -o "${TEST_DIR}/${fixture}.so"
done
"${CC_BIN}" "${COMMON_FLAGS[@]}" "${HERE}/test_power_shim.c" -ldl \
    -o "${TEST_DIR}/test_power_shim"

"${TEST_DIR}/test_power_shim" "${TEST_DIR}/shim.so" "${TEST_DIR}/normal.so" contracts
python3 - "${TEST_DIR}" <<'PY'
import pathlib
import resource
import signal
import subprocess
import sys

test_dir = pathlib.Path(sys.argv[1])
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
cases = [
    ("normal", "missing-library", "cannot find loaded libpowerhal.so"),
    ("missing-scalar", "missing-symbol", "cannot resolve libpowerhal.so _Z9set_valuePKci:"),
    ("missing-pair", "missing-symbol", "cannot resolve libpowerhal.so _Z9set_valuePKcii:"),
]
for fixture, mode, diagnostic in cases:
    result = subprocess.run(
        [str(test_dir / "test_power_shim"), str(test_dir / "shim.so"),
         str(test_dir / (fixture + ".so")), mode], capture_output=True, text=True)
    assert result.returncode == -signal.SIGABRT, (fixture, result.returncode, result.stderr)
    assert diagnostic in result.stderr, (fixture, result.stderr)
print("Power HAL shim missing backend/symbol fatal diagnostics: PASS")
PY
