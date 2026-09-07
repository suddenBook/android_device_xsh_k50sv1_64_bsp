#!/usr/bin/env bash

# Capture a privacy-minimized Tier 1 runtime snapshot from direct root adbd.
# Raw output is sanitized before it reaches disk. This collector deliberately
# avoids bugreport/dumpstate and every MTK battery command proc node.

set -euo pipefail

# ADB_BIN, matching every other tool, and ADB_LIBUSB exported: HANDOFF records
# that platform-tools 37 needs it to enumerate this single-interface MTK device.
ADB_BIN="${ADB_BIN:-${ADB:-/home/desmond/Android/Sdk/platform-tools/adb}}"
export ADB_LIBUSB="${ADB_LIBUSB:-1}"
ADB_TARGET="${ADB_TARGET:-}"
ADB_TIMEOUT="${ADB_TIMEOUT:-120}"
OUTPUT_DIR="${1:-}"

if [[ -z "${ADB_TARGET}" || -z "${OUTPUT_DIR}" ]]; then
    printf 'usage: ADB_TARGET=HOST:PORT %s NEW_OUTPUT_DIR\n' "$0" >&2
    exit 2
fi

if [[ ! -x "${ADB_BIN}" ]]; then
    printf 'adb is not executable: %s\n' "${ADB_BIN}" >&2
    exit 2
fi

if [[ ! "${ADB_TIMEOUT}" =~ ^[0-9]+([.][0-9]+)?[smhd]?$ ]]; then
    printf 'invalid ADB_TIMEOUT: %s\n' "${ADB_TIMEOUT}" >&2
    exit 2
fi

if [[ -e "${OUTPUT_DIR}" ]]; then
    printf 'refusing to merge into existing output: %s\n' "${OUTPUT_DIR}" >&2
    exit 2
fi

umask 077
mkdir -p -- "$(dirname -- "${OUTPUT_DIR}")"
if ! mkdir -m 0700 -- "${OUTPUT_DIR}"; then
    printf 'refusing to merge into existing output: %s\n' "${OUTPUT_DIR}" >&2
    exit 2
fi

sanitize_stream() {
    LC_ALL=C sed -E \
        -e 's/([[:xdigit:]]{2}[:-]){5}[[:xdigit:]]{2}/<redacted-mac>/g' \
        -e 's/androidboot\.serialno=[^[:space:]]+/androidboot.serialno=<redacted>/g' \
        -e 's/((ro\.(boot\.)?serialno|serial([ _-]?number)?)[[:space:]]*[:=][[:space:]]*)[[:alnum:]_.:-]+/\1<redacted>/Ig' \
        -e 's/(imei(sv)?|imsi|iccid|eid|meid|msisdn|subscriberId|deviceId|line1Number|phone[ _-]?number)([^[:alnum:]]{0,8})[[:alnum:]_.:-]+/\1\3<redacted>/Ig' \
        -e 's/((ssid|bssid)[[:space:]]*[:=][[:space:]]*)("[^"]*"|[^[:space:],;]+)/\1<redacted>/Ig' \
        -e 's/(Nonce[[:space:]]+)[[:xdigit:]]+/\1<redacted>/Ig' \
        -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<redacted-email>/Ig' \
        -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<redacted-ip>/g' \
        -e ':redact_id_32' \
        -e 's/(^|[^0-9])[0-9]{32}([^0-9]|$)/\1<redacted-id>\2/' \
        -e 't redact_id_32' \
        -e ':redact_id_18_22' \
        -e 's/(^|[^0-9])[0-9]{18,22}([^0-9]|$)/\1<redacted-id>\2/' \
        -e 't redact_id_18_22' \
        -e ':redact_id_14_16' \
        -e 's/(^|[^0-9])[0-9]{14,16}([^0-9]|$)/\1<redacted-id>\2/' \
        -e 't redact_id_14_16'
}

capture_text() {
    local output_name="$1"
    local device_command="$2"
    local output_part="${OUTPUT_DIR}/${output_name}.txt.part"
    local output_path="${OUTPUT_DIR}/${output_name}.txt"
    local adb_status
    local sanitizer_status
    local -a pipeline_status

    {
        printf '# captured_at: %s\n' "$(date -Iseconds)"
        printf '# capture: direct root adbd; stream-sanitized on host\n\n'
        set +e
        timeout --foreground "${ADB_TIMEOUT}" \
            "${ADB_BIN}" -s "${ADB_TARGET}" exec-out sh -c "${device_command}" 2>&1 \
            | sanitize_stream
        pipeline_status=("${PIPESTATUS[@]}")
        adb_status="${pipeline_status[0]}"
        sanitizer_status="${pipeline_status[1]}"
        set -e
        printf '\n# adb_exit_status: %s\n' "${adb_status}"
        printf '# sanitizer_exit_status: %s\n' "${sanitizer_status}"
    } >"${output_part}"
    mv -- "${output_part}" "${output_path}"

    if ((adb_status != 0 || sanitizer_status != 0)); then
        printf 'capture failed for %s: adb=%s sanitizer=%s\n' \
            "${output_name}" "${adb_status}" "${sanitizer_status}" >&2
        return 1
    fi
}

device_id="$(
    timeout --foreground "${ADB_TIMEOUT}" \
        "${ADB_BIN}" -s "${ADB_TARGET}" shell id 2>/dev/null \
        | tr -d '\r'
)"
if [[ "${device_id}" != uid=0\(root\)* ]]; then
    printf 'Tier 1 direct root adbd contract failed\n' >&2
    exit 1
