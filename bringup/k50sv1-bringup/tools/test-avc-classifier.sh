#!/usr/bin/env bash
# Offline regression tests for qualifier-aware AVC classification.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ROOT="$(cd "${TOOL_DIR}/.." && pwd)"
WORK_ROOT="$(cd "${CASE_ROOT}/.." && pwd)"
CLASSIFIER="${TOOL_DIR}/classify-avc-denials.sh"
EXPECTED="${TOOL_DIR}/expected-avc-tuples.txt"
CAPTURE="${WORK_ROOT}/.capture-staging/tier1-verify-20260824T153250Z"

for path in "${CLASSIFIER}" "${EXPECTED}" \
            "${CAPTURE}/early-dmesg.txt" "${CAPTURE}/early-logcat-all.txt" \
            "${CAPTURE}/continuous-dmesg.txt" \
            "${CAPTURE}/continuous-logcat-all.txt" \
            "${CAPTURE}/late-dmesg.txt" "${CAPTURE}/late-logcat-all.txt"; do
    [[ -f "${path}" && ! -L "${path}" ]] \
        || { printf 'missing AVC fixture: %s\n' "${path}" >&2; exit 1; }
done

TEST_ROOT="$(mktemp -d /tmp/k50-avc-test.XXXXXX)"
cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-avc-test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT
mkdir "${TEST_ROOT}/capture" "${TEST_ROOT}/bad" "${TEST_ROOT}/good" \
      "${TEST_ROOT}/malformed" "${TEST_ROOT}/unreadable" \
      "${TEST_ROOT}/unwritable" "${TEST_ROOT}/empty" \
      "${TEST_ROOT}/enforcing" "${TEST_ROOT}/prose" "${TEST_ROOT}/floor"

