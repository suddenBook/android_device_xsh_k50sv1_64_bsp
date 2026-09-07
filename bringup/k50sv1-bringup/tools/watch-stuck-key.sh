#!/usr/bin/env bash
#
# Catch the stuck-key fault in the act, and say WHICH input device caused it.
#
# The fault: a key DOWN with no matching UP. A latched VOLUME_UP makes
# PhoneWindowManager set mA11yShortcutChordVolumeUpKeyTriggered, after which
# interceptPowerKeyDown() sets mPowerKeyHandled and never calls
# wakeUpFromPowerKey() -- so the power button stops lighting the screen, and
# held long enough the PMIC's own long-press reset fires. E-024/E-028 traced one
# cause (mtk-kpd losing an edge across suspend, fixed with kpd_call_state=2) on
# the premise that the OTHER candidate, ACCDET, was an ADC comparator with
# nothing attached to it. E-088 disproved that premise: ACCDET is wired to the
# USB-C analog audio path and sees every accessory insertion. So this exists to
# tell the two apart with evidence instead of reasoning.
#
# A stuck key produces NO further input events, so streaming getevent cannot see
# it -- the absence of an UP is the signal. This polls the state instead.
#
# Usage: watch-stuck-key.sh <adb-serial-or-host:port> [poll-seconds]
#
# Emits one line per detection and keeps running. Read-only.

set -uo pipefail

SERIAL="${1:-}"
POLL="${2:-5}"
if [[ -z "${SERIAL}" ]]; then
    echo "usage: $(basename "$0") <adb-serial-or-host:port> [poll-seconds]" >&2
    exit 2
fi

ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
export ADB_LIBUSB="${ADB_LIBUSB:-1}"

# Capture, then match. `adb shell ... | grep -q` under pipefail reports the
# producer's SIGPIPE status, not the match (HANDOFF trap 6).
sh_() { "${ADB_BIN}" -s "${SERIAL}" shell "$@" 2>/dev/null | tr -d '\r'; }

armed=""
while true; do
    dump="$(sh_ 'dumpsys input')"
    if [[ -z "${dump}" ]]; then
        sleep "${POLL}"
        continue
    fi

    # "Device N: name" ... "KeyDowns: K keys currently down". Report the device
    # NAME, because naming mtk-kpd vs ACCDET is the entire point.
    stuck="$(printf '%s\n' "${dump}" | awk '
        /^  Device [0-9]+: /   { dev = $0; sub(/^  Device [0-9]+: /, "", dev) }
        /KeyDowns: [0-9]+ keys/ { n = $2 + 0; if (n > 0) print dev "=" n }
    ')"

    if [[ -n "${stuck}" ]]; then
        if [[ "${armed}" == "${stuck}" ]]; then
            # Seen twice in a row: a real press is not held across two polls by
            # accident at a 5 s interval, and a genuine long-press is exactly
            # what we want to see anyway.
            ts="$(sh_ 'date +%FT%T')"
            printf 'STUCK-KEY %s  %s\n' "${ts}" "${stuck//$'\n'/ ; }"
            # One-shot detail so the line above is never the only record.
            printf '%s\n' "${dump}" \
                | grep -E '^  Device [0-9]+: |KeyDowns:|SwitchValues:|DownTime:' \
                | sed 's/^/    /'
            sh_ 'getevent -p' | sed -n '/ACCDET/,/^$/p' | sed 's/^/    accdet: /'
        fi
        armed="${stuck}"
    else
        armed=""
    fi
    sleep "${POLL}"
done