fi

capture_text identity '
id;
uname -a;
cat /proc/uptime;
cat /proc/cmdline;
printf "boot_id_sha256=";
cat /proc/sys/kernel/random/boot_id | sha256sum | cut -c1-16;
getenforce;
cat /sys/fs/selinux/enforce 2>/dev/null;
cat /sys/fs/selinux/policyvers 2>/dev/null;
for prop in \
    ro.build.version.release ro.build.version.sdk ro.build.type ro.build.tags \
    ro.lineage.version ro.product.device ro.hardware ro.boot.verifiedbootstate \
    ro.secure ro.debuggable ro.adb.secure service.adb.root \
    sys.boot_completed dev.bootcomplete init.svc.bootanim ro.config.low_ram \
    sys.usb.config sys.usb.state persist.sys.usb.config \
    sys.usb.ffs.aio_compat persist.adb.nonblocking_ffs; do
        printf "%s=" "$prop"; getprop "$prop";
done;
'

capture_text mounts_and_filesystems '
cat /proc/partitions;
cat /proc/mounts;
df -k;
for path in /fstab* /vendor/etc/fstab*; do
    [ -f "$path" ] || continue;
    printf "### %s\n" "$path";
    cat "$path";
done;
'

capture_text crash_residue '
for path in /sys/fs/pstore/console-ramoops* /sys/fs/pstore/dmesg-ramoops*; do
    [ -f "$path" ] || continue;
    printf "### %s\n" "$path";
    cat "$path";
done;
if [ -f /proc/last_kmsg ]; then
    printf "### /proc/last_kmsg\n";
    cat /proc/last_kmsg;
fi;
'

capture_text dmesg 'dmesg'
capture_text logcat_all 'logcat -b all -d -v epoch'

capture_text input '
cat /proc/bus/input/devices;
getevent -lp;
dumpsys input;
dumpsys window policy;
'

capture_text services '
getprop | grep "^\[init\.svc\.";
ps -AZ | grep -E "(servicemanager|surfaceflinger|audioserver|camera|sensor|power|thermal|health|nvram|wmt|ccci|gsm0710|mtkrild|rilproxy|mnld|agpsd|lbs|omx|codec|system_server|zygote)";
service list;
lshal --neat;
'

capture_text hardware '
dumpsys media.camera;
dumpsys sensorservice;
dumpsys thermalservice;
dumpsys battery;
dumpsys audio;
'

privacy_failures="${OUTPUT_DIR}/privacy-files.txt.part"
# WAS FAIL-OPEN. This was `if LC_ALL=C grep ...; then <fail>; fi`, which folds
# grep's THREE exit statuses onto two outcomes: 0 (matched) failed, and BOTH
# 1 (ran, matched nothing) and 2 (grep itself errored) fell through to the
# manifest below -- which then wrote `privacy_gate=pass`. rc 2 does not mean
# "no leak", it means NOTHING WAS SCANNED, and it is easy to reach: an
# unreadable capture file, a `"${OUTPUT_DIR}"/*.txt` glob that matched nothing
# and was therefore passed to grep literally, or a bracket expression the local
# grep rejects. In every one of those cases the snapshot went to disk carrying a
# recorded claim that it had been checked, when it had not. Capture the status
# and treat anything but 1 as a hard refusal.
privacy_rc=0
LC_ALL=C grep -Eil \
    '(imei|imsi|iccid|eid|meid|msisdn|subscriberId|deviceId|line1Number|phone[ _-]?number)[^<]{0,24}[0-9]|(ro\.(boot\.)?serialno|serial([ _-]?number)?)[[:space:]]*[:=][[:space:]]*[[:alnum:]]|([[:xdigit:]]{2}[:-]){5}[[:xdigit:]]{2}|androidboot\.serialno=[^<[:space:]]|(ssid|bssid)[[:space:]]*[:=][[:space:]]*[^<[:space:]]|Nonce[[:space:]]+[[:xdigit:]]|[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}|([0-9]{1,3}\.){3}[0-9]{1,3}|(^|[^0-9])([0-9]{32}|[0-9]{18,22}|[0-9]{14,16})([^0-9]|$)' \
    -- "${OUTPUT_DIR}"/*.txt >"${privacy_failures}" || privacy_rc=$?
case "${privacy_rc}" in
    1) ;;   # grep ran over every file and matched nothing. The only pass.
    0)
        printf 'privacy gate failed; inspect file list in %s\n' "${privacy_failures}" >&2
        exit 1
        ;;
    *)
        printf 'privacy gate could not run: grep exited %s, so nothing was scanned.\n' \
            "${privacy_rc}" >&2
        printf 'this snapshot is NOT cleared for release; %s is left in place unmanifested.\n' \
            "${OUTPUT_DIR}" >&2
        exit 1
        ;;
esac
rm -f -- "${privacy_failures}"

{
    printf 'captured_at=%s\n' "$(date -Iseconds)"
    printf 'adb_version=%s\n' "$("${ADB_BIN}" version | head -n 1)"
    printf 'capture_policy=direct root adbd; host-side streaming redaction; no transport serial; no bugreport/dumpstate; no MTK battery command proc reads\n'
    printf 'privacy_gate=pass\n'
} >"${OUTPUT_DIR}/MANIFEST.txt"

(
    cd "${OUTPUT_DIR}"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum >SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
)

printf 'captured sanitized Tier 1 runtime snapshot in %s\n' "${OUTPUT_DIR}"