set +e
capture_result="$("${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/capture" \
    "${CAPTURE}/early-dmesg.txt" "${CAPTURE}/early-logcat-all.txt" \
    "${CAPTURE}/continuous-dmesg.txt" \
    "${CAPTURE}/continuous-logcat-all.txt" \
    "${CAPTURE}/late-dmesg.txt" "${CAPTURE}/late-logcat-all.txt")"
capture_rc=$?
set -e
[[ "${capture_rc}" -eq 1 ]]
grep -Fxq 'denial_count=274' <<<"${capture_result}"
grep -Fxq 'normalized_count=274' <<<"${capture_result}"
grep -Fxq 'unparsed_count=0' <<<"${capture_result}"
grep -Fxq 'expected_count=12' <<<"${capture_result}"
grep -Fxq 'unexpected_count=3' <<<"${capture_result}"
[[ "$(wc -l <"${TEST_ROOT}/capture/avc-unexpected.txt")" -eq 3 ]]
# The trailing `permissive=1` is asserted, not tolerated. The classifier used to
# drop that field entirely, which made a Tier-2 run with half the vendor policy
# still permissive produce byte-identical artifacts to a fully enforcing one.
# Pinning it here is what stops that regression from coming back silently.
for dev in mmcblk0p6 mmcblk0p8 mmcblk0p9; do
    grep -Fxq "vendor_init -> unlabeled : dir setattr | dev=${dev} name=/ permissive=1" \
        "${TEST_ROOT}/capture/avc-unexpected.txt"
done

printf '%s\n' \
    'avc: denied { set } for property=gsm.sim.state scontext=u:r:mtkrild:s0 tcontext=u:object_r:radio_prop:s0 tclass=property_service permissive=1' \
    'avc: denied { ioctl } for path="/mnt/vendor/protect_f" dev="mmcblk0p8" ioctlcmd=1234 scontext=u:r:vold:s0 tcontext=u:object_r:mnt_vendor_file:s0 tclass=dir permissive=1' \
    'avc: denied { getattr } for path="/sys/devices/other" app=com.google.android.gms scontext=u:r:priv_app:s0 tcontext=u:object_r:sysfs:s0 tclass=file permissive=1' \
    'avc: denied { getattr } for path="/data/local/other" app=com.android.providers.media scontext=u:r:mediaprovider:s0 tcontext=u:object_r:shell_data_file:s0 tclass=dir permissive=1' \
    'avc: denied { find } for service=not_apexservice scontext=u:r:system_app:s0 tcontext=u:object_r:apex_service:s0 tclass=service_manager permissive=1' \
    'avc: denied { find } for interface=android.hardware.memtrack::IOther scontext=u:r:priv_app:s0 tcontext=u:object_r:hal_memtrack_hwservice:s0 tclass=hwservice_manager permissive=1' \
    'avc: denied { open } for path="/proc/stat" app=com.google.android.gms scontext=u:r:priv_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { getattr } for path="/proc/loadavg" app=com.huawei.hwid scontext=u:r:priv_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { open } for path="/proc/stat" app=com.google.android.gms scontext=u:r:untrusted_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { open } for path="/cache/recovery" app=com.android.providers.media scontext=u:r:mediaprovider:s0 tcontext=u:object_r:cache_recovery_file:s0 tclass=dir permissive=1' \
    'avc: denied { lock } for path="/system/framework/arm64/boot.art" app=com.google.android.gms scontext=u:r:dexoptanalyzer:s0 tcontext=u:object_r:system_file:s0 tclass=file permissive=1' \
    >"${TEST_ROOT}/bad.log"
set +e
bad_result="$("${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/bad" \
    "${TEST_ROOT}/bad.log")"
bad_rc=$?
set -e
[[ "${bad_rc}" -eq 1 ]]
grep -Fxq 'unexpected_count=11' <<<"${bad_result}"

printf '%s\n' \
    'avc: denied { set } for property=gsm.version.ril-impl scontext=u:r:mtkrild:s0 tcontext=u:object_r:radio_prop:s0 tclass=property_service permissive=1' \
    'avc: denied { ioctl } for path="/mnt/vendor/protect_f" dev="mmcblk0p8" ioctlcmd=5879 scontext=u:r:vold:s0 tcontext=u:object_r:mnt_vendor_file:s0 tclass=dir permissive=1' \
    'avc: denied { getattr } for path="/sys/devices/soc/180f0000.wifi/net/wlan0/address" app=com.google.android.gms scontext=u:r:priv_app:s0 tcontext=u:object_r:sysfs:s0 tclass=file permissive=1' \
    'avc: denied { open } for path="/sys/devices/soc/180f0000.wifi/net/p2p0/type" dev="sysfs" app=com.google.android.gms scontext=u:r:priv_app:s0 tcontext=u:object_r:sysfs:s0 tclass=file permissive=1' \
    'avc: denied { getattr } for path="/data/local/tmp" app=com.android.providers.media scontext=u:r:mediaprovider:s0 tcontext=u:object_r:shell_data_file:s0 tclass=dir permissive=1' \
    'avc: denied { find } for service=apexservice scontext=u:r:system_app:s0 tcontext=u:object_r:apex_service:s0 tclass=service_manager permissive=1' \
    'avc: denied { find } for service=suspend_control scontext=u:r:system_app:s0 tcontext=u:object_r:system_suspend_control_service:s0 tclass=service_manager permissive=1' \
    'avc: denied { find } for interface=android.hardware.memtrack::IMemtrack scontext=u:r:priv_app:s0 tcontext=u:object_r:hal_memtrack_hwservice:s0 tclass=hwservice_manager permissive=1' \
    'avc: denied { open } for path="/proc/stat" app=com.huawei.hwid scontext=u:r:priv_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { getattr } for path="/proc/stat" app=com.huawei.hwid scontext=u:r:priv_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { getattr } for path="/proc/537" scontext=u:r:hal_power_default:s0 tcontext=u:r:mediacodec:s0 tclass=dir permissive=1' \
    'avc: denied { open } for path="/data/cache/recovery" dev="mmcblk0p30" scontext=u:r:mediaprovider:s0 tcontext=u:object_r:cache_recovery_file:s0 tclass=dir app=com.android.providers.media permissive=1' \
    'avc: denied { read } for name="recovery" dev="mmcblk0p30" scontext=u:r:mediaprovider:s0 tcontext=u:object_r:cache_recovery_file:s0 tclass=dir app=com.android.providers.media permissive=1' \
    'avc: denied { getattr } for path="/proc/stat" app=com.huawei.hwid scontext=u:r:untrusted_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { open } for path="/proc/stat" app=com.huawei.hwid scontext=u:r:untrusted_app:s0 tcontext=u:object_r:proc_stat:s0 tclass=file permissive=1' \
    'avc: denied { call } for comm="m.android.phone" scontext=u:r:radio:s0 tcontext=u:r:gpuservice:s0 tclass=binder permissive=1' \
    >"${TEST_ROOT}/good.log"
good_result="$("${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/good" \
    "${TEST_ROOT}/good.log")"
grep -Fxq 'unexpected_count=0' <<<"${good_result}"
grep -Fxq 'expected_count=16' <<<"${good_result}"

printf '%s\n' \
    'avc: denied { } for scontext=u:r:mtkrild:s0 tcontext=u:object_r:radio_prop:s0 tclass=property_service permissive=1' \
    >"${TEST_ROOT}/malformed.log"
set +e
malformed_result="$("${CLASSIFIER}" "${EXPECTED}" \
    "${TEST_ROOT}/malformed" "${TEST_ROOT}/malformed.log")"
malformed_rc=$?
set -e
[[ "${malformed_rc}" -eq 1 ]]
grep -Fxq 'denial_count=1' <<<"${malformed_result}"
grep -Fxq 'normalized_count=0' <<<"${malformed_result}"

printf '%s\n' 'unreadable fixture' >"${TEST_ROOT}/unreadable.log"
chmod 000 "${TEST_ROOT}/unreadable.log"
set +e
"${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/unreadable" \
    "${TEST_ROOT}/unreadable.log" >/dev/null 2>&1
unreadable_rc=$?
set -e
chmod 0600 "${TEST_ROOT}/unreadable.log"
[[ "${unreadable_rc}" -eq 2 ]]

chmod 0500 "${TEST_ROOT}/unwritable"
set +e
"${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/unwritable" \
    "${TEST_ROOT}/good.log" >/dev/null 2>&1
unwritable_rc=$?
set -e
chmod 0700 "${TEST_ROOT}/unwritable"
[[ "${unwritable_rc}" -eq 2 ]]

# An empty log, a file that is not a log, and a capture below the caller's
# evidence floor are all UNREAD, not clean. Each used to produce
# `denial_count=0 unexpected_count=0` and rc 0 -- this tool's strongest answer,
# "no unexpected denial" -- about a file nothing had been read from.
: >"${TEST_ROOT}/empty.log"
set +e
empty_result="$("${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/empty" \
    "${TEST_ROOT}/empty.log" 2>&1)"
empty_rc=$?
set -e
[[ "${empty_rc}" -eq 3 ]]
grep -Fxq 'denial_count=0' <<<"${empty_result}"
grep -Fxq 'unexpected_count=0' <<<"${empty_result}"
grep -Fq 'unread: empty AVC input log' <<<"${empty_result}"

printf '%s\n' \
    'this file is prose, not a capture' \
    'it carries no kernel stamp, no logcat stamp and no denial' \
    >"${TEST_ROOT}/prose.log"
set +e
prose_result="$("${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/prose" \
    "${TEST_ROOT}/prose.log" 2>&1)"
prose_rc=$?
set -e
[[ "${prose_rc}" -eq 3 ]]
grep -Fxq 'evidence_lines=0' <<<"${prose_result}"

# good.log is real evidence, but sixteen lines of it. A caller that asked for a
# thousand records has not been given an answer it can act on.
set +e
floor_result="$("${CLASSIFIER}" --min-evidence-lines 1000 "${EXPECTED}" \
    "${TEST_ROOT}/floor" "${TEST_ROOT}/good.log" 2>&1)"
floor_rc=$?
set -e
[[ "${floor_rc}" -eq 3 ]]
grep -Fxq 'evidence_lines=16' <<<"${floor_result}"
grep -Fxq 'min_evidence_lines=1000' <<<"${floor_result}"

# Same denial, same tuple, same qualifiers, one bit different: an ENFORCED
# refusal and a merely-logged one must not normalize to the same record. This is
# the whole verifiability claim Tier 2 rests on, and before the permissive
# capture was added both sides of this pair produced the identical line.
printf '%s\n' \
    'avc: denied { find } for service=apexservice scontext=u:r:system_app:s0 tcontext=u:object_r:apex_service:s0 tclass=service_manager permissive=0' \
    >"${TEST_ROOT}/enforcing.log"
enforcing_result="$("${CLASSIFIER}" "${EXPECTED}" "${TEST_ROOT}/enforcing" \
    "${TEST_ROOT}/enforcing.log")"
grep -Fxq 'expected_count=1' <<<"${enforcing_result}"
grep -Fxq 'system_app -> apex_service : service_manager find | service=apexservice permissive=0' \
    "${TEST_ROOT}/enforcing/avc-expected.txt"
grep -Fxq 'system_app -> apex_service : service_manager find | service=apexservice permissive=1' \
    "${TEST_ROOT}/good/avc-expected.txt"

printf 'AVC QUALIFIER CLASSIFIER MATRIX: PASS\n'
