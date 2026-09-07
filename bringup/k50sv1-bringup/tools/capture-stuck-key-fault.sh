#!/usr/bin/env bash
#
# Run this WHILE the stuck-key fault is present: Volume Up behaves as if held,
# Volume Down still changes volume, and the Power button no longer lights the
# screen.
#
# What it is for
# --------------
# The framework-side chain is already understood and does not need re-proving:
# a VOLUME_UP down with no matching up latches PhoneWindowManager's
# mA11yShortcutChordVolumeUpKeyTriggered, interceptPowerKeyDown() then sets
# mPowerKeyHandled and never calls wakeUpFromPowerKey(), and holding
# VOL_UP + POWER long enough reaches the PMIC hard reset. What is NOT yet
# established is which input device originates the stuck down and whether the
# kernel's own key bitmap is latched. Those are the two questions this answers:
#
#   1. keystate-probe reads EVIOCGKEY per device. If a bit is DOWN there, the
#      fault is in the kernel/driver/hardware. If every bit is up while the
#      framework still thinks a key is held, the fault is a userspace state
#      leak and is fixable in the device tree.
#   2. dumpsys input reports KeyDowns per device, i.e. what InputReader
#      believes. Comparing the two localises the desync.
#
# The two candidate originators are mtk-kpd (the real matrix keypad) and ACCDET
# (the PMIC jack-detect comparator, on a chassis that has no 3.5 mm jack).
#
# Everything here is read-only. Nothing is injected, nothing is rebooted.

set -euo pipefail

SERIAL="${1:-${ANDROID_SERIAL:-}}"
if [[ -z "${SERIAL}" ]]; then
    printf 'usage: %s <adb-serial>\n' "$0" >&2
    printf '   or: ANDROID_SERIAL=<serial> %s\n' "$0" >&2
    exit 2
fi

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# A PATH adb is not necessarily the platform-tools 37 build this device needs,
# and HANDOFF records that that build requires ADB_LIBUSB=1 to enumerate this
# single-interface MTK gadget at all. Every other tool here pins ADB_BIN.
ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
export ADB_LIBUSB="${ADB_LIBUSB:-1}"
PROBE="${TOOL_DIR}/keystate-probe/out/keystate-probe"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${TOOL_DIR}/../evidence/stuck-key-${STAMP}"

adb() { "${ADB_BIN}" -s "${SERIAL}" "$@"; }

if [[ ! -x "${ADB_BIN}" ]]; then
    printf 'adb is not executable: %s\n' "${ADB_BIN}" >&2
    exit 2
fi
if ! adb shell true >/dev/null 2>&1; then
    printf 'handset %s is not reachable over adb\n' "${SERIAL}" >&2
    exit 1
fi
if [[ ! -x "${PROBE}" ]]; then
    printf 'build the probe first: keystate-probe/build.sh $ANDROID_NDK_ROOT\n' >&2
    exit 1
fi

mkdir -p "${OUT}"
printf 'capturing to %s\n' "${OUT}"

# 1. Kernel truth: the per-device key bitmap.
adb push "${PROBE}" /data/local/tmp/keystate-probe >/dev/null
adb shell 'chmod 755 /data/local/tmp/keystate-probe && /data/local/tmp/keystate-probe' \
    >"${OUT}/kernel-key-bitmap.txt" 2>&1

# 2. Framework belief: per-device KeyDowns/MetaState, and the resolved key maps.
adb shell dumpsys input >"${OUT}/dumpsys-input.txt" 2>&1

# 3. Whether the screen-off path is the one being blocked.
adb shell dumpsys power >"${OUT}/dumpsys-power.txt" 2>&1

# 4. Sixty seconds of raw events. With the fault present this should be silent
#    for Volume Up (the kernel only reports transitions, and it never
#    transitions), while Volume Down still produces clean down/up pairs. Press
#    Volume Up, Volume Down and Power a few times while this runs.
printf 'press Volume Up, Volume Down and Power a few times over the next 60s...\n'
adb shell 'timeout 60 getevent -lt' >"${OUT}/getevent-60s.txt" 2>&1 || true

# 5. Keypad and PMIC interrupt counters, twice, five seconds apart: a storming
#    IRQ and a dead IRQ look very different here.
for pass in 1 2; do
    adb shell 'cat /proc/interrupts' >"${OUT}/interrupts-${pass}.txt" 2>&1
    [[ "${pass}" == 1 ]] && sleep 5
done

# 6. Suspend/resume history -- the fault only appears after a long idle.
adb shell 'cat /sys/kernel/debug/suspend_stats' >"${OUT}/suspend-stats.txt" 2>&1 || true
adb shell 'dmesg' >"${OUT}/dmesg.txt" 2>&1 || true

# 7. The previous boot, in case this capture follows a watchdog reset.
adb shell 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null || cat /proc/last_kmsg 2>/dev/null' \
    >"${OUT}/last-boot-console.txt" 2>&1 || true

adb shell rm -f /data/local/tmp/keystate-probe >/dev/null 2>&1 || true

# The bitmap is the decisive line; surface it immediately.
printf '\n--- kernel key bitmap ---\n'
grep -E 'name=|asserted' "${OUT}/kernel-key-bitmap.txt" || true
printf '\n--- InputReader KeyDowns ---\n'
grep -B12 'KeyDowns: [1-9]' "${OUT}/dumpsys-input.txt" | grep -E '^  Device|KeyDowns|MetaState' || \
    printf 'InputReader reports no keys down on any device\n'

( cd "${OUT}" && sha256sum ./* >SHA256SUMS )
printf '\ncapture complete: %s\n' "${OUT}"
