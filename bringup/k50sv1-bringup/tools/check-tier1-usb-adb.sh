#!/usr/bin/env bash

# Tight bring-up loop for the MT6755 legacy USB gadget. It deliberately emits
# counts and state only; transport serials and raw USB descriptors stay out of
# the output.

set -euo pipefail

# ADB_BIN, not ADB, and ADB_LIBUSB exported: HANDOFF says platform-tools 37
# needs ADB_LIBUSB=1 to enumerate this single-interface MTK device at all, and
# a tool whose whole subject is USB enumeration must not depend on the caller
# having exported it. check-volte-chain.sh and verify-post-flash.sh already use
# this spelling.
ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
export ADB_LIBUSB="${ADB_LIBUSB:-1}"
JOURNAL_SINCE="${1:-5 minutes ago}"

if [[ ! -x "${ADB_BIN}" ]]; then
    printf 'adb is not executable: %s\n' "${ADB_BIN}" >&2
    exit 2
fi

# `journalctl ... 2>/dev/null || true` made an unreadable journal -- no
# systemd-journal group membership, no persistent journal, journald not running
# -- produce an empty string, i.e. exactly what a clean journal produces. Both
# host gates below are then evaluated against zero lines and both pass. Take
# the status.
if ! kernel_journal="$(journalctl -k --since "${JOURNAL_SINCE}" --no-pager 2>&1)"; then
    printf 'HOST_JOURNAL=unreadable\n'
    printf '%s\n' "${kernel_journal}" >&2
    printf 'RESULT=FAIL reason=host_journal_unreadable\n'
    exit 1
fi

kernel_events="$(
    printf '%s\n' "${kernel_journal}" \
        | grep -E 'idVendor=18d1, idProduct=4ee[1-9]|no configurations|can.t read configurations|unable to enumerate USB device' \
        || true
)"

vid_pid_events="$(printf '%s\n' "${kernel_events}" | grep -Ec 'idVendor=18d1, idProduct=4ee[1-9]' || true)"
no_configuration_errors="$(printf '%s\n' "${kernel_events}" | grep -Ec 'no configurations|can.t read configurations|unable to enumerate USB device' || true)"

adb_table="$("${ADB_BIN}" devices -l 2>/dev/null || true)"
adb_usb_device_count="$(
    printf '%s\n' "${adb_table}" \
        | awk 'NR > 1 && $2 == "device" && /(^|[[:space:]])usb:/ { count++ } END { print count + 0 }'
)"
adb_usb_nonready_count="$(
    printf '%s\n' "${adb_table}" \
        | awk 'NR > 1 && NF >= 2 && $2 != "device" && /(^|[[:space:]])usb:/ { count++ } END { print count + 0 }'
)"

adb_root=false
selinux_mode=unavailable
if [[ "${adb_usb_device_count}" -eq 1 && "${adb_usb_nonready_count}" -eq 0 ]]; then
    # Capture, then match a here-string. `producer | grep -q` under pipefail is
    # trap 6, and here it would set adb_root=false on a root adbd and fail the
    # run with reason=tier1_root_adbd. `id` is one short line so the window is
    # narrow, but the same idiom on a 42 kB producer was measured returning 72
    # on a present match in check-volte-chain.sh this session.
    id_output="$("${ADB_BIN}" -d shell id 2>/dev/null)"
    if grep -q '^uid=0(root)' <<<"${id_output}"; then
        adb_root=true
    fi
    selinux_mode="$("${ADB_BIN}" -d shell getenforce 2>/dev/null | tr -d '\r' || true)"
fi

printf 'HOST_GOOGLE_USB_EVENTS=%s\n' "${vid_pid_events}"
printf 'HOST_CONFIGURATION_ERRORS=%s\n' "${no_configuration_errors}"
printf 'ADB_USB_DEVICE_COUNT=%s\n' "${adb_usb_device_count}"
printf 'ADB_USB_NONREADY_COUNT=%s\n' "${adb_usb_nonready_count}"
printf 'ADB_ROOT=%s\n' "${adb_root}"
printf 'SELINUX_MODE=%s\n' "${selinux_mode}"

if [[ "${no_configuration_errors}" -ne 0 ]]; then
    printf 'RESULT=FAIL reason=usb_configuration_descriptor\n'
    exit 1
fi

# HOST_GOOGLE_USB_EVENTS was computed, printed, and then asserted NOWHERE, so
# the one thing this tool exists to say -- "the gadget enumerated as a Google
# ADB device" -- was never actually checked. Everything below it only proves
# that SOME adb transport is usable. Zero events is not a pass; it means the
# window holds no enumeration record, which for a tool you run right after
# plugging the cable in is a real answer, not a missing one. Widen the window
# with the first argument if the handset was attached earlier.
if [[ "${vid_pid_events}" -eq 0 ]]; then
    printf 'RESULT=FAIL reason=no_google_adb_enumeration since=%s\n' "${JOURNAL_SINCE}"
    exit 1
fi

if [[ "${adb_usb_device_count}" -ne 1 || "${adb_usb_nonready_count}" -ne 0 ]]; then
    printf 'RESULT=FAIL reason=adb_transport\n'
    exit 1
fi

if [[ "${adb_root}" != true ]]; then
    printf 'RESULT=FAIL reason=tier1_root_adbd\n'
    exit 1
fi

if [[ "${selinux_mode}" != Permissive ]]; then
    printf 'RESULT=FAIL reason=tier1_selinux_mode\n'
    exit 1
fi

printf 'RESULT=PASS\n'
