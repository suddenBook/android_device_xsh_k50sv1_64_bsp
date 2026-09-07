#!/usr/bin/env bash
#
# Post-flash verification for the session-2 fixes. Every check corresponds to
# something that was changed and can be confirmed from the running handset.
#
# Active but non-destructive. Invoke immediately after the flasher reboots; it
# captures logs, waits for boot completion, wakes/unlocks the UI, launches four
# apps and creates/removes one temporary screen recording. It changes no
# partition, persistent setting or account state.

# No pipefail. Every check here is "does this output contain X", and `grep -q`
# exits at the first match, which SIGPIPEs the `tr` inside sh_(). Under pipefail
# the pipeline then reports the 141, so a *successful* match looks like a
# failure -- racily, depending on whether the upstream had already drained into
# the pipe buffer. That produced three false negatives on the first run.
set -u

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY_STAGE_TOOL="${TOOL_DIR}/verify-stage-contract.sh"
SERIAL="${1:-${ANDROID_SERIAL:-}}"
STAGE_DIR="${2:-}"
FLASH_RECEIPT="${3:-}"
CAPTURE_DIR="${4:-}"
RADIO_PROFILE="${5:-${K50SV1_RADIO_PROFILE:-}}"
PSTORE_PHASE="${6:-}"
PRIOR_PSTORE_MANIFEST="${7:-}"
if [[ "$#" -gt 7 || -z "${SERIAL}" || -z "${STAGE_DIR}" || \
      -z "${FLASH_RECEIPT}" || -z "${CAPTURE_DIR}" || \
      -z "${RADIO_PROFILE}" || -z "${PSTORE_PHASE}" ]]; then
    printf 'usage: %s <adb-serial> <stage-dir> <flash-receipt> <new-capture-dir> <dual-cn|lebara-slot0|vdf-nl-slot0|cu-slot0-cmcc-slot1> <preflash-predecessor|stock-predecessor|lineage-predecessor> [prior-pstore-manifest]\n' "$0" >&2
    exit 2
fi
[[ -x "${VERIFY_STAGE_TOOL}" ]] || {
    printf 'stage-contract verifier is unavailable: %s\n' "${VERIFY_STAGE_TOOL}" >&2
    exit 2
}
if ! stage_contract_report="$("${VERIFY_STAGE_TOOL}" "${STAGE_DIR}")"; then
    printf 'post-flash verification refuses an invalid stage contract\n' >&2
    exit 2
fi
STAGE_DIR="$(realpath -e "${STAGE_DIR}")"
contract_get_exact() {
    local key="$1"
    awk -F= -v key="${key}" '
        $1 == key { count++; value = substr($0, length(key) + 2) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' <<<"${stage_contract_report}"
}
STAGE_CONTRACT_SHA="$(contract_get_exact stage_contract_sha256)" || exit 2
SOURCE_MANIFEST_SHA="$(contract_get_exact source_manifest_sha256)" || exit 2
BUILD_RECEIPT_SHA="$(contract_get_exact build_receipt_sha256)" || exit 2
EXPECTED_TIER="$(contract_get_exact tier)" || exit 2
EXPECTED_VARIANT="$(contract_get_exact variant)" || exit 2
K50SV1_EXPECT_FINGERPRINT="$(contract_get_exact public_fingerprint)" || exit 2
K50SV1_EXPECT_SYSTEM_FINGERPRINT="$(contract_get_exact system_fingerprint)" || exit 2
EXPECTED_PRODUCT_APNS_SHA="$(contract_get_exact product_apns_sha256)" || exit 2
EXPECTED_INCREMENTAL="$(contract_get_exact build_incremental)" || exit 2
[[ "${EXPECTED_PRODUCT_APNS_SHA}" =~ ^[0-9a-f]{64}$ ]] || exit 2
[[ "$(contract_get_exact status)" == PASS ]] || exit 2

[[ -f "${FLASH_RECEIPT}" && ! -L "${FLASH_RECEIPT}" && -s "${FLASH_RECEIPT}" ]] || {
    printf 'missing, empty, or symlinked mandatory flash receipt: %s\n' \
        "${FLASH_RECEIPT}" >&2
    exit 2
}
FLASH_RECEIPT="$(realpath -e "${FLASH_RECEIPT}")"
flash_get_exact() {
    local key="$1"
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++; value = substr($0, length(key) + 2)
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${FLASH_RECEIPT}"
}
[[ "$(flash_get_exact flash_receipt.version)" == 1 && \
   "$(flash_get_exact status.initial)" == IN_PROGRESS && \
   "$(flash_get_exact status)" == PASS && \
   "$(flash_get_exact stage.contract_sha256)" == "${STAGE_CONTRACT_SHA}" && \
   "$(flash_get_exact stage.source_manifest_sha256)" == "${SOURCE_MANIFEST_SHA}" && \
   "$(flash_get_exact stage.build_receipt_sha256)" == "${BUILD_RECEIPT_SHA}" && \
   "$(flash_get_exact stage.tier)" == "${EXPECTED_TIER}" && \
   "$(flash_get_exact stage.variant)" == "${EXPECTED_VARIANT}" && \
   "$(flash_get_exact stage.public_fingerprint)" == \
        "${K50SV1_EXPECT_FINGERPRINT}" && \
   "$(flash_get_exact stage.system_fingerprint)" == \
        "${K50SV1_EXPECT_SYSTEM_FINGERPRINT}" && \
   "$(flash_get_exact stage.build_incremental)" == "${EXPECTED_INCREMENTAL}" ]] || {
    printf 'flash receipt does not describe the supplied stage contract\n' >&2
    exit 2
}
[[ "$(flash_get_exact device.fastboot_serial)" == "${SERIAL}" ]] || {
    printf 'post-flash adb serial %s differs from flashed fastboot serial %s\n' \
        "${SERIAL}" "$(flash_get_exact device.fastboot_serial)" >&2
    exit 2
}
for operation in \
    operation.flash.boot operation.flash.recovery \
    operation.flash.system operation.flash.vendor operation.reboot; do
    [[ "$(flash_get_exact "${operation}")" == success ]] || {
        printf 'flash receipt lacks successful %s\n' "${operation}" >&2
        exit 2
    }
done
for wipe in userdata metadata cache; do
    [[ "$(flash_get_exact "operation.wipe.${wipe}")" == success:* ]] || {
        printf 'flash receipt lacks successful %s wipe\n' "${wipe}" >&2
        exit 2
    }
done
stage_manifest_get() {
    local key="$1"
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++; value = substr($0, length(key) + 2)
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${STAGE_DIR}/SOURCE-MANIFEST"
}
# THE VERIFIER NO LONGER REQUIRES ITSELF TO BE FROZEN AT THE STAGE IT VERIFIES.
# This check used to compare this file's digest against
# tool.verify_post_flash_sha256 in SOURCE-MANIFEST and refuse to run on any
# mismatch. A verifier is not an input to the bytes it verifies, and the rule
# had a measured cost and no measured benefit: twice in one session it stopped
# a stage being re-verified after a verifier bug was fixed, and the project's
# response was to restore the OLD, KNOWN-BUGGY verifier out of git so the digest
# would match -- so its two fixes went unexercised (E-142, E-143). It was
# enforcing sameness, not correctness.
#
# What still binds, and is what actually matters, is unchanged: the four image
# SHA-256s, SOURCE-MANIFEST, the build receipt, the pinned repo manifest and the
# APN digest, all cross-linked through STAGE-CONTRACT, plus the flasher and
# contract verifier below -- those two ran BEFORE and DURING the destructive
# operation, so a change to either after the fact really does invalidate the
# receipt.
for image in boot recovery system vendor; do
    [[ "$(flash_get_exact "image.${image}.sha256")" == \
            "$(stage_manifest_get "image.${image}.sha256")" && \
       "$(flash_get_exact "image.${image}.bytes")" == \
            "$(stage_manifest_get "image.${image}.bytes")" ]] || {
        printf 'flash receipt image metadata disagrees for %s\n' "${image}" >&2
        exit 2
    }
done
[[ "$(flash_get_exact tool.flash_tier_images_sha256)" == \
        "$(sha256sum "${TOOL_DIR}/flash-tier-images.sh" | awk '{ print $1 }')" && \
   "$(flash_get_exact tool.verify_stage_contract_sha256)" == \
        "$(sha256sum "${VERIFY_STAGE_TOOL}" | awk '{ print $1 }')" ]] || {
    printf 'flash/contract tooling changed after the destructive operation\n' >&2
    exit 2
}
FLASH_RECEIPT_SHA="$(sha256sum "${FLASH_RECEIPT}" | awk '{ print $1 }')"
case "${EXPECTED_TIER}" in
    1 | 2) ;;
    3)
        printf 'Tier 3 does not expose adb by default. If explicitly enabled later it must be authenticated and non-root; this rooted diagnostic verifier supports only Tiers 1/2, so verify the signed release contract and boot/UI separately.\n' >&2
        exit 2
        ;;
    *)
        printf 'expected tier must be 1 or 2 (got %s)\n' "${EXPECTED_TIER}" >&2
        exit 2
        ;;
esac
case "${RADIO_PROFILE}" in
    dual-cn | lebara-slot0 | vdf-nl-slot0 | cu-slot0-cmcc-slot1) ;;
    *)
        printf 'unknown radio profile: %s (expected dual-cn, lebara-slot0, vdf-nl-slot0 or cu-slot0-cmcc-slot1)\n' \
            "${RADIO_PROFILE}" >&2
        exit 2
        ;;
esac
case "${PSTORE_PHASE}" in
    preflash-predecessor | stock-predecessor)
        if [[ -n "${PRIOR_PSTORE_MANIFEST}" ]]; then
            printf '%s phase does not accept a prior pstore manifest\n' \
                "${PSTORE_PHASE}" >&2
            exit 2
        fi
        ;;
    lineage-predecessor)
        if [[ ! -f "${PRIOR_PSTORE_MANIFEST}" || \
              -L "${PRIOR_PSTORE_MANIFEST}" || \
              ! -s "${PRIOR_PSTORE_MANIFEST}" ]]; then
            printf 'lineage-predecessor requires the first run pstore/FAULT-SHA256SUMS: %s\n' \
                "${PRIOR_PSTORE_MANIFEST:-<missing>}" >&2
            exit 2
        fi
        ;;
    *)
        printf 'unknown pstore phase: %s (expected preflash-predecessor, stock-predecessor or lineage-predecessor)\n' \
            "${PSTORE_PHASE}" >&2
        exit 2
        ;;
esac
if [[ -e "${CAPTURE_DIR}" || -L "${CAPTURE_DIR}" ]]; then
    printf 'refusing to overwrite capture directory: %s\n' "${CAPTURE_DIR}" >&2
    exit 2
fi
capture_parent="$(dirname "${CAPTURE_DIR}")"
capture_name="$(basename "${CAPTURE_DIR}")"
[[ "${capture_name}" != . && "${capture_name}" != .. && \
   "${capture_name}" != / && \
   -d "${capture_parent}" && ! -L "${capture_parent}" ]] || {
    printf 'capture parent/name is unsafe: %s\n' "${CAPTURE_DIR}" >&2
    exit 2
}
capture_parent="$(realpath -e "${capture_parent}")"
CAPTURE_DIR="${capture_parent}/${capture_name}"
mkdir -- "${CAPTURE_DIR}" || exit 2

EXPECTED_AVC_FILE="${TOOL_DIR}/expected-avc-tuples.txt"
AVC_CLASSIFIER="${TOOL_DIR}/classify-avc-denials.sh"
PSTORE_PRETRANSITION_FILE="${TOOL_DIR}/../evidence/E-074-console-SHA256SUMS.txt"
PSTORE_CLASSIFIER="${TOOL_DIR}/classify-pstore.sh"
ADB_WAIT_SECONDS="${K50SV1_ADB_WAIT_SECONDS:-120}"
ADB_COMMAND_SECONDS="${K50SV1_ADB_COMMAND_SECONDS:-60}"
BOOT_WAIT_ATTEMPTS="${K50SV1_BOOT_WAIT_ATTEMPTS:-180}"
RADIO_WAIT_SECONDS="${K50SV1_RADIO_WAIT_SECONDS:-300}"
ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
# No tool exported this, although HANDOFF records that platform-tools 37 needs
# ADB_LIBUSB=1 to enumerate this single-interface MTK device at all. Inheriting
# it from the operator's shell is how a whole verification run turns into 150
# unread checks for a reason that has nothing to do with the image. Demonstrated
# in this session: check-tier1-usb-adb.sh went from seeing no USB transport to
# ADB_USB_DEVICE_COUNT=1 on the same attached handset once it exported this.
export ADB_LIBUSB="${ADB_LIBUSB:-1}"
LOGCAT_PROOF_BUFFERS=(kernel events main system radio)
LOGCAT_BUFFER_ARGS=()
for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
    LOGCAT_BUFFER_ARGS+=(-b "${logcat_buffer}")
done
FFPROBE_BIN="$(command -v ffprobe || true)"
if [[ ! "${ADB_WAIT_SECONDS}" =~ ^[1-9][0-9]*$ || \
      ! "${ADB_COMMAND_SECONDS}" =~ ^[1-9][0-9]*$ || \
      ! "${BOOT_WAIT_ATTEMPTS}" =~ ^[1-9][0-9]*$ || \
      ! "${RADIO_WAIT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ADB wait/command and boot/radio wait values must be positive integers\n' >&2
    exit 2
fi
if [[ ! -x "${ADB_BIN}" ]]; then
    printf 'adb binary is not executable: %s\n' "${ADB_BIN}" >&2
    exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
    printf 'host timeout command is required\n' >&2
    exit 2
fi
if [[ ! -x "${FFPROBE_BIN}" ]]; then
    printf 'host ffprobe is required for the hardware AVC gate\n' >&2
    exit 2
fi
if [[ ! -r "${EXPECTED_AVC_FILE}" ]]; then
    printf 'missing expected-AVC list: %s\n' "${EXPECTED_AVC_FILE}" >&2
    exit 2
fi
if [[ ! -x "${AVC_CLASSIFIER}" || -L "${AVC_CLASSIFIER}" ]]; then
    printf 'missing AVC classifier: %s\n' "${AVC_CLASSIFIER}" >&2
    exit 2
fi
if [[ ! -f "${PSTORE_PRETRANSITION_FILE}" || -L "${PSTORE_PRETRANSITION_FILE}" || \
      "$(sha256sum "${PSTORE_PRETRANSITION_FILE}" 2>/dev/null | awk '{print $1}')" != \
      "925734a4654b91f1fa8450cf8354909fb9dc970fc97adde06d0a1ff0954620f6" ]]; then
    printf 'missing or changed E-074 pre-transition pstore record: %s\n' \
        "${PSTORE_PRETRANSITION_FILE}" >&2
    exit 2
fi
if [[ ! -x "${PSTORE_CLASSIFIER}" || -L "${PSTORE_CLASSIFIER}" ]]; then
    printf 'missing pstore classifier: %s\n' "${PSTORE_CLASSIFIER}" >&2
    exit 2
fi
adb() { timeout "${ADB_COMMAND_SECONDS}s" "${ADB_BIN}" -s "${SERIAL}" "$@"; }
sh_() { adb shell "$@" 2>/dev/null | tr -d '\r'; }
logcat_snapshot() {
    adb logcat -d "${LOGCAT_BUFFER_ARGS[@]}" -v monotonic 2>/dev/null \
        | tr -d '\r'
}

pass=0; fail=0; info=0; unread=0; evidence_fatal=0
result_records=""
record_result() { result_records+="$1"$'\t'"$2"$'\n'; }
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; record_result PASS "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; record_result FAIL "$1"; fail=$((fail+1)); }
note() { printf '  ....  %s\n' "$1"; record_result INFO "$1"; info=$((info+1)); }
# A check that could not READ the thing it is asking about has not failed -- it
# has not run. Conflating the two produced five phantom failures on the first
# run after a flash, every one of which was correct on the handset. Report it
# separately and loudly instead.
skip() {
    printf '  \033[33m????\033[0m  %s (could not read; check did not run)\n' "$1"
    record_result UNREAD "$1"
    unread=$((unread+1))
}
evidence_error() {
    printf '  \033[31mFATAL\033[0m evidence write/capture failed: %s\n' "$1" >&2
    evidence_fatal=$((evidence_fatal + 1))
}
must_write_text() {
    local path="$1"
    local value="$2"
    local incomplete="${path}.incomplete"
    if [[ -e "${path}" || -L "${path}" || -e "${incomplete}" || \
          -L "${incomplete}" ]] || \
       ! printf '%s\n' "${value}" >"${incomplete}" || \
       ! chmod 0644 "${incomplete}" || \
       ! mv -T "${incomplete}" "${path}"; then
        rm -f -- "${incomplete}" 2>/dev/null || true
        evidence_error "${path}"
        return 1
    fi
}
must_append_text() {
    local path="$1"
    local value="$2"
    if [[ ! -f "${path}" || -L "${path}" ]] || \
       ! printf '%s\n' "${value}" >>"${path}"; then
        evidence_error "append ${path}"
        return 1
    fi
}
must_copy_evidence() {
    local source="$1"
    local destination="$2"
    if [[ ! -f "${source}" || -L "${source}" || ! -s "${source}" || \
          -e "${destination}" || -L "${destination}" ]] || \
       ! cp -- "${source}" "${destination}" || \
       ! chmod 0644 "${destination}" || \
       ! cmp -s "${source}" "${destination}"; then
        evidence_error "copy ${source} -> ${destination}"
        return 1
    fi
}

PROVENANCE_CAPTURE_DIR="${CAPTURE_DIR}/provenance"
mkdir -- "${PROVENANCE_CAPTURE_DIR}" || {
    evidence_error "${PROVENANCE_CAPTURE_DIR}"
    exit 1
}
for provenance_file in \
    SHA256SUMS SOURCE-MANIFEST SOURCE-MANIFEST.sha256 \
    K50SV1-BUILD-RECEIPT K50SV1-BUILD-SOURCE-STATE \
    K50SV1-ANDROID-REPO-MANIFEST.xml STAGE-CONTRACT STAGE-CONTRACT.sha256; do
    must_copy_evidence "${STAGE_DIR}/${provenance_file}" \
        "${PROVENANCE_CAPTURE_DIR}/${provenance_file}" || exit 1
done
must_copy_evidence "${FLASH_RECEIPT}" \
    "${PROVENANCE_CAPTURE_DIR}/FLASH-RECEIPT" || exit 1

# One remote command, plus proof that the round trip happened at all.
#
# sh_() throws the remote exit status away, so a command that RAN and produced
# nothing was indistinguishable from a transport that never delivered anything.
# `check` used to be `[[ -n "$2" ]] && ok || skip`, which meant a MISSING FILE
# -- a real regression -- and a DEAD ADB were reported with the same wording,
# and skip() is explicitly defined three lines up as "has not failed; has not
# run". The sentinel is the same __K50_*_RC__ idiom the dexopt probe and the
# tombstone manifest already use further down: if the sentinel line comes back,
# the handset answered, and an empty answer is then a real answer.
PROBE_RC=""
PROBE_OUT=""
probe_remote() {
    local raw
    raw="$(sh_ "$1"'
__k50_probe_rc=$?
printf "__K50_PROBE_RC__=%s\n" "${__k50_probe_rc}"')"
    PROBE_RC="$(sed -n 's/^__K50_PROBE_RC__=//p' <<<"${raw}")"
    PROBE_OUT="$(sed '/^__K50_PROBE_RC__=/d' <<<"${raw}")"
}
# check <label> <remote command>. Non-empty output passes; an empty answer from
# a handset that answered FAILS; only a missing sentinel skips.
check(){
    probe_remote "$2"
    if   [[ -z "${PROBE_RC}" ]]; then skip "$1"
    elif [[ -n "${PROBE_OUT}" ]]; then ok "$1: ${PROBE_OUT}"
    else no "$1: nothing on the handset (it answered with rc=${PROBE_RC} and no output)"
    fi
}

if ! timeout "${ADB_WAIT_SECONDS}s" "${ADB_BIN}" -s "${SERIAL}" wait-for-device; then
    printf 'adb device %s did not appear within %s seconds\n' \
        "${SERIAL}" "${ADB_WAIT_SECONDS}" >&2
    exit 1
fi
if ! root_result="$(timeout "${ADB_WAIT_SECONDS}s" \
        "${ADB_BIN}" -s "${SERIAL}" root 2>&1)"; then
    root_result="${root_result//$'\r'/}"
    printf 'adb root failed or timed out for %s: %s\n' \
        "${SERIAL}" "${root_result:-<no output>}" >&2
    exit 1
fi
root_result="${root_result//$'\r'/}"
if ! timeout "${ADB_WAIT_SECONDS}s" "${ADB_BIN}" -s "${SERIAL}" wait-for-device; then
    printf 'adb device %s did not return after adb root within %s seconds\n' \
        "${SERIAL}" "${ADB_WAIT_SECONDS}" >&2
    exit 1
fi

# Start one follower per assertion-relevant logcat ring before doing any waits
# or active checks. Per-ring files let the reconnect proof compare each ring's
# own pre-drop tail with its own replay instead of inferring continuity from a
# mixed stream. The compatibility `continuous-logcat-all.txt` is assembled
# after the followers stop.
continuous_logcat_file="${CAPTURE_DIR}/continuous-logcat-all.txt"
continuous_dmesg_file="${CAPTURE_DIR}/continuous-dmesg.txt"
declare -A logcat_stream_file=()
declare -A logcat_stream_pid=()
declare -A logcat_stream_needs_reconnect=()
declare -A logcat_stream_reconnect_offset=()
declare -A logcat_stream_pre_drop_last=()
declare -A logcat_stream_replay_oldest=()
declare -A logcat_stream_overlap=()
LOGCAT_STREAM_FILES=()
for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
    logcat_stream_file["${logcat_buffer}"]="${CAPTURE_DIR}/continuous-logcat-${logcat_buffer}.txt"
    LOGCAT_STREAM_FILES+=("${logcat_stream_file[${logcat_buffer}]}")
    "${ADB_BIN}" -s "${SERIAL}" logcat -b "${logcat_buffer}" -v monotonic \
        >"${logcat_stream_file[${logcat_buffer}]}" 2>&1 &
    logcat_stream_pid["${logcat_buffer}"]=$!
    logcat_stream_needs_reconnect["${logcat_buffer}"]=false
    logcat_stream_reconnect_offset["${logcat_buffer}"]=0
    logcat_stream_pre_drop_last["${logcat_buffer}"]=""
    logcat_stream_replay_oldest["${logcat_buffer}"]="not-required"
    logcat_stream_overlap["${logcat_buffer}"]="not-required"
done
"${ADB_BIN}" -s "${SERIAL}" shell dmesg -w \
    >"${continuous_dmesg_file}" 2>&1 &
dmesg_pid=$!
streams_stopped=false
logcat_combined=false
logcat_combine_ok=false
record_temp_file=""
record_remote_active=false
record_remote_file="/sdcard/Movies/k50-vfy-${BASHPID}-${RANDOM}.mp4"
combine_logcat_streams() {
    local logcat_stream_path
    if [[ "${logcat_combined}" == true ]]; then
        [[ "${logcat_combine_ok}" == true ]]
        return
    fi
    logcat_combined=true
    logcat_combine_ok=true
    if ! : >"${continuous_logcat_file}"; then
        logcat_combine_ok=false
    else
        for logcat_stream_path in "${LOGCAT_STREAM_FILES[@]}"; do
            if ! cat -- "${logcat_stream_path}" \
                    >>"${continuous_logcat_file}"; then
                logcat_combine_ok=false
                break
            fi
        done
    fi
    [[ "${logcat_combine_ok}" == true ]]
}
cleanup_streams() {
    local all_stopped logcat_buffer pid
    local -a stream_pids=()
    if [[ "${record_remote_active:-false}" == true ]]; then
        if timeout 10s "${ADB_BIN}" -s "${SERIAL}" shell \
                rm -f "${record_remote_file}" >/dev/null 2>&1; then
            record_remote_active=false
        fi
    fi
    if [[ -n "${record_temp_file:-}" && -f "${record_temp_file}" && \
          ! -L "${record_temp_file}" && \
          "${record_temp_file}" == /tmp/k50-screenrecord.*.mp4 ]]; then
        if unlink -- "${record_temp_file}"; then
            record_temp_file=""
        fi
    fi
    if [[ "${streams_stopped}" == true ]]; then
        combine_logcat_streams || true
        return 0
    fi
    for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
        stream_pids+=("${logcat_stream_pid[${logcat_buffer}]}")
    done
    stream_pids+=("${dmesg_pid}")
    kill "${stream_pids[@]}" 2>/dev/null || true
    for _ in $(seq 1 50); do
        all_stopped=true
        for pid in "${stream_pids[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                all_stopped=false
                break
            fi
        done
        [[ "${all_stopped}" == true ]] && break
        sleep 0.1
    done
    for pid in "${stream_pids[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
    wait "${stream_pids[@]}" 2>/dev/null || true
    streams_stopped=true
    combine_logcat_streams || true
}
trap cleanup_streams EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sleep 1
for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
    if ! kill -0 "${logcat_stream_pid[${logcat_buffer}]}" 2>/dev/null; then
        skip "continuous ${logcat_buffer} logcat"
    fi
done
if ! kill -0 "${dmesg_pid}" 2>/dev/null; then
    skip "continuous dmesg"
fi

# Preserve the earliest window rooted adbd can reach. The block-device format
# and discard paths run around two seconds into boot; waiting for boot_completed
# and first-boot dexopt can rotate them out of both chatty log buffers.
early_dmesg="$(sh_ dmesg)"
early_logcat="$(logcat_snapshot)"
must_write_text "${CAPTURE_DIR}/early-dmesg.txt" "${early_dmesg}" || true
must_write_text "${CAPTURE_DIR}/early-logcat-all.txt" "${early_logcat}" || true
meta_initial="$({
    printf 'observed_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'serial=%s\n' "${SERIAL}"
    printf 'expected_tier=%s\n' "${EXPECTED_TIER}"
    printf 'stage_contract_sha256=%s\n' "${STAGE_CONTRACT_SHA}"
    printf 'source_manifest_sha256=%s\n' "${SOURCE_MANIFEST_SHA}"
    printf 'build_receipt_sha256=%s\n' "${BUILD_RECEIPT_SHA}"
    printf 'flash_receipt_sha256=%s\n' "${FLASH_RECEIPT_SHA}"
    printf 'expected_public_fingerprint=%s\n' "${K50SV1_EXPECT_FINGERPRINT}"
    printf 'expected_system_fingerprint=%s\n' "${K50SV1_EXPECT_SYSTEM_FINGERPRINT}"
    printf 'expected_incremental=%s\n' "${EXPECTED_INCREMENTAL}"
    printf 'radio_profile=%s\n' "${RADIO_PROFILE}"
    printf 'pstore_phase=%s\n' "${PSTORE_PHASE}"
    printf 'radio_wait_seconds=%s\n' "${RADIO_WAIT_SECONDS}"
    printf 'adb_root=%s\n' "${root_result}"
    printf 'tool.check_launcher_policy_sha256=%s\n' \
        "$(sha256sum "${TOOL_DIR}/check-launcher-policy.py" | awk '{print $1}')"
})"
must_write_text "${CAPTURE_DIR}/META.txt" "${meta_initial}" || true
[[ -n "${early_dmesg}" ]] || skip "early dmesg snapshot"
[[ -n "${early_logcat}" ]] || skip "early logcat snapshot"

boot_completed=false
last_boot_state=""
boot_read_failures=0
for _ in $(seq 1 "${BOOT_WAIT_ATTEMPTS}"); do
    if ! last_boot_state="$(timeout 5s "${ADB_BIN}" -s "${SERIAL}" \
            shell getprop sys.boot_completed 2>/dev/null)"; then
        boot_read_failures=$((boot_read_failures+1))
        if [[ "${boot_read_failures}" -ge 3 ]]; then
            must_append_text "${CAPTURE_DIR}/META.txt" \
                'last_sys_boot_completed=<three consecutive adb read failures>' || true
            printf 'adb transport failed three consecutive boot-state reads; evidence kept at %s\n' \
                "${CAPTURE_DIR}" >&2
            exit 1
        fi
        sleep 5
        continue
    fi
    last_boot_state="${last_boot_state//$'\r'/}"
    boot_read_failures=0
    if [[ "${last_boot_state}" == 1 ]]; then
        boot_completed=true
        break
    fi
    sleep 5
done
if [[ "${boot_completed}" != true ]]; then
    must_append_text "${CAPTURE_DIR}/META.txt" \
        "last_sys_boot_completed=${last_boot_state:-<unreadable>}" || true
    printf 'device failed to report sys.boot_completed=1 after %d seconds; evidence kept at %s\n' \
        "$((BOOT_WAIT_ATTEMPTS * 5))" "${CAPTURE_DIR}" >&2
    exit 1
fi

# boot_completed is NOT settled. On the first boot after a flash, installd is
# still dex2oat-ing every prebuilt APK -- with the omni GApps payload that is
# 128 files across all eight cores -- and adb shell round trips can come back
# empty. Wait for dex2oat to go quiet before asking the handset anything that
# matters, with a bound so this can never hang the run.
printf 'waiting for first-boot dexopt to settle'
dexopt_settled=false
dexopt_readable=true
last_dexopt_state=""
for _ in $(seq 1 60); do
    dexopt_probe="$(sh_ 'p="$(pgrep dex2oat 2>/dev/null)"; rc=$?; printf "__K50_PGREP_RC__=%s\n" "$rc"; printf "%s\n" "$p"')"
    dexopt_rc="$(printf '%s\n' "${dexopt_probe}" \
        | sed -n 's/^__K50_PGREP_RC__=//p')"
    last_dexopt_state="$(printf '%s\n' "${dexopt_probe}" \
        | sed '/^__K50_PGREP_RC__=/d')"
    case "${dexopt_rc}" in
        0) printf '.'; sleep 10 ;;
        1) dexopt_settled=true; break ;;
        *) dexopt_readable=false; break ;;
    esac
done
printf '\n'
if [[ "${dexopt_readable}" != true ]]; then
    skip "dex2oat process state"
elif [[ "${dexopt_settled}" != true ]]; then
    no "dex2oat still running after 600 s: ${last_dexopt_state:-<unreadable>}"
else
    ok "first-boot dexopt settled"
fi
# adbd briefly drops every host stream when Android changes the USB function
# from adb-only to mtp,adb near boot completion. Preserve the early bytes, wait
# until the replacement transport is configured twice consecutively, then
# reconnect either follower that was lost. Both commands replay their retained
# buffers, and the classifier de-duplicates normalized records.
logcat_any_reconnect=false
dmesg_needs_reconnect=false
dmesg_reconnect_offset=0
for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
    if ! kill -0 "${logcat_stream_pid[${logcat_buffer}]}" 2>/dev/null; then
        logcat_stream_needs_reconnect["${logcat_buffer}"]=true
        logcat_any_reconnect=true
    fi
done
dmesg_reconnect_anchor=""
dmesg_reconnect_anchor_hash="not-required"
kill -0 "${dmesg_pid}" 2>/dev/null || dmesg_needs_reconnect=true
usb_reconnect_ready=true
if [[ "${logcat_any_reconnect}" == true || \
      "${dmesg_needs_reconnect}" == true ]]; then
    usb_reconnect_ready=false
    usb_ready_observations=0
    usb_reconnect_deadline=$((SECONDS+30))
    while [[ "${SECONDS}" -lt "${usb_reconnect_deadline}" ]]; do
        usb_reconnect_remaining=$((usb_reconnect_deadline-SECONDS))
        usb_probe_timeout=5
        if [[ "${usb_reconnect_remaining}" -lt "${usb_probe_timeout}" ]]; then
            usb_probe_timeout="${usb_reconnect_remaining}"
        fi
        if [[ "${usb_probe_timeout}" -le 0 ]]; then
            break
        fi
        if usb_probe="$(timeout "${usb_probe_timeout}s" "${ADB_BIN}" \
                -s "${SERIAL}" shell \
                'printf "__K50_USB_STATE__=%s\n__K50_USB_CONFIG__=%s\n" "$(getprop sys.usb.state)" "$(getprop sys.usb.config)"' \
                2>/dev/null)"; then
            usb_probe="${usb_probe//$'\r'/}"
            usb_state="$(sed -n 's/^__K50_USB_STATE__=//p' <<<"${usb_probe}")"
            usb_config="$(sed -n 's/^__K50_USB_CONFIG__=//p' <<<"${usb_probe}")"
            if [[ -n "${usb_state}" && "${usb_state}" == "${usb_config}" && \
                  ",${usb_state}," == *,adb,* ]]; then
                usb_ready_observations=$((usb_ready_observations+1))
                if [[ "${usb_ready_observations}" -ge 2 ]]; then
                    usb_reconnect_ready=true
                    break
                fi
            else
                usb_ready_observations=0
            fi
        else
            usb_ready_observations=0
        fi
        sleep 1
    done
    if [[ "${usb_reconnect_ready}" != true ]]; then
        skip "settled post-boot adb USB transport for follower reconnect"
    fi
fi
if [[ "${usb_reconnect_ready}" == true && \
      "${logcat_any_reconnect}" == true ]]; then
    for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
        [[ "${logcat_stream_needs_reconnect[${logcat_buffer}]}" == true ]] \
            || continue
        logcat_stream_reconnect_offset["${logcat_buffer}"]="$(stat -c %s \
            "${logcat_stream_file[${logcat_buffer}]}" 2>/dev/null)"
        logcat_stream_pre_drop_last["${logcat_buffer}"]="$(LC_ALL=C awk '
            $1 ~ /^[0-9]+[.][0-9]+$/ && ($1 + 0) >= max {
                max=$1 + 0
                raw=$1
            }
            END { print raw }
        ' "${logcat_stream_file[${logcat_buffer}]}" 2>/dev/null)"
        wait "${logcat_stream_pid[${logcat_buffer}]}" 2>/dev/null || true
        "${ADB_BIN}" -s "${SERIAL}" logcat -b "${logcat_buffer}" \
            -v monotonic >>"${logcat_stream_file[${logcat_buffer}]}" 2>&1 &
        logcat_stream_pid["${logcat_buffer}"]=$!
    done
    note "continuous per-ring logcat followers reconnected after the boot USB transition"
fi
if [[ "${usb_reconnect_ready}" == true && \
      "${dmesg_needs_reconnect}" == true ]]; then
    dmesg_reconnect_offset="$(stat -c %s "${continuous_dmesg_file}" 2>/dev/null)"
    dmesg_reconnect_anchor="$(LC_ALL=C grep -aE \
        '^\[[[:space:]]*[0-9]+[.][0-9]+\]' \
        "${continuous_dmesg_file}" 2>/dev/null | tail -n 1)"
    if [[ -n "${dmesg_reconnect_anchor}" ]]; then
        dmesg_reconnect_anchor_hash="$(printf '%s' \
            "${dmesg_reconnect_anchor}" | sha256sum | awk '{print $1}')"
    else
        dmesg_reconnect_anchor_hash="missing"
    fi
    wait "${dmesg_pid}" 2>/dev/null || true
    "${ADB_BIN}" -s "${SERIAL}" shell dmesg -w \
        >>"${continuous_dmesg_file}" 2>&1 &
    dmesg_pid=$!
    note "continuous dmesg reconnected after the boot USB transition"
fi
sleep 1
for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
    if ! kill -0 "${logcat_stream_pid[${logcat_buffer}]}" 2>/dev/null; then
        skip "continuous ${logcat_buffer} logcat after boot USB transition"
    fi
done
if ! kill -0 "${dmesg_pid}" 2>/dev/null; then
    skip "continuous dmesg after boot USB transition"
fi
# Snapshot once: these were being re-fetched over adb for every single check.
#
# Through probe_remote(), not sh_(). sh_() throws the remote status away, so an
# empty snapshot from a dead transport and a handset that genuinely lists
# nothing produced the identical empty string -- and several gates below put
# their PASS on the "this is absent" side, which is exactly where a dead
# transport then landed. `pm list features`, `pm list packages` and
# `pm list packages -s` cannot legitimately be empty on a booted device, so
# readable means: the sentinel came back AND the snapshot has content. Every
# gate that asserts absence from one of these lists is gated on its flag.
snapshot_remote() {
    local target="$1" readable_flag="$2"
    probe_remote "$3"
    printf -v "${target}" '%s' "${PROBE_OUT}"
    if [[ -n "${PROBE_RC}" && -n "${PROBE_OUT}" ]]; then
        printf -v "${readable_flag}" true
    else
        printf -v "${readable_flag}" false
    fi
}
snapshot_remote features features_read 'pm list features'
snapshot_remote packages packages_read 'pm list packages'
snapshot_remote system_packages system_packages_read 'pm list packages -s'
mounts="$(sh_ cat /proc/mounts)"
registry="$(sh_ dumpsys telephony.registry)"
continuous_logcat_snapshot=""
current_logcat_snapshot=""
combined_logs=""
refresh_combined_logs() {
    continuous_logcat_snapshot="$(cat -- "${LOGCAT_STREAM_FILES[@]}" 2>/dev/null)"
    current_logcat_snapshot="$(logcat_snapshot)"
    combined_logs="$({
        printf '%s\n' "${early_logcat}"
        printf '%s\n' "${continuous_logcat_snapshot}"
        printf '%s\n' "${current_logcat_snapshot}"
    } | sort -u)"
    [[ -n "${continuous_logcat_snapshot}" && -n "${current_logcat_snapshot}" ]]
}
if ! refresh_combined_logs; then
    skip "continuous/current logcat coverage"
fi

has() { printf '%s\n' "$2" | grep -q -- "$1"; }
has_line() { printf '%s\n' "$2" | grep -Fqx -- "$1"; }
launch_package() {
    local package="$1" label="$2" result launch_rc error warning resumed_probe
    local probe_rc resumed_rc resumed resumed_log="" last_probe_readable=false
    local launched=false stable_probes=0
    result="$(timeout 15s "${ADB_BIN}" -s "${SERIAL}" shell \
        "am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -p ${package}" \
        2>&1)"
    launch_rc=$?
    result="${result//$'\r'/}"
    launch_record="$({
        printf 'host_adb_rc=%s\n' "${launch_rc}"
        printf '%s\n' "${result}"
    })"
    must_write_text "${CAPTURE_DIR}/launch-${package}.txt" \
        "${launch_record}" || true
    error="$(sed -n 's/^Error: */Error: /p' <<<"${result}")"
    warning="$(sed -n 's/^Warning: */Warning: /p' <<<"${result}")"
    if [[ "${launch_rc}" -ne 0 ]]; then
        skip "${label} launch command"
    elif [[ -n "${error}" ]]; then
        no "${label} launch failed: ${error}"
    else
        [[ -n "${warning}" ]] && note "${label} launch diagnostic: ${warning}"
        local tries=10 permission_grace=20
        while [[ "${tries}" -gt 0 ]]; do
            tries=$((tries - 1))
            resumed_probe="$(timeout 10s "${ADB_BIN}" -s "${SERIAL}" shell '
                raw="$(dumpsys activity activities 2>&1)"
                rc=$?
                out="$(printf "%s\n" "$raw" | awk "/mResumedActivity/ {print; exit}")"
                printf "__K50_ACTIVITY_RC__=%s\n" "$rc"
                printf "%s\n" "$out"
            ' 2>/dev/null)"
            probe_rc=$?
            resumed_probe="${resumed_probe//$'\r'/}"
            resumed_rc="$(printf '%s\n' "${resumed_probe}" \
                | sed -n 's/^__K50_ACTIVITY_RC__=//p')"
            resumed="$(printf '%s\n' "${resumed_probe}" \
                | sed '/^__K50_ACTIVITY_RC__=/d')"
            resumed_log+="host_adb_rc=${probe_rc} ${resumed_probe//$'\n'/ }"$'\n'
            last_probe_readable=false
            if [[ "${probe_rc}" -eq 0 && "${resumed_rc}" == 0 && \
                  -n "${resumed}" ]]; then
                last_probe_readable=true
                if [[ "${resumed}" == *"${package}/"* ]]; then
                    # A newly resumed app can still dispatch a permission
                    # activity. DeskClock did so after the next app launched,
                    # returning focus to Clock and falsely failing Calendar.
                    # Require three samples, one second apart, before moving on.
                    stable_probes=$((stable_probes + 1))
                    if [[ "${stable_probes}" -ge 3 ]]; then
                        launched=true
                        break
                    fi
                else
                    stable_probes=0
                fi
                # A runtime-permission dialog on top is the app starting, not a
                # different app winning. On a freshly wiped /data every first
                # launch raises one, and it held the foreground for the whole
                # budget: Etar reported "did not become the resumed package"
                # while GrantPermissionsActivity was resumed, and launching it
                # by hand a moment later worked. Refund the iteration, up to a
                # bounded grace, so the dialog cannot spend the budget and
                # cannot hang the check either.
                if [[ "${resumed}" == *com.android.permissioncontroller/* && \
                      "${permission_grace}" -gt 0 ]]; then
                    permission_grace=$((permission_grace - 1))
                    tries=$((tries + 1))
                fi
            else
                stable_probes=0
            fi
            sleep 1
        done
        must_write_text "${CAPTURE_DIR}/launch-${package}-resumed.txt" \
            "${resumed_log}" || true
        if [[ "${launched}" == true ]]; then
            ok "${label} opens and remains resumed (${package})"
        elif [[ "${last_probe_readable}" != true ]]; then
            skip "${label} resumed-activity probes"
        else
            no "${label} did not become the resumed package"
        fi
    fi
}

printf '\n== identity ==\n'
fingerprint="$(sh_ getprop ro.build.fingerprint)"
build_type="$(sh_ getprop ro.build.type)"
debuggable="$(sh_ getprop ro.debuggable)"
adb_secure="$(sh_ getprop ro.adb.secure)"
adb_root="$(sh_ getprop service.adb.root)"
shell_uid="$(sh_ id -u)"
selinux_mode="$(sh_ getenforce)"
privapp_mode="$(sh_ getprop ro.control_privapp_permissions)"
usb_config="$(sh_ getprop persist.sys.usb.config)"

# WAS ONLY A note(): the build fingerprint -- the one field that says WHICH
# image every other check in this file is describing -- was informational, and
# note() cannot fail. A run against yesterday's image produced a full green
# report about a build nobody flashed. Assert it.
#
# Expectations above were derived from the validated stage and flash receipts;
# inherited shell variables are deliberately overwritten and are not trusted.
if [[ -z "${fingerprint}" ]]; then
    skip "build fingerprint"
elif [[ "${fingerprint}" == "${K50SV1_EXPECT_FINGERPRINT}" ]]; then
    ok "fingerprint  ${fingerprint}"
else
    no "fingerprint is ${fingerprint}, expected ${K50SV1_EXPECT_FINGERPRINT} -- every result below describes a DIFFERENT image"
fi

# Google Play sees the public Coral identity; hardware/update/provenance fields
# must remain this LineageOS 17.1 MTK product. A matching fingerprint alone is
# not enough: CTS also checks its brand/product/device components against the
# public Build fields, while copying Pixel board/API/SPL values would break or
# misrepresent the device.
for pair in \
    'ro.product.brand=google' \
    'ro.product.name=coral' \
    'ro.product.device=coral' \
    'ro.product.manufacturer=Google' \
    'ro.product.model=Pixel 4 XL' \
    'ro.build.id=QQ3A.200805.001' \
    'ro.build.display.id=QQ3A.200805.001' \
    'ro.build.description=coral-user 10 QQ3A.200805.001 6578210 release-keys' \
    'ro.build.product=k50sv1_64_bsp' \
    'ro.build.version.release=10' \
    'ro.build.version.sdk=29' \
    'ro.lineage.build.version=17.1' \
    'ro.lineage.device=k50sv1_64_bsp' \
    'ro.product.system.brand=XSH' \
    'ro.product.system.name=lineage_k50sv1_64_bsp' \
    'ro.product.system.device=k50sv1_64_bsp' \
    'ro.product.system.manufacturer=XSH' \
    'ro.product.system.model=F212' \
    'ro.product.vendor.brand=XSH' \
    'ro.product.vendor.name=lineage_k50sv1_64_bsp' \
    'ro.product.vendor.device=k50sv1_64_bsp' \
    'ro.product.vendor.manufacturer=XSH' \
    'ro.product.vendor.model=F212' \
    'ro.product.board=k50sv1_64_bsp' \
    'ro.board.platform=mt6755' \
    'ro.product.first_api_level=26' \
    'ro.build.version.security_patch=2023-02-05' \
    'ro.vendor.build.security_patch=2020-08-05'; do
    prop="${pair%%=*}"
    expected="${pair#*=}"
    actual="$(sh_ getprop "${prop}")"
    [[ "${actual}" == "${expected}" ]] \
        && ok "${prop}=${actual}" \
        || no "${prop}=${actual:-<unset>} (expected ${expected})"
done

system_fingerprint="$(sh_ getprop ro.system.build.fingerprint)"
vendor_fingerprint="$(sh_ getprop ro.vendor.build.fingerprint)"
bootimage_fingerprint="$(sh_ getprop ro.bootimage.build.fingerprint)"
if [[ -z "${system_fingerprint}" ]]; then
    no "ro.system.build.fingerprint is unset"
elif [[ "${system_fingerprint}" != "${K50SV1_EXPECT_SYSTEM_FINGERPRINT}" ]]; then
    no "ro.system.build.fingerprint=${system_fingerprint}, expected staged ${K50SV1_EXPECT_SYSTEM_FINGERPRINT} -- the constant Coral public fingerprint cannot identify this image"
elif [[ "${system_fingerprint}" == "${fingerprint}" ]]; then
    no "system partition fingerprint equals the public Coral spoof; real partition provenance was overwritten"
else
    ok "exact staged system partition fingerprint: ${system_fingerprint}"
fi
if [[ "${vendor_fingerprint}" == "${K50SV1_EXPECT_SYSTEM_FINGERPRINT}" ]]; then
    ok "vendor fingerprint matches the exact clean system build: ${vendor_fingerprint}"
else
    no "ro.vendor.build.fingerprint=${vendor_fingerprint:-<unset>}, expected exact staged ${K50SV1_EXPECT_SYSTEM_FINGERPRINT}"
fi
if [[ "${bootimage_fingerprint}" == "${K50SV1_EXPECT_SYSTEM_FINGERPRINT}" ]]; then
    ok "bootimage fingerprint matches the exact clean system build: ${bootimage_fingerprint}"
else
    no "ro.bootimage.build.fingerprint=${bootimage_fingerprint:-<unset>}, expected exact staged ${K50SV1_EXPECT_SYSTEM_FINGERPRINT}"
fi
# "Absent" is this check's PASS, and sh_() returns the same empty string for an
# unset property and for a transport that delivered nothing. Only the sentinel
# separates them.
probe_remote 'getprop ro.product.build.fingerprint'
if [[ -z "${PROBE_RC}" ]]; then
    skip "ro.product.build.fingerprint is absent"
elif [[ -z "${PROBE_OUT}" ]]; then
    ok "ro.product.build.fingerprint is absent (this A-only target has no product image)"
else
    no "unexpected ro.product.build.fingerprint=${PROBE_OUT} on a target with no product image"
fi
for incremental_prop in \
    ro.build.version.incremental \
    ro.system.build.version.incremental \
    ro.vendor.build.version.incremental; do
    actual_incremental="$(sh_ getprop "${incremental_prop}")"
    [[ "${actual_incremental}" == "${EXPECTED_INCREMENTAL}" ]] \
        && ok "${incremental_prop}=${actual_incremental}" \
        || no "${incremental_prop}=${actual_incremental:-<unset>} (expected ${EXPECTED_INCREMENTAL})"
done
probe_remote 'getprop ro.mtk_gmo_ram_optimize'
if [[ -z "${PROBE_RC}" ]]; then
    skip "ro.mtk_gmo_ram_optimize"
elif [[ -z "${PROBE_OUT}" || "${PROBE_OUT}" == 0 ]]; then
    ok "ro.mtk_gmo_ram_optimize=${PROBE_OUT:-<unset>} (Mali's device-name branch remains inactive)"
else
    no "ro.mtk_gmo_ram_optimize=${PROBE_OUT} -- Coral changes Mali's branch when this is 1"
fi

# /vendor must be mounted read-only. A hand-patched read-write /vendor has
# already happened on this device, and it is worse than a wrong fingerprint:
# the fingerprint still names the flashed build while the partition no longer
# matches it, so every downstream result describes a build that was never
# flashed and cannot be reproduced. `adb remount` / `mount -o rw,remount` leaves
# exactly one trace, and this is it.
probe_remote 'cat /proc/mounts'
if [[ -z "${PROBE_RC}" ]]; then
    skip "/vendor is mounted ro"
else
    vendor_mount_opts="$(awk '$2 == "/vendor" { print $4 }' <<<"${PROBE_OUT}" | sed -n '1p')"
    if [[ -z "${vendor_mount_opts}" ]]; then
        no "/vendor is not in /proc/mounts at all"
    elif [[ ",${vendor_mount_opts}," == *,ro,* ]]; then
        ok "/vendor mounted ro (${vendor_mount_opts})"
    else
        no "/vendor is mounted ${vendor_mount_opts} -- it has been remounted read-write, so the partition no longer matches ${fingerprint:-the fingerprint} and nothing below describes a reproducible build"
    fi
fi
[[ "${build_type}" == userdebug ]] && ok "build type: userdebug" \
    || no "build type: ${build_type:-<unset>} (tiers 1/2 require userdebug)"
[[ "${debuggable}" == 1 ]] && ok "ro.debuggable=1" \
    || no "ro.debuggable=${debuggable:-<unset>} (tiers 1/2 require 1)"
[[ "${shell_uid}" == 0 ]] && ok "root adb shell" \
    || no "adb shell uid=${shell_uid:-<unreadable>} (tiers 1/2 require root)"
[[ "${adb_secure}" == 0 ]] && ok "ro.adb.secure=0" \
    || no "ro.adb.secure=${adb_secure:-<unset>} (tiers 1/2 require insecure adb)"
[[ "${adb_root}" == 1 ]] && ok "service.adb.root=1" \
    || no "service.adb.root=${adb_root:-<unset>}"
case ",${usb_config}," in
    *,adb,*) ok "USB config exposes adb: ${usb_config}" ;;
    *)       no "USB config does not expose adb: ${usb_config:-<unset>}" ;;
esac

if [[ "${EXPECTED_TIER}" == 1 ]]; then
    [[ "${selinux_mode}" == Permissive ]] && ok "SELinux permissive (Tier 1)" \
        || no "SELinux is ${selinux_mode:-<unreadable>}; Tier 1 must be Permissive"
    [[ "${privapp_mode}" == log ]] && ok "privapp mode=log (Tier 1)" \
        || no "privapp mode=${privapp_mode:-<unset>}; Tier 1 must be log"
else
    [[ "${selinux_mode}" == Enforcing ]] && ok "SELinux enforcing (Tier 2)" \
        || no "SELinux is ${selinux_mode:-<unreadable>}; Tier 2 must be Enforcing"
    [[ "${privapp_mode}" == enforce ]] && ok "privapp mode=enforce (Tier 2)" \
        || no "privapp mode=${privapp_mode:-<unset>}; Tier 2 must be enforce"
fi
note "ro.boot.selinux=$(sh_ getprop ro.boot.selinux)"

printf '\n== input: every device must resolve to its own key layout ==\n'
# Before: all five fell back to Generic.kl, and HALL_DEV.kl did not even parse.
inp="$(sh_ dumpsys input)"
# Only devices EventHub classifies as keyboards get a key layout at all
# (INPUT_DEVICE_CLASS_KEYBOARD, Classes bit 0x1). fts_ts is a pure touchscreen
# here -- Classes 0x14, TOUCH|TOUCH_MT -- because the Focaltech gesture engine
# is left off, so it advertises no keys and can never resolve a .kl no matter
# what is installed. Demanding one was a check that could not pass. The file is
# still shipped on purpose: it is the safety net that keeps the gesture scan
# codes off Generic.kl if fts_gesture_mode is ever enabled, and the header of
# keylayout/fts_ts.kl says so.
for dev in mtk-kpd ACCDET fts_ts HALL_DEV; do
    blk="$(printf '%s' "${inp}" | grep -A9 ": ${dev}\$")"
    kl="$(printf '%s' "${blk}" | sed -n 's/.*KeyLayoutFile: *//p' | head -1)"
    cls="$(printf '%s' "${blk}" | sed -n 's/.*Classes: *//p' | head -1)"
    if [[ -z "${cls}" ]]; then
        skip "${dev} key layout"
    elif (( $((cls)) & 0x1 )); then
        case "${kl}" in
            /vendor/usr/keylayout/${dev}.kl) ok "${dev} -> ${kl}" ;;
            *) no "${dev} -> ${kl:-<none>} (expected /vendor/usr/keylayout/${dev}.kl)" ;;
        esac
    elif [[ -z "${kl}" ]]; then
        ok "${dev} advertises no keys (Classes=${cls}); no key layout is loaded, as expected"
    else
        no "${dev} has no keyboard class (Classes=${cls}) yet loaded ${kl}"
    fi
done
note "keys down now: $(printf '%s' "${inp}" | grep -c 'KeyDowns: [1-9]') device(s) with a key held"

printf '\n== memory: the Dalvik heap was previously unset entirely ==\n'
# ro.config.low_ram and the four notLowRam features used to be asserted HERE, in
# the direction "low_ram must be on and the features must be gone". Android Go
# was removed at the owner's request, so those five assertions now assert the
# opposite of what the product wants; they are in the "full android" section
# below, inverted. A check that outlives the decision it encodes is a check that
# fails for being right.
for p in dalvik.vm.heapstartsize dalvik.vm.heapgrowthlimit dalvik.vm.heapsize \
         dalvik.vm.heaptargetutilization ro.config.per_app_memcg; do
    check "${p}" "getprop ${p}"
done

printf '\n== cgroups: placeholder dirs must be gone, and quiet ==\n'
# WAS BROKEN: `if sh_ "test -d ${d} && echo yes" | grep -q yes` ... `else ok`.
# sh_() throws the remote exit status away and prints nothing when the transport
# is dead, so "the handset says the directory is gone" and "nothing came back at
# all" produced the identical empty string -- and the PASS lived in the `else`
# branch, so a dead transport reported all four directories removed. That is the
# exact failure mode probe_remote() was added for; use its three-state form and
# skip when the sentinel does not come back.
for d in /dev/stune /dev/cpuset /dev/memcg /dev/cg2_bpf; do
    probe_remote "if [ -d ${d} ]; then echo __K50_DIR__present; ls -A ${d}; else echo __K50_DIR__absent; fi"
    dir_verdict="$(sed -n 's/^__K50_DIR__//p' <<<"${PROBE_OUT}")"
    if [[ -z "${PROBE_RC}" || -z "${dir_verdict}" ]]; then
        skip "${d} removed"
    elif [[ "${dir_verdict}" == absent ]]; then
        ok "${d} removed"
    else
        no "${d} still exists ($(sed '/^__K50_DIR__/d' <<<"${PROBE_OUT}" | tr '\n' ' '))"
    fi
done

printf '\n== features added this session ==\n'
# The absent-hardware half below puts its PASS on "not in the list", so an
# unread snapshot was six free green lines about hardware nobody asked the
# handset about. Both halves read the same snapshot, so both are gated on it.
for f in android.hardware.bluetooth_le android.hardware.opengles.aep \
         android.hardware.usb.accessory android.hardware.wifi.direct \
         android.software.midi android.hardware.telephony.ims; do
    if [[ "${features_read}" != true ]]; then
        skip "${f}"
    elif has "^feature:${f}$" "${features}"; then ok "${f}"; else no "${f}"; fi
done
for f in android.hardware.sensor.compass android.hardware.fingerprint \
         android.hardware.nfc android.hardware.sensor.light \
         android.hardware.sensor.proximity android.software.nfc.beam; do
    if [[ "${features_read}" != true ]]; then
        skip "${f} correctly absent"
    elif has "^feature:${f}$" "${features}"; then
        no "${f} declared but the hardware is absent"
    else
        ok "${f} correctly absent"
    fi
done

# The jar alone is not a shared library. SystemConfig must parse the matching
# <library> declaration restored by WI-040.
lineage_library="$(sh_ 'dumpsys package libraries 2>/dev/null | grep -F org.lineageos.platform')"
if [[ -n "${lineage_library}" ]]; then
    ok "Lineage SDK shared library registered"
else
    no "org.lineageos.platform is absent from PackageManager shared libraries"
fi

printf '\n== storage and partitions ==\n'
for m in /mnt/vendor/protect_f /mnt/vendor/protect_s /mnt/vendor/nvdata; do
    if has " ${m} " "${mounts}"; then ok "${m} mounted"; else no "${m} NOT mounted"; fi
done
nvdata_opts="$(printf '%s\n' "${mounts}" | awk '$2 == "/mnt/vendor/nvdata" { print $4; exit }')"
case ",${nvdata_opts}," in
    *,discard,*) no "nvdata is mounted with online discard: ${nvdata_opts}" ;;
    ,,)          skip "nvdata mount options" ;;
    *)           ok "nvdata online discard disabled" ;;
esac
crypto_state="$(sh_ getprop ro.crypto.state)"; crypto_type="$(sh_ getprop ro.crypto.type)"
# Not `check`, which only tests non-emptiness -- with both getprops empty the
# argument was the string "/", which is non-empty, so this check could never
# fail and never skip. It was one of the 77.
# userdata is deliberately UNENCRYPTED on every tier (fstab.mt6755 says why),
# so the expected state is `unsupported` with no ro.crypto.type at all.
# `unsupported` and `unencrypted` are NOT interchangeable: builtins.cpp:581-588
# gives `unencrypted` to a partition that COULD be encrypted (encryptable=) and
# `unsupported` to one with no encryption flag, which is this fstab. Reporting
# either as a pass would hide an fstab regression in exactly the direction that
# matters.
if [[ -z "${crypto_state}" ]]; then skip "crypto state"
elif [[ "${crypto_state}" == "unsupported" && -z "${crypto_type}" ]]; then
    ok "crypto state: unsupported (userdata unencrypted by design)"
elif [[ "${crypto_state}" == "encrypted" ]]; then
    no "crypto state: ${crypto_state}/${crypto_type} -- userdata is encrypted, but this tree ships no encryption flag. The fstab regressed, or the device was not wiped."
else
    no "crypto state: ${crypto_state}/${crypto_type} (expected unsupported with no type)"
fi
if sh_ "test -L /mnt/sdcard && echo yes" | grep -q yes; then ok "/mnt/sdcard symlink present"; else no "/mnt/sdcard missing"; fi

printf '\n== usb ==\n'
check "sys.usb.ffs.ready" "getprop sys.usb.ffs.ready"
check "sys.usb.state" "getprop sys.usb.state"
if sh_ "test -d /dev/usb-ffs/adb && echo yes" | grep -q yes; then ok "/dev/usb-ffs/adb present"; else no "/dev/usb-ffs/adb missing"; fi

printf '\n== ims / volte ==\n'
# persist.dbg.volte_avail_ovr=1 used to be asserted here. It was removed from
# the tree on purpose -- lineage_k50sv1_64_bsp.mk:133 "is deliberately NOT
# here", init.mt6755.rc:381 "is gone from both places" -- because it
# short-circuits ImsManager.isVolteEnabledByPlatform() (:622-637) instead of
# satisfying it, so it also defeated config_device_volte_available and
# isGbaValid(). The platform gate moved to
# overlay/packages/apps/CarrierConfig/res/xml/vendor.xml, and the gate for it
# is carrier_volte_available_bool, checked with the other CarrierConfig
# outcomes further down. The old assertion could therefore only ever FAIL;
# measured on the live handset:
#     $ adb shell getprop persist.dbg.volte_avail_ovr
#     (empty)
# What is asserted here instead is that it STAYED removed: a persisted 1 left
# in /data would silently re-enable the short circuit, which is the exact
# failure init.mt6755.rc:376-385 restates the other two _ovr keys to prevent.
volte_ovr="$(sh_ getprop persist.dbg.volte_avail_ovr)"
if [[ -z "${volte_ovr}" || "${volte_ovr}" == 0 ]]; then
    ok "persist.dbg.volte_avail_ovr=${volte_ovr:-<unset>} (the debug short circuit stayed removed)"
else
    no "persist.dbg.volte_avail_ovr=${volte_ovr} -- the debug short circuit is back and bypasses config_device_volte_available"
fi
for pair in \
    persist.vendor.volte_support=1 \
    ro.vendor.mtk_ril_mode=c6m_3rild; do
    prop="${pair%%=*}"; expected="${pair#*=}"; actual="$(sh_ getprop "${prop}")"
    [[ "${actual}" == "${expected}" ]] && ok "${prop}=${actual}" \
        || no "${prop}=${actual:-<unset>} (expected ${expected})"
done
if [[ "${packages_read}" != true ]]; then skip "com.mediatek.ims installed"
elif has "^package:com.mediatek.ims$" "${packages}"; then ok "com.mediatek.ims installed"
else no "com.mediatek.ims missing"; fi

sim_state="$(sh_ getprop gsm.sim.state)"
sim_operator="$(sh_ getprop gsm.sim.operator.numeric)"
operator_numeric="$(sh_ getprop gsm.operator.numeric)"
operator_roaming="$(sh_ getprop gsm.operator.isroaming)"
mapfile -t service_states < <(printf '%s\n' "${registry}" | awk '/mServiceState=/{print}')
phone0_state="${service_states[0]:-}"
phone1_state="${service_states[1]:-}"
refresh_radio_state() {
    local probe_timeout="${1:-15}" probe
    if ! probe="$(timeout "${probe_timeout}s" "${ADB_BIN}" -s "${SERIAL}" shell '
        for p in gsm.sim.state gsm.sim.operator.numeric gsm.operator.numeric gsm.operator.isroaming; do
            printf "__K50_PROP__%s=" "$p"
            getprop "$p"
        done
        printf "__K50_REGISTRY__\n"
        dumpsys telephony.registry
    ' 2>/dev/null)"; then
        sim_state=""; sim_operator=""; operator_numeric=""; operator_roaming=""
        registry=""; service_states=(); phone0_state=""; phone1_state=""
        radio_snapshot_readable=false
        return 1
    fi
    probe="${probe//$'\r'/}"
    sim_state="$(sed -n 's/^__K50_PROP__gsm[.]sim[.]state=//p' <<<"${probe}")"
    sim_operator="$(sed -n 's/^__K50_PROP__gsm[.]sim[.]operator[.]numeric=//p' <<<"${probe}")"
    operator_numeric="$(sed -n 's/^__K50_PROP__gsm[.]operator[.]numeric=//p' <<<"${probe}")"
    operator_roaming="$(sed -n 's/^__K50_PROP__gsm[.]operator[.]isroaming=//p' <<<"${probe}")"
    registry="$(sed -n '/^__K50_REGISTRY__$/,$ {
        /^__K50_REGISTRY__$/d
        p
    }' <<<"${probe}")"
    mapfile -t service_states < <(
        printf '%s\n' "${registry}" | awk '/mServiceState=/{print}'
    )
    phone0_state="${service_states[0]:-}"
    phone1_state="${service_states[1]:-}"
    radio_snapshot_readable=true
}
# `registrationState=` is not unique inside an mServiceState line. The line
# carries one NetworkRegistrationInfo record per (domain, transportType) pair,
# each with its own registrationState. Measured on the live handset, from a
# single mServiceState line:
#
#   NetworkRegistrationInfo{ domain=CS transportType=WWAN registrationState=HOME
#       roamingType=NOT_ROAMING accessNetworkTechnology=LTE ...
#   NetworkRegistrationInfo{ domain=PS transportType=WWAN registrationState=HOME
#       roamingType=NOT_ROAMING accessNetworkTechnology=LTE ...
#
# so the old unanchored *'registrationState=ROAMING'* could be satisfied by the
# PS record, or by a PS/IWLAN record, while the CS one said something else --
# the substring cannot say which (domain, transportType) supplied it. Require
# the three fields contiguously, in the order dumpsys prints them, with a
# trailing separator so one state name cannot match the prefix of another.
cs_wwan_registration_is() {
    [[ "$1" == *"domain=CS transportType=WWAN registrationState=$2"[[:space:]},]* ]]
}
radio_control_ready() {
    case "${RADIO_PROFILE}" in
        dual-cn)
            [[ "${sim_state}" == LOADED,LOADED && \
               "${sim_operator}" == 46000,46001 && \
               "${operator_numeric}" == 20408,20416 && \
               "${operator_roaming}" == true,true && \
               "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'getRilVoiceRadioTechnology=14(LTE)'* && \
               "${phone0_state}" == *'getRilDataRadioTechnology=14(LTE)'* && \
               "${phone0_state}" == *'mIsEmergencyOnly=false'* && \
               "${phone1_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone1_state}" == *'mDataRegState=1(OUT_OF_SERVICE)'* && \
               "${phone1_state}" == *'getRilVoiceRadioTechnology=3(UMTS)'* && \
               "${phone1_state}" == *'getRilDataRadioTechnology=0(Unknown)'* && \
               "${phone1_state}" == *'mIsEmergencyOnly=false'* ]] && \
            cs_wwan_registration_is "${phone0_state}" ROAMING && \
            cs_wwan_registration_is "${phone1_state}" ROAMING
            ;;
        lebara-slot0)
            [[ "${sim_state}" == LOADED,ABSENT && \
               "${sim_operator}" == 20408 && \
               "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* ]] && \
            cs_wwan_registration_is "${phone0_state}" HOME
            ;;
        # The fixture that is actually in the handset (HANDOFF "State"):
        # slot 0 Vodafone NL 20404 on its OWN network, slot 1 CMCC 46000
        # roaming on KPN 20408. That ordering is deliberate -- IMS only ever
        # runs on the main-capability phone, which is phone 0, so a VoLTE test
        # SIM has to be in slot 0.
        #
        # Slot 1 asserts GSM, not UMTS. `persist.vendor.radio.mtk_ps2_rat` is
        # W/G, but the modem reports GSM only and E-084 measured EDGE on both
        # cards tried there; `getRilVoiceRadioTechnology=16(GSM)` is what the
        # handset prints. Do not "correct" this to UMTS.
        vdf-nl-slot0)
            [[ "${sim_state}" == LOADED,LOADED && \
               "${sim_operator}" == 20404,46000 && \
               "${operator_numeric}" == 20404,20408 && \
               "${operator_roaming}" == false,true && \
               "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'getRilVoiceRadioTechnology=14(LTE)'* && \
               "${phone0_state}" == *'getRilDataRadioTechnology=14(LTE)'* && \
               "${phone0_state}" == *'mIsEmergencyOnly=false'* && \
               "${phone1_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone1_state}" == *'mDataRegState=1(OUT_OF_SERVICE)'* && \
               "${phone1_state}" == *'getRilVoiceRadioTechnology=16(GSM)'* && \
               "${phone1_state}" == *'getRilDataRadioTechnology=0(Unknown)'* && \
               "${phone1_state}" == *'mIsEmergencyOnly=false'* ]] && \
            cs_wwan_registration_is "${phone0_state}" HOME && \
            cs_wwan_registration_is "${phone1_state}" ROAMING
            ;;
        # Current fixture, captured before this build: China Unicom 46001 in
        # the LTE-capable slot roaming on Vodafone NL, and China Mobile 46000
        # in the fixed W/G slot roaming on KPN/GSM.
        cu-slot0-cmcc-slot1)
            [[ "${sim_state}" == LOADED,LOADED && \
               "${sim_operator}" == 46001,46000 && \
               "${operator_numeric}" == 20404,20408 && \
               "${operator_roaming}" == true,true && \
               "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* && \
               "${phone0_state}" == *'getRilVoiceRadioTechnology=14(LTE)'* && \
               "${phone0_state}" == *'getRilDataRadioTechnology=14(LTE)'* && \
               "${phone0_state}" == *'mIsEmergencyOnly=false'* && \
               "${phone1_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
               "${phone1_state}" == *'mDataRegState=1(OUT_OF_SERVICE)'* && \
               "${phone1_state}" == *'getRilVoiceRadioTechnology=16(GSM)'* && \
               "${phone1_state}" == *'getRilDataRadioTechnology=0(Unknown)'* && \
               "${phone1_state}" == *'mIsEmergencyOnly=false'* ]] && \
            cs_wwan_registration_is "${phone0_state}" ROAMING && \
            cs_wwan_registration_is "${phone1_state}" ROAMING
            ;;
        # A `case` with no matching arm returns 0. Without this, adding a radio
        # profile name to the argument validation at the top of the file and
        # forgetting these two switches would make the handset look settled
        # after zero comparisons -- which is exactly the work WI-049 asks for.
        *) return 1 ;;
    esac
}
radio_snapshot_readable=false
radio_wait_start="${SECONDS}"
radio_deadline=$((radio_wait_start + RADIO_WAIT_SECONDS))
initial_probe_timeout=15
(( RADIO_WAIT_SECONDS < initial_probe_timeout )) \
    && initial_probe_timeout="${RADIO_WAIT_SECONDS}"
refresh_radio_state "${initial_probe_timeout}" || true
if ! radio_control_ready; then
    printf 'waiting for %s radio control to settle' "${RADIO_PROFILE}"
    while (( SECONDS < radio_deadline )); do
        remaining=$((radio_deadline - SECONDS))
        probe_timeout=15
        (( remaining < probe_timeout )) && probe_timeout="${remaining}"
        # `timeout 0s CMD` in GNU coreutils means NO timeout, not "expire
        # immediately" (coreutils timeout(1): "A duration of 0 disables the
        # associated timeout"). Once `remaining` reached 0 -- which it does on
        # the last pass of every loop that runs to the deadline -- this handed
        # refresh_radio_state a 0, and a wedged `dumpsys telephony.registry`
        # then hung forever inside a loop whose whole purpose was to bound the
        # wait at RADIO_WAIT_SECONDS. The USB reconnect loop above already has
        # this guard at its line 428; this loop did not.
        (( probe_timeout <= 0 )) && break
        refresh_radio_state "${probe_timeout}" || true
        radio_control_ready && break
        printf '.'
        remaining=$((radio_deadline - SECONDS))
        (( remaining <= 0 )) && break
        sleep_for=5
        (( remaining < sleep_for )) && sleep_for="${remaining}"
        sleep "${sleep_for}"
    done
    printf '\n'
fi
radio_wait_seconds=$((SECONDS - radio_wait_start))
if radio_control_ready; then
    ok "${RADIO_PROFILE} radio control settled after ${radio_wait_seconds}s"
elif [[ "${radio_snapshot_readable}" != true ]]; then
    skip "${RADIO_PROFILE} radio control snapshots within ${radio_wait_seconds}s"
else
    no "${RADIO_PROFILE} radio control did not settle within ${radio_wait_seconds}s"
fi
case "${RADIO_PROFILE}" in
    dual-cn)
        [[ "${sim_state}" == LOADED,LOADED ]] && ok "both control SIMs loaded" \
            || no "gsm.sim.state=${sim_state:-<unset>} (expected LOADED,LOADED)"
        [[ "${sim_operator}" == 46000,46001 ]] && ok "SIM layout: CMCC slot 0, CU slot 1" \
            || no "gsm.sim.operator.numeric=${sim_operator:-<unset>} (expected 46000,46001)"
        [[ "${operator_roaming}" == true,true ]] && ok "both control SIMs roaming" \
            || no "gsm.operator.isroaming=${operator_roaming:-<unset>} (expected true,true)"
        [[ "${operator_numeric}" == 20408,20416 ]] \
            && ok "visited operators: KPN 20408, T-Mobile 20416" \
            || no "gsm.operator.numeric=${operator_numeric:-<unset>} (expected 20408,20416)"
        if [[ "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'getRilVoiceRadioTechnology=14(LTE)'* && \
              "${phone0_state}" == *'getRilDataRadioTechnology=14(LTE)'* && \
              "${phone0_state}" == *'mIsEmergencyOnly=false'* ]] && \
           cs_wwan_registration_is "${phone0_state}" ROAMING; then
            ok "slot 0 CMCC voice/data registered while roaming"
        else
            no "slot 0 CMCC is not stock-equivalent: ${phone0_state:-<unreadable>}"
        fi
        if [[ "${phone1_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone1_state}" == *'mDataRegState=1(OUT_OF_SERVICE)'* && \
              "${phone1_state}" == *'getRilVoiceRadioTechnology=3(UMTS)'* && \
              "${phone1_state}" == *'getRilDataRadioTechnology=0(Unknown)'* && \
              "${phone1_state}" == *'mIsEmergencyOnly=false'* ]] && \
           cs_wwan_registration_is "${phone1_state}" ROAMING; then
            ok "slot 1 CU voice registered while roaming"
        else
            no "slot 1 CU is not stock-equivalent: ${phone1_state:-<unreadable>}"
        fi
        ;;
    lebara-slot0)
        [[ "${sim_state}" == LOADED,ABSENT ]] && ok "Lebara control SIM loaded in slot 0" \
            || no "gsm.sim.state=${sim_state:-<unset>} (expected LOADED,ABSENT)"
        [[ "${sim_operator}" == 20408 ]] && ok "SIM layout: Lebara 20408 slot 0" \
            || no "gsm.sim.operator.numeric=${sim_operator:-<unset>} (expected 20408)"
        if [[ "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* ]] && \
           cs_wwan_registration_is "${phone0_state}" HOME; then
            ok "slot 0 Lebara voice/data registered at home"
        else
            no "slot 0 Lebara is not stock-equivalent: ${phone0_state:-<unreadable>}"
        fi
        ;;
    vdf-nl-slot0)
        [[ "${sim_state}" == LOADED,LOADED ]] && ok "both fixture SIMs loaded" \
            || no "gsm.sim.state=${sim_state:-<unset>} (expected LOADED,LOADED)"
        [[ "${sim_operator}" == 20404,46000 ]] \
            && ok "SIM layout: Vodafone NL slot 0, CMCC slot 1" \
            || no "gsm.sim.operator.numeric=${sim_operator:-<unset>} (expected 20404,46000)"
        [[ "${operator_roaming}" == false,true ]] \
            && ok "slot 0 home, slot 1 roaming" \
            || no "gsm.operator.isroaming=${operator_roaming:-<unset>} (expected false,true)"
        [[ "${operator_numeric}" == 20404,20408 ]] \
            && ok "visited operators: Vodafone NL 20404, KPN 20408" \
            || no "gsm.operator.numeric=${operator_numeric:-<unset>} (expected 20404,20408)"
        if [[ "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'getRilVoiceRadioTechnology=14(LTE)'* && \
              "${phone0_state}" == *'getRilDataRadioTechnology=14(LTE)'* && \
              "${phone0_state}" == *'mIsEmergencyOnly=false'* ]] && \
           cs_wwan_registration_is "${phone0_state}" HOME; then
            ok "slot 0 Vodafone NL voice/data registered at home on LTE"
        else
            no "slot 0 Vodafone NL is not as expected: ${phone0_state:-<unreadable>}"
        fi
        if [[ "${phone1_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone1_state}" == *'mDataRegState=1(OUT_OF_SERVICE)'* && \
              "${phone1_state}" == *'getRilVoiceRadioTechnology=16(GSM)'* && \
              "${phone1_state}" == *'getRilDataRadioTechnology=0(Unknown)'* && \
              "${phone1_state}" == *'mIsEmergencyOnly=false'* ]] && \
           cs_wwan_registration_is "${phone1_state}" ROAMING; then
            ok "slot 1 CMCC voice registered while roaming on GSM"
        else
            no "slot 1 CMCC is not as expected: ${phone1_state:-<unreadable>}"
        fi
        ;;
    cu-slot0-cmcc-slot1)
        [[ "${sim_state}" == LOADED,LOADED ]] && ok "both current fixture SIMs loaded" \
            || no "gsm.sim.state=${sim_state:-<unset>} (expected LOADED,LOADED)"
        [[ "${sim_operator}" == 46001,46000 ]] \
            && ok "SIM layout: China Unicom slot 0, China Mobile slot 1" \
            || no "gsm.sim.operator.numeric=${sim_operator:-<unset>} (expected 46001,46000)"
        [[ "${operator_roaming}" == true,true ]] \
            && ok "both current fixture SIMs roaming" \
            || no "gsm.operator.isroaming=${operator_roaming:-<unset>} (expected true,true)"
        [[ "${operator_numeric}" == 20404,20408 ]] \
            && ok "visited operators: Vodafone NL 20404, KPN 20408" \
            || no "gsm.operator.numeric=${operator_numeric:-<unset>} (expected 20404,20408)"
        if [[ "${phone0_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'mDataRegState=0(IN_SERVICE)'* && \
              "${phone0_state}" == *'getRilVoiceRadioTechnology=14(LTE)'* && \
              "${phone0_state}" == *'getRilDataRadioTechnology=14(LTE)'* && \
              "${phone0_state}" == *'mIsEmergencyOnly=false'* ]] && \
           cs_wwan_registration_is "${phone0_state}" ROAMING; then
            ok "slot 0 China Unicom voice/data registered while roaming on LTE"
        else
            no "slot 0 China Unicom is not as expected: ${phone0_state:-<unreadable>}"
        fi
        if [[ "${phone1_state}" == *'mVoiceRegState=0(IN_SERVICE)'* && \
              "${phone1_state}" == *'mDataRegState=1(OUT_OF_SERVICE)'* && \
              "${phone1_state}" == *'getRilVoiceRadioTechnology=16(GSM)'* && \
              "${phone1_state}" == *'getRilDataRadioTechnology=0(Unknown)'* && \
              "${phone1_state}" == *'mIsEmergencyOnly=false'* ]] && \
           cs_wwan_registration_is "${phone1_state}" ROAMING; then
            ok "slot 1 China Mobile voice registered while roaming on GSM"
        else
            no "slot 1 China Mobile is not as expected: ${phone1_state:-<unreadable>}"
        fi
        ;;
    # Same hole as radio_control_ready(): an unmatched `case` returns 0, so a
    # new profile name would have reached the summary having made ZERO radio
    # assertions and still counted as a clean run. Fail loudly and name it.
    *)
        no "radio profile ${RADIO_PROFILE} has no assertions in this verifier -- add them before trusting a run under it"
        ;;
esac
for pair in \
    persist.vendor.radio.mtk_dsbp_support=1 \
    persist.vendor.radio.mtk_ps2_rat=W/G; do
    prop="${pair%%=*}"; expected="${pair#*=}"; actual="$(sh_ getprop "${prop}")"
    [[ "${actual}" == "${expected}" ]] && ok "${prop}=${actual}" \
        || no "${prop}=${actual:-<unset>} (expected ${expected})"
done
vsim_sockets="$(sh_ 'grep -Ec "^[[:space:]]+socket rild-vsim(2|3)? stream 660 root radio$" /vendor/etc/init/mtkrild.rc')"
[[ "${vsim_sockets}" == 3 ]] && ok "RIL internal VSIM-named socket ABI intact" \
    || no "installed mtkrild.rc has ${vsim_sockets:-?}/3 internal VSIM-named sockets"

printf '\n== gapps ==\n'
# MindTheGapps 10.0.0 arm64. The list is every package the payload installs;
# it is derived from vendor/gapps/payload.sha256, not curated.
for p in com.google.android.gms com.android.vending com.google.android.gsf \
         com.google.android.setupwizard com.google.android.googlequicksearchbox \
         com.google.android.partnersetup com.google.android.feedback \
         com.google.android.apps.pixelmigrate com.google.android.markup \
         com.google.android.syncadapters.calendar \
         com.google.android.syncadapters.contacts \
         com.android.inputmethod.latin; do
    if [[ "${packages_read}" != true ]]; then
        skip "${p}"
    elif has "^package:${p}$" "${packages}"; then ok "${p}"; else no "${p}"; fi
done
# MindTheGapps deliberately ships no Google replacements for the AOSP and
# Lineage applications. If any of these appears it came from Play, not from the
# image, and the framework redirects that a system copy would need are gone.
for p in com.google.android.inputmethod.latin com.google.android.dialer \
         com.google.android.contacts com.google.android.apps.messaging \
         com.google.android.apps.photos com.google.android.gm.exchange; do
    if [[ "${system_packages_read}" != true ]]; then
        skip "${p} not a system package"
    elif has "^package:${p}$" "${system_packages}"; then
        no "${p} is installed as a SYSTEM package; MindTheGapps ships none"
    else
        ok "${p} not a system package"
    fi
done

device_provisioned="$(sh_ 'settings get global device_provisioned')"
user_setup_complete="$(sh_ 'settings get secure user_setup_complete')"
setup_state_record="$({
    printf 'device_provisioned=%s\n' "${device_provisioned:-<unreadable>}"
    printf 'user_setup_complete=%s\n' "${user_setup_complete:-<unreadable>}"
})"
must_write_text "${CAPTURE_DIR}/setup-state.txt" "${setup_state_record}" || true
post_setup_ready=false
if [[ "${device_provisioned}" == 1 && "${user_setup_complete}" == 1 ]]; then
    post_setup_ready=true
    ok "LineageSetupWizard completed"
else
    skip "post-setup role/IME/app acceptance; complete LineageSetupWizard and rerun (${device_provisioned:-?}/${user_setup_complete:-?})"
fi

# Capture removal checks on both the first boot and the ordinary reboot run.
# HOME must follow the unmodified Q policy after SetupWizard has completed.
launcher_policy_args=(runtime --adb "${ADB_BIN}" --serial "${SERIAL}")
if [[ "${post_setup_ready}" == true ]]; then
    launcher_policy_args+=(--post-setup)
fi
if launcher_policy_report="$(python3 "${TOOL_DIR}/check-launcher-policy.py" \
        "${launcher_policy_args[@]}" 2>&1)"; then
    ok "Niagara package, declared permissions, configuration and components are absent"
    if [[ "${post_setup_ready}" == true ]]; then
        ok "post-setup HOME role and resolver select Trebuchet"
    fi
else
    no "launcher removal/HOME check failed; see launcher-policy.json"
fi
must_write_text "${CAPTURE_DIR}/launcher-policy.json" "${launcher_policy_report}" || true

# The system dialer stays AOSP's: MindTheGapps ships no Google Dialer, so
# config_defaultDialer is left at frameworks/base's own com.android.dialer and
# nothing in this tree redirects it.
if [[ "${post_setup_ready}" == true ]]; then
    default_dialer="$(sh_ 'dumpsys telecom 2>/dev/null' \
        | awk '/mDefaultDialerCache:/{seen=1; next} seen && /^[[:space:]]*User 0:/ {sub(/^[[:space:]]*User 0:[[:space:]]*/, ""); print; exit}')"
    must_write_text "${CAPTURE_DIR}/default-dialer-probes.txt" \
        "default_dialer=${default_dialer:-<unreadable>}" || true
    if [[ "${default_dialer}" == com.android.dialer ]]; then
        ok "default dialer: ${default_dialer}"
    elif [[ -n "${default_dialer}" ]]; then
        no "default dialer is ${default_dialer} (expected com.android.dialer)"
    else
        skip "default dialer role was unreadable"
    fi
fi

webview_state="$(sh_ 'dumpsys webviewupdate 2>/dev/null')"
if has 'Current WebView package.*com.google.android.webview' "${webview_state}"; then
    ok "WebView provider: com.google.android.webview"
else
    no "Google WebView is not the current provider"
fi

# AOSP LatinIME is the only system IME. MindTheGapps ships no GBoard; it ships
# libjni_latinimegoogle.so, which is what gives AOSP LatinIME gesture typing.
expected_aosp_ime='com.android.inputmethod.latin/.LatinIME'
default_ime="$(sh_ 'settings get secure default_input_method')"
all_imes="$(sh_ 'ime list -a -s')"
enabled_imes="$(sh_ 'ime list -s')"
if [[ "${post_setup_ready}" == true ]]; then
    [[ "${default_ime}" == "${expected_aosp_ime}" ]] \
        && ok "default IME: exact AOSP LatinIME service" \
        || no "default IME: ${default_ime:-<unset>} (expected ${expected_aosp_ime})"
fi
if has_line "${expected_aosp_ime}" "${all_imes}"; then
    ok "AOSP LatinIME registered"
    if has_line "${expected_aosp_ime}" "${enabled_imes}"; then
        ok "AOSP LatinIME enabled"
    else
        no "AOSP LatinIME is installed but not enabled"
    fi
else
    no "exact AOSP LatinIME service is absent"
fi
for lib in /system/lib/libjni_latinimegoogle.so /system/lib64/libjni_latinimegoogle.so; do
    if [[ "$(sh_ "test -f ${lib} && echo yes")" == yes ]]; then
        ok "${lib}"
    else
        no "${lib} missing (AOSP LatinIME loses gesture typing)"
    fi
done
ime_state_record="$({
    printf 'default_input_method=%s\n' "${default_ime:-<unreadable>}"
    printf 'registered_input_methods_begin\n%s\nregistered_input_methods_end\n' \
        "${all_imes:-<unreadable>}"
    printf 'enabled_input_methods_begin\n%s\nenabled_input_methods_end\n' \
        "${enabled_imes:-<unreadable>}"
})"
must_append_text "${CAPTURE_DIR}/setup-state.txt" "${ime_state_record}" || true

if [[ "${post_setup_ready}" == true ]]; then
    sh_ 'input keyevent 224; input keyevent 82' >/dev/null 2>&1
    launch_package com.android.settings Settings
    launch_package com.android.vending PlayStore
    launch_package com.android.deskclock Clock
    launch_package org.lineageos.etar Calendar
fi

if ! refresh_combined_logs; then
    skip "post-launch logcat coverage"
fi
privapp_viol="$(printf '%s\n' "${combined_logs}" \
    | grep -cE 'not-in-privapp-permissions|Privileged permission.*not in privapp-permissions')"
if [[ -z "${combined_logs}" ]]; then
    skip "privileged-permission allowlist violations"
elif [[ "${privapp_viol}" == 0 ]]; then
    ok "no privileged-permission allowlist violations"
elif [[ -n "${privapp_viol}" ]]; then
    no "${privapp_viol} privileged-permission allowlist violation(s)"
else
    skip "privileged-permission allowlist violations"
fi

printf '\n== power: the boost path must actually be reachable ==\n'
# Session 3: the MTK PowerHAL control nodes were root:root while the HAL runs as
# system, so no scenario in powerscntbl.xml could ever be applied, and the table
# itself asked for another SKU's OPPs. Both halves are checked here.
for n in /proc/ppm/mode /proc/ppm/policy/userlimit_min_cpu_freq \
         /proc/ppm/policy/userlimit_min_cpu_core /proc/perfmgr/perf_ioctl \
         /proc/perfmgr/legacy/perfserv_freq /proc/hps/up_threshold; do
    owner="$(sh_ "stat -c '%U:%G %a' ${n}")"
    case "${owner}" in
        system:system*) ok "${n} ${owner}" ;;
        '')             no "${n} missing" ;;
        *)              no "${n} is ${owner}, expected system:system (the HAL runs as system)" ;;
    esac
done
# Every frequency the shipped table names must exist in the real DVFS tables.
c0="$(sh_ 'cat /proc/ppm/dump_cluster_0_dvfs_table')"
c1="$(sh_ 'cat /proc/ppm/dump_cluster_1_dvfs_table')"
note "cluster0 OPPs: ${c0}"
note "cluster1 OPPs: ${c1}"
powerscntbl="$(sh_ cat /vendor/etc/powerscntbl.xml)"
expected_c0="$(printf '%s\n' "${powerscntbl}" \
    | grep -o 'PERF_RES_CPUFREQ_[A-Z]*_CLUSTER_0" param1="[0-9]*' \
    | grep -o '[0-9]*$' | sort -u)"
expected_c1="$(printf '%s\n' "${powerscntbl}" \
    | grep -o 'PERF_RES_CPUFREQ_[A-Z]*_CLUSTER_1" param1="[0-9]*' \
    | grep -o '[0-9]*$' | sort -u)"
if [[ -z "${c0}" || -z "${c1}" || -z "${powerscntbl}" || \
      -z "${expected_c0}" || -z "${expected_c1}" ]]; then
    skip "powerscntbl/DVFS frequency coverage"
else
    bad=0
    while IFS= read -r f; do
        has " ${f} " " ${c0} " || {
            no "powerscntbl cluster0 asks for ${f}, not an OPP on this part"
            bad=1
        }
    done <<<"${expected_c0}"
    while IFS= read -r f; do
        has " ${f} " " ${c1} " || {
            no "powerscntbl cluster1 asks for ${f}, not an OPP on this part"
            bad=1
        }
    done <<<"${expected_c1}"
    [[ "${bad}" -eq 0 ]] && ok "every powerscntbl frequency exists in the DVFS tables"
fi
gov="$(sh_ 'cat /sys/devices/system/cpu/cpufreq/interactive/go_hispeed_load')"
[[ "${gov}" == 85 ]] && ok "interactive go_hispeed_load=85" || no "go_hispeed_load=${gov:-<none>}, expected 85"
iob="$(sh_ 'cat /sys/devices/system/cpu/cpufreq/interactive/io_is_busy')"
[[ "${iob}" == 1 ]] && ok "interactive io_is_busy=1" || no "io_is_busy=${iob:-<none>}, expected 1"
sched="$(sh_ 'cat /sys/block/mmcblk0/queue/scheduler')"
has '\[deadline\]' "${sched}" && ok "mmcblk0 scheduler ${sched}" || no "mmcblk0 scheduler ${sched}, expected deadline"
ra="$(sh_ 'cat /sys/block/mmcblk0/queue/read_ahead_kb')"
[[ "${ra}" == 128 ]] && ok "read_ahead_kb restored to 128 after boot" || no "read_ahead_kb=${ra}, expected 128 (2048 is the boot-time value; it must be put back)"
# WAS BROKEN twice over. `case "${ul}" in *-1*)` is a substring test across the
# WHOLE file, so on a two-cluster part one released cluster passed the check for
# both -- and the other arm was note(), which increments the informational
# counter, so a CPU still pinned at its boot-time floor could not fail the run
# no matter what the file said. Every cluster value is extracted and every one
# of them must be the -1 no-limit sentinel.
probe_remote 'cat /proc/ppm/policy/userlimit_min_cpu_freq'
if [[ -z "${PROBE_RC}" ]]; then
    skip "boot-time CPU pin released"
else
    # Two shapes are accepted: the "cluster N: min_freq = V KHz" line the PPM
    # policy nodes print, and a bare whitespace-separated value per cluster.
    cpu_pin_values="$(awk '
        {
            if (match($0, /[Mm]in_freq[[:space:]]*=[[:space:]]*-?[0-9]+/)) {
                token = substr($0, RSTART, RLENGTH)
                sub(/.*=[[:space:]]*/, "", token)
                print token
                next
            }
            for (i = 1; i <= NF; i++)
                if ($i ~ /^-?[0-9]+$/) print $i
        }' <<<"${PROBE_OUT}")"
    cpu_pin_clusters="$(grep -c . <<<"${cpu_pin_values}")"
    cpu_pin_pinned="$(grep -vFxc -- -1 <<<"${cpu_pin_values}" || true)"
    if [[ "${cpu_pin_clusters}" -lt 1 ]]; then
        no "userlimit_min_cpu_freq holds no cluster value this check can read: ${PROBE_OUT//$'\n'/ }"
    elif [[ "${cpu_pin_pinned}" -eq 0 ]]; then
        ok "boot-time CPU pin released on all ${cpu_pin_clusters} cluster(s)"
    else
        no "userlimit_min_cpu_freq still pins ${cpu_pin_pinned} of ${cpu_pin_clusters} cluster(s): ${PROBE_OUT//$'\n'/ }"
    fi
fi

printf '\n== media: hardware codec must not be seccomp-killed ==\n'
# Session 3: media.codec was SIGSYS-killed on every hardware codec session
# because no vendor seccomp policy was installed.
if [[ -n "$(sh_ 'ls /vendor/etc/seccomp_policy/mediacodec.policy 2>/dev/null')" ]]; then
    ok "/vendor/etc/seccomp_policy/mediacodec.policy installed"
else
    no "/vendor/etc/seccomp_policy/mediacodec.policy MISSING -- every hw codec will SIGSYS"
fi
smi="$(sh_ "stat -c '%U:%G %a' /dev/MTK_SMI")"
note "/dev/MTK_SMI ${smi} (the OMX service needs the 'media' supplementary group)"
# screenrecord captures the display, so with the panel blanked it produces a
# single frame or nothing at all and the check reads as a codec failure. Wake the
# handset first. Store media under Movies so MediaProvider can inspect it
# without a diagnostic-only shell_data_file denial.
sh_ 'input keyevent 224; input keyevent 82' >/dev/null 2>&1
sh_ 'mkdir -p /sdcard/Movies'
read_tombstone_manifest() {
    sh_ '
        if [ ! -d /data/tombstones ]; then
            printf "__K50_TOMBSTONE_RC__=2\n"
            exit
        fi
        manifest=""
        rc=0
        for file in /data/tombstones/*; do
            [ -f "$file" ] || continue
            line="$(sha256sum "$file")" || { rc=1; break; }
            manifest="${manifest}${line}\n"
        done
        printf "__K50_TOMBSTONE_RC__=%s\n" "$rc"
        printf "%b" "$manifest"
    '
}
tomb_before_probe="$(read_tombstone_manifest)"
tomb_before_rc="$(printf '%s\n' "${tomb_before_probe}" \
    | sed -n 's/^__K50_TOMBSTONE_RC__=//p')"
tomb_before="$(printf '%s\n' "${tomb_before_probe}" \
    | sed '/^__K50_TOMBSTONE_RC__=/d')"
codec_token="${BASHPID}_${RANDOM}_${RANDOM}"
codec_begin_marker="K50_SCREENRECORD_BEGIN_${codec_token}"
codec_end_marker="K50_SCREENRECORD_END_${codec_token}"
timeout 10s "${ADB_BIN}" -s "${SERIAL}" shell log -t K50Verifier \
    "${codec_begin_marker}" >/dev/null 2>&1
codec_begin_write_rc=$?
record_remote_active=true
record_probe="$(sh_ "screenrecord --time-limit 3 --size 320x640 ${record_remote_file} >/dev/null 2>&1; rc=\$?; printf '__K50_SCREENRECORD_RC__=%s\n' \"\$rc\"; stat -c %s ${record_remote_file} 2>/dev/null")"
timeout 10s "${ADB_BIN}" -s "${SERIAL}" shell log -t K50Verifier \
    "${codec_end_marker}" >/dev/null 2>&1
codec_end_write_rc=$?
codec_current_log="$(timeout "${ADB_COMMAND_SECONDS}s" "${ADB_BIN}" \
    -s "${SERIAL}" logcat -d "${LOGCAT_BUFFER_ARGS[@]}" \
    -v monotonic 2>/dev/null)"
codec_current_log_rc=$?
if [[ "${codec_current_log_rc}" -ne 0 ]]; then
    codec_current_log=""
fi
record_rc="$(printf '%s\n' "${record_probe}" \
    | sed -n 's/^__K50_SCREENRECORD_RC__=//p')"
record_size="$(printf '%s\n' "${record_probe}" \
    | sed '/^__K50_SCREENRECORD_RC__=/d')"
record_temp_file="$(mktemp --suffix=.mp4 /tmp/k50-screenrecord.XXXXXX)"
pull_output="$(adb pull "${record_remote_file}" "${record_temp_file}" 2>&1)"
pull_rc=$?
if timeout 10s "${ADB_BIN}" -s "${SERIAL}" shell \
        rm -f "${record_remote_file}" >/dev/null 2>&1; then
    record_remote_active=false
else
    no "remote screenrecord temporary file cleanup"
fi
sleep 2
tomb_after_probe="$(read_tombstone_manifest)"
tomb_after_rc="$(printf '%s\n' "${tomb_after_probe}" \
    | sed -n 's/^__K50_TOMBSTONE_RC__=//p')"
tomb_after="$(printf '%s\n' "${tomb_after_probe}" \
    | sed '/^__K50_TOMBSTONE_RC__=/d')"
tombstone_record="$({
    printf 'before_rc=%s\n%s\n' "${tomb_before_rc:-<unreadable>}" "${tomb_before}"
    printf 'after_rc=%s\n%s\n' "${tomb_after_rc:-<unreadable>}" "${tomb_after}"
})"
must_write_text "${CAPTURE_DIR}/screenrecord-tombstones.txt" \
    "${tombstone_record}" || true

ffprobe_output=""
record_hash=""
if [[ "${pull_rc}" -eq 0 && -s "${record_temp_file}" ]]; then
    record_hash="$(sha256sum "${record_temp_file}" | awk '{print $1}')"
    ffprobe_output="$("${FFPROBE_BIN}" -v error -select_streams v:0 \
        -show_entries stream=codec_name,width,height \
        -of default=noprint_wrappers=1 "${record_temp_file}" 2>&1)"
fi
screenrecord_metadata="$({
    printf 'screenrecord_rc=%s\n' "${record_rc:-<unreadable>}"
    printf 'remote_size=%s\n' "${record_size:-<unreadable>}"
    printf 'pull_rc=%s\n' "${pull_rc}"
    printf 'sha256=%s\n' "${record_hash:-<unreadable>}"
    printf '%s\n' "${ffprobe_output}"
})"
must_write_text "${CAPTURE_DIR}/screenrecord-metadata.txt" \
    "${screenrecord_metadata}" || true
codec_log_range=""
codec_window_readable=false
codec_window_reason="marker-write-or-logcat-failure"
codec_begin_count=0
codec_end_count=0
if [[ "${codec_current_log_rc}" -eq 0 ]]; then
    codec_begin_count="$(grep -Fc "${codec_begin_marker}" <<<"${codec_current_log}")"
    codec_end_count="$(grep -Fc "${codec_end_marker}" <<<"${codec_current_log}")"
fi
if [[ "${codec_begin_write_rc}" -ne 0 ]]; then
    codec_window_reason="begin-marker-write-rc-${codec_begin_write_rc}"
elif [[ "${codec_end_write_rc}" -ne 0 ]]; then
    codec_window_reason="end-marker-write-rc-${codec_end_write_rc}"
elif [[ "${codec_current_log_rc}" -ne 0 ]]; then
    codec_window_reason="logcat-read-rc-${codec_current_log_rc}"
elif [[ "${codec_begin_count}" -ne 1 || "${codec_end_count}" -ne 1 ]]; then
    codec_window_reason="ambiguous-marker-count"
else
    codec_marker_order="$(LC_ALL=C awk -v begin="${codec_begin_marker}" \
        -v end="${codec_end_marker}" '
        index($0, begin) { begun=1; next }
        begun && index($0, end) { print "complete"; exit }
        ' <<<"${codec_current_log}")"
    if [[ "${codec_marker_order}" == complete ]]; then
        codec_log_range="$(LC_ALL=C awk -v begin="${codec_begin_marker}" \
            -v end="${codec_end_marker}" '
            index($0, begin) { begun=1; next }
            begun && index($0, end) { exit }
            begun { print }
        ' <<<"${codec_current_log}")"
        codec_window_readable=true
        codec_window_reason="complete"
    else
        codec_window_reason="markers-out-of-order"
    fi
fi
screenrecord_hardware_log="$({
    printf 'begin_marker=%s\n' "${codec_begin_marker}"
    printf 'end_marker=%s\n' "${codec_end_marker}"
    printf 'begin_write_rc=%s\n' "${codec_begin_write_rc}"
    printf 'end_write_rc=%s\n' "${codec_end_write_rc}"
    printf 'logcat_rc=%s\n' "${codec_current_log_rc}"
    printf 'begin_count=%s\n' "${codec_begin_count}"
    printf 'end_count=%s\n' "${codec_end_count}"
    printf 'window_reason=%s\n' "${codec_window_reason}"
    printf 'window_readable=%s\n' "${codec_window_readable}"
    printf '%s\n' "${codec_log_range}" \
        | grep -E 'OMX[.]MTK[.]VIDEO[.]ENCODER[.]AVC|setupVideoEncoder succeeded|AVC EncTime' \
        || true
})"
must_write_text "${CAPTURE_DIR}/screenrecord-hardware-log.txt" \
    "${screenrecord_hardware_log}" || true

codec_log_ok=false
if printf '%s\n' "${codec_log_range}" \
       | grep -q 'OMX[.]MTK[.]VIDEO[.]ENCODER[.]AVC' && \
   printf '%s\n' "${codec_log_range}" \
       | grep -q 'setupVideoEncoder succeeded' && \
   printf '%s\n' "${codec_log_range}" | grep -q 'AVC EncTime'; then
    codec_log_ok=true
fi
if [[ "${record_rc}" != 0 ]]; then
    no "screenrecord exited ${record_rc:-<unreadable>}"
elif [[ "${pull_rc}" -ne 0 || ! -s "${record_temp_file}" ]]; then
    no "screenrecord pull failed: ${pull_output:-<no output>}"
elif [[ "${ffprobe_output}" != *'codec_name=h264'* || \
        "${ffprobe_output}" != *'width=320'* || \
        "${ffprobe_output}" != *'height=640'* ]]; then
    no "screenrecord stream is not H.264 320x640: ${ffprobe_output:-<unreadable>}"
elif [[ "${codec_window_readable}" != true ]]; then
    skip "marker-bounded screenrecord codec log window (${codec_window_reason})"
elif [[ "${codec_log_ok}" != true ]]; then
    no "screenrecord lacks MTK AVC setup/frame evidence in its log window"
else
    ok "hardware AVC encode: ${record_size} bytes, H.264 320x640, MTK frames"
fi
if [[ "${tomb_before_rc}" != 0 || "${tomb_after_rc}" != 0 ]]; then
    skip "screenrecord tombstone hash delta"
elif [[ "${tomb_before}" != "${tomb_after}" ]]; then
    no "screenrecord changed the tombstone hash manifest"
else
    ok "screenrecord created no new or changed tombstone"
fi
if [[ -f "${record_temp_file}" && ! -L "${record_temp_file}" && \
      "${record_temp_file}" == /tmp/k50-screenrecord.*.mp4 ]]; then
    if unlink -- "${record_temp_file}"; then
        record_temp_file=""
    else
        no "host screenrecord temporary file cleanup"
    fi
fi

printf '\n== input: the keypad must survive suspend ==\n'
cs="$(sh_ 'cat /sys/bus/platform/drivers/mtk-kpd/kpd_call_state')"
# Expect 0, not 2. The =2 escape hatch existed only for the PREBUILT kernel,
# whose kpd_pdrv_suspend() cleared KP_EN; the source kernel keeps KP_EN on
# across suspend and re-reads the shadow key state on resume, so init no longer
# writes it (E-168, device tree d56a17d). A 2 here now means somebody restored
# a write that the driver this image ships does not need.
if   [[ -z "${cs}" ]];  then skip "kpd_call_state"
elif [[ "${cs}" == 0 ]]; then ok   "kpd_call_state=0 (source kernel keeps KP_EN; the =2 hatch is retired)"
else                          no   "kpd_call_state=${cs}, expected 0 -- the retired =2 write is back"; fi
kd="$(sh_ 'dmesg | grep -c "KEYPAD is disabled"')"
if   [[ -z "${kd}" ]];  then skip "'KEYPAD is disabled' count"
elif [[ "${kd}" == 0 ]]; then ok   "'KEYPAD is disabled' never logged"
else                          no   "'KEYPAD is disabled' logged ${kd} time(s) -- the fix did not take"; fi
note "suspend cycles so far: $(sh_ 'dmesg | grep -c "PM: suspend entry"') (0 is expected while USB is attached)"

printf '\n== drm ==\n'
for f in /vendor/lib/mediadrm/libwvdrmengine.so /vendor/lib64/mediadrm/libwvdrmengine.so; do
    [[ -n "$(sh_ "ls ${f} 2>/dev/null")" ]] && ok "${f}" || no "${f} missing"
done
note "widevine level: $(sh_ 'dumpsys media.drm 2>/dev/null | grep -i -m1 securityLevel')"

printf '\n== full android: Go mode is gone ==\n'
# An empty read used to be reported straight through as PASS ("unset"), so a
# shell round trip that came back with nothing -- the exact condition the five
# phantom failures after the first flash came from -- was indistinguishable
# from the Go-mode-is-gone outcome this gate exists to prove. Every other
# property gate in this file distinguishes <unset>; this one now does too. The
# sentinel proves the handset answered, and only then is "empty" the pass.
probe_remote 'getprop ro.config.low_ram'
if   [[ -z "${PROBE_RC}" ]];  then skip "ro.config.low_ram"
elif [[ -z "${PROBE_OUT}" ]]; then ok "ro.config.low_ram unset"
else no "ro.config.low_ram=${PROBE_OUT} -- Go mode is back"; fi
# Reuse the one snapshot. This block re-ran `pm list features` over adb, which
# contradicts the "Snapshot once" comment at the top of the check section and
# gave the two feature sections two different readings of one handset.
if [[ "${features_read}" != true ]]; then skip "feature set"; else
    has 'android.hardware.ram.low' "${features}" \
        && no "android.hardware.ram.low still declared" || ok "ram.low not declared"
    # The four notLowRam features SystemConfig drops under Go, and which coming
    # back is the whole user-visible point of removing it.
    for f in picture_in_picture managed_users voice_recognizers activities_on_secondary_displays; do
        has "android.software.${f}" "${features}" \
            && ok "feature ${f}" || no "feature ${f} missing -- low_ram still in effect somewhere"
    done
fi
# E-042: two products agreeing on `false` produced `false false` and shipped the
# 130 MB debug runtime. This is the one-line check that it did not come back.
if [[ -n "$(sh_ 'ls -d /system/apex/com.android.runtime.release 2>/dev/null')" ]]; then
    ok "ART runtime APEX: release"
elif [[ -n "$(sh_ 'ls -d /system/apex/com.android.runtime.debug 2>/dev/null')" ]]; then
    no "ART runtime APEX: DEBUG -- PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD resolved to something other than the literal 'false'"
else
    skip "ART runtime APEX"
fi

printf '\n== telephony: the VoLTE teardown loop must be gone ==\n'
# E-043. The failure signature is startListeningForCalls followed within
# milliseconds by stopListeningForCalls, repeating forever, because
# getSupplementaryServiceConfiguration() throws 801 on a null UT interface.
for jar in mediatek-common mediatek-ims-base mediatek-ims-common \
           mediatek-ims-extension-plugin mediatek-ims-legacy mediatek-telecom-common \
           mediatek-telephony-base mediatek-telephony-common; do
    [[ -n "$(sh_ "ls /system/framework/${jar}.jar 2>/dev/null")" ]] \
        && ok "${jar}.jar present" || no "${jar}.jar missing from the IMS closure"
done
addon="$(sh_ getprop ro.vendor.mtk_telephony_add_on_policy)"
[[ "${addon}" == "0" ]] && ok "mtk_telephony_add_on_policy=0" || no "mtk_telephony_add_on_policy=${addon:-<unset>} (must be 0)"
if ! refresh_combined_logs; then
    skip "IMS/radio logcat coverage"
fi
radio_logs="${combined_logs}"
ims_logs="${combined_logs}"
# All four of these gates read the SAME log snapshot, so the one question that
# decides whether any of them can run is whether that snapshot exists. It is
# asked once, first, using the idiom this file already uses correctly for the
# privileged-permission gate above.
#
# What was here instead: `ut801="$(... | grep -c ...)"` followed by
# `[[ -z "${ut801}" ]] && skip`. grep -c ALWAYS prints a number, so that guard
# and the trailing `else skip` were both unreachable, and when
# refresh_combined_logs failed just above, both counts came back 0 and both
# VoLTE-teardown gates reported PASS on no evidence at all -- the single
# strongest claim this section makes, made from an empty string.
if [[ -z "${combined_logs}" ]]; then
    skip "IMS extension/legacy factory selection"
    skip "IMS notifyReady"
    skip "stopListeningForCalls count"
    skip "rilproxy VSIM-channel retry count"
else
    # ExtensionFactory logs selection after construction, type validation and
    # assignment. makeImsCallPlugin instead belongs to later video-call utility
    # use and need not run at boot. Require the actual factory-selection logs.
    # A wrapped capture containing none of these factories cannot prove startup.
    if ! has 'ExtensionPluginFactory' "${ims_logs}" && \
       ! has 'LegacyComponentFactory' "${ims_logs}"; then
        skip "IMS extension/legacy factory selection (capture does not reach IMS startup)"
    elif has "ImsExtensionFactory: Use MTK's ExtensionPluginFactory" "${ims_logs}" && \
       has "Use Legacy's LegacyComponentFactory" "${ims_logs}" && \
       ! has 'Use default ExtensionPluginFactory' "${ims_logs}" && \
       ! has 'ExtensionPluginFactoryBase:' "${ims_logs}" && \
       ! has 'Use default LegacyComponentFactory' "${ims_logs}"; then
        ok "MTK IMS extension and legacy implementation factories loaded"
    else
        no "IMS extension/legacy factory selection is incomplete or fell back to a base"
    fi
    ut801="$(printf '%s\n' "${radio_logs}" | grep -c 'notifyReady exception')"
    if [[ "${ut801}" == 0 ]]; then ok "no ImsManager notifyReady exception"
    else no "${ut801} ImsManager notifyReady exception(s) -- the UT teardown loop is still running"; fi
    stops="$(printf '%s\n' "${radio_logs}" | grep -c stopListeningForCalls)"
    if [[ "${stops}" == 0 ]]; then ok "no stopListeningForCalls teardown"
    else no "stopListeningForCalls seen ${stops} time(s)"; fi
    vsim_retries="$(printf '%s\n' "${radio_logs}" \
        | grep -c 'connectSocket fail, try again name:rild-vsim' || true)"
    if [[ "${vsim_retries}" == 0 ]]; then
        ok "rilproxy has no VSIM-channel reconnect loop"
    else
        no "rilproxy retried its internal rild-vsim channel ${vsim_retries} time(s)"
    fi
fi

# A live binder and updateImsServiceConfig prove framework setup only. The
# Lebara stock control gives three stronger end-to-end signatures. The roaming
# Chinese control proves base radio/calls but is not known to provision IMS, so
# it leaves WI-029 open rather than manufacturing a failure.
# WAS BROKEN: the three strongest IMS signals in this file were selected by the
# NAME of the radio profile -- lebara-slot0 asserted them, every other profile
# fell through to a note(), and note() cannot fail. A profile name is an
# ARGUMENT, not a measurement, and the argument is now wrong: the SIM fixture
# changed (HANDOFF "State"), `dual-cn` describes a pair of cards that is not in
# this handset, and the branch that silently skipped every IMS assertion was
# therefore chosen by a stale string. Gate on what the radio reports instead.
# IMS runs only on phone 0 on this platform, and IMS provisioning can only be
# REQUIRED where phone 0 is on its own network, so the condition is "slot 0 is
# CS/WWAN registered HOME" -- read through cs_wwan_registration_is(), which
# already exists precisely because a bare registrationState= substring cannot
# say which (domain, transportType) record supplied it.
#
# These gates are live now, not aspirational: E-091 root-caused VoLTE on this
# handset and it registers (+CIREGU: 1,5) with the fix applied.
ims_gates_live=false
if [[ -n "${phone0_state}" ]] && cs_wwan_registration_is "${phone0_state}" HOME; then
    ims_gates_live=true
fi
if [[ -z "${radio_logs}" ]]; then
    # Same snapshot, same question. These three read only the ABSENCE of a
    # pattern, so with no logs at all they reported three hard failures against
    # a handset nobody had managed to read -- the opposite error to the two
    # gates above, and equally wrong per skip()'s definition at the top.
    skip "modem IMS registration: +CIREG registered"
    skip "framework IMS registration state"
    skip "MMTEL voice capability"
elif [[ "${ims_gates_live}" != true ]]; then
    # Deliberately skip() and not note(). A fixture on which IMS cannot be
    # demanded is a fixture on which nobody checked IMS, and this file's policy
    # is that an unread check is not a pass -- which is exactly what the old
    # note() violated. Put a HOME-registering card in slot 0 to make it run.
    note "slot 0 is not CS/WWAN registered HOME (${phone0_state:-<unreadable>}); IMS provisioning cannot be required on a visited network"
    skip "modem IMS registration: +CIREG registered"
    skip "framework IMS registration state"
    skip "MMTEL voice capability"
else
    if printf '%s\n' "${radio_logs}" | grep -Eq '\+CIREG(U)?: (1,5|2,1,5)'; then
        ok "modem IMS registration: +CIREG registered"
    else
        no "no registered +CIREG/+CIREGU state on a HOME-registered slot 0"
    fi
    has 'IMS registration state: true' "${radio_logs}" \
        && ok "framework IMS registration state=true" \
        || no "framework never reported IMS registration state=true"
    has 'MmTel Capabilities - \[Voice: true' "${radio_logs}" \
        && ok "MMTEL voice capability=true" \
        || no "MMTEL voice capability never became true"
fi

printf '\n== net: tethering must be offerable ==\n'
teth="$(sh_ 'dumpsys connectivity 2>/dev/null | grep -A4 tetherableUsbRegexs')"
if [[ -z "${teth}" ]]; then skip "tetherable regexs"; else
    for k in tetherableUsbRegexs tetherableWifiRegexs tetherableBluetoothRegexs; do
        v="$(printf '%s\n' "${teth}" | sed -n "s/.*${k}: \[\(.*\)\].*/\1/p")"
        [[ -n "${v}" ]] && ok "${k}: [${v}]" || no "${k} is empty -- Settings will hide the whole tethering screen"
    done
fi

printf '\n== storage: swap must come up exactly once ==\n'
# dmesg holds about 11 minutes on this device: the vendor drivers are chatty
# enough that the 512 KiB ring wraps long before an ordinary session ends. A
# boot-time failure that has rotated out is indistinguishable from one that
# never happened, so establish coverage BEFORE reading the absence as a pass.
# This is the same class of mistake as counting denials with a pattern that
# matches a subset -- a number that looks like evidence and is not.
swap_dmesg="$(printf '%s\n%s\n' "${early_dmesg}" "$(sh_ dmesg)" | sort -u)"
linux_banner_count="$(printf '%s\n' "${swap_dmesg}" | grep -c 'Linux version')"
if [[ "${linux_banner_count}" -gt 0 ]] 2>/dev/null; then
    swapfail="$(printf '%s\n' "${swap_dmesg}" \
        | grep -cE 'swapon failed|Cannot change disksize')"
    [[ "${swapfail:-1}" == 0 ]] && ok "no swapon failure (dmesg reaches boot)" \
        || no "${swapfail} swapon failure(s) -- swapon_all is running twice again"
else
    skip "swapon failure (dmesg has already wrapped past boot; re-run sooner after a flash)"
fi
swaps="$(sh_ cat /proc/swaps)"
if [[ -z "${swaps}" ]]; then
    skip "/proc/swaps"
elif printf '%s\n' "${swaps}" | grep -qE '(^|/)zram0[[:space:]]'; then
    ok "zram0 active"
else
    no "zram0 is absent from readable /proc/swaps"
fi

printf '\n== stability ==\n'
# CALIBRATE BEFORE YOU TRUST THIS. An earlier revision of this block failed on
# ro.boot.bootreason=HW_reboot, on the reasoning that HW_reboot means the
# hardware watchdog fired. On THIS bootloader it does not: a deliberate
# `adb reboot` from a healthy Android also comes back HW_reboot, measured twice.
# Every entry in persist.sys.boot.reason.history is either hw_reboot or the
# factory_reset written at flash time, so this MTK LK reports HW_reboot for any
# warm reboot and the value carries no information about health.
#
# That mattered. A review of this handset recorded "two spontaneous hardware
# watchdog resets during the session" on the strength of it, when the owner had
# rebooted deliberately after inserting a SIM. A check that fires on every boot
# is not a check, and a signal that cannot distinguish the thing it names is
# worse than no signal at all.
bootreason="$(sh_ 'getprop ro.boot.bootreason')"
case "${bootreason}" in
    kernel_panic|wdt|watchdog|*panic*)
        no "boot reason: ${bootreason} -- an unambiguous crash reason" ;;
    *)
        note "boot reason: ${bootreason:-<unset>} (HW_reboot is this bootloader's normal warm-reboot value, not a fault)" ;;
esac

# pstore describes the PRECEDING boot, not the running one. On the first
# ROM boot after flashing, the expected predecessor is whichever preflash ROM
# `adb reboot bootloader` ended (Stock for the original E-077 transition, or an
# older Lineage build for an update). It will normally differ from E-074, which
# is only the archived original Stock observation. Exact E-074 equality is
# therefore stale context, never the health oracle for the running ROM.
#
# Capture every file, require at least one console/dmesg record, reject known
# kernel-fault signatures, and otherwise require an explicit orderly reboot
# trail. A second verifier run after a deliberate Lineage reboot is what
# classifies the first Lineage boot (including this run's active
# media/screenrecord probe).
# Empty or console-free pstore means the diagnostic channel was lost; it is
# unread evidence, not proof of stability. pmsg remains capture-only because
# ordinary userspace logging legitimately changes it. The required phase
# argument makes the first run intentionally incomplete and makes the second
# run prove that pstore advanced beyond the first run's saved manifest.
pstore_probe="$(sh_ 'if [ ! -d /sys/fs/pstore ]; then printf "__K50_PSTORE_MISSING__\n"; else p="$(ls -1 /sys/fs/pstore 2>/dev/null)"; rc=$?; printf "__K50_PSTORE_RC__=%s\n" "$rc"; printf "%s\n" "$p"; fi')"
pstore_rc="$(printf '%s\n' "${pstore_probe}" \
    | sed -n 's/^__K50_PSTORE_RC__=//p')"
pstore="$(printf '%s\n' "${pstore_probe}" \
    | sed '/^__K50_PSTORE_RC__=/d; /^__K50_PSTORE_MISSING__$/d')"
if [[ "${pstore_rc}" != 0 ]]; then
    skip "/sys/fs/pstore listing"
elif [[ -z "${pstore}" ]]; then
    skip "/sys/fs/pstore console evidence (directory is empty)"
else
    pstore_capture="${CAPTURE_DIR}/pstore"
    mkdir -p -- "${pstore_capture}"
    pstore_read_error=false
    while IFS= read -r name; do
        [[ -z "${name}" ]] && continue
        if [[ ! "${name}" =~ ^[A-Za-z0-9._-]+$ ]] || \
           ! adb exec-out cat "/sys/fs/pstore/${name}" \
                >"${pstore_capture}/${name}"; then
            pstore_read_error=true
        fi
    done <<<"${pstore}"
    if [[ "${pstore_read_error}" == true ]]; then
        skip "complete pstore capture"
    else
        classification_output="$("${PSTORE_CLASSIFIER}" \
            "${pstore_capture}" "${PSTORE_PRETRANSITION_FILE}" 2>&1)"
        classification_rc=$?
        classification="$(printf '%s\n' "${classification_output}" \
            | sed -n 's/^classification=//p')"
        case "${classification}" in
            stale_pretransition_record)
                no "pstore is still the older E-074 record and did not advance across reboot bootloader" ;;
            orderly_controlled_predecessor_reboot)
                if [[ "${PSTORE_PHASE}" == lineage-predecessor ]] && \
                   cmp -s "${pstore_capture}/FAULT-SHA256SUMS" \
                       "${PRIOR_PSTORE_MANIFEST}"; then
                    no "pstore did not advance from the first verifier run to the Lineage predecessor"
                else
                    ok "pstore predecessor has one ordered reboot trail and no recognized fault signature"
                    if [[ "${PSTORE_PHASE}" == stock-predecessor || \
                          "${PSTORE_PHASE}" == preflash-predecessor ]]; then
                        skip "current ROM pstore proof pending one controlled reboot and lineage-predecessor rerun"
                    fi
                fi
                ;;
            kernel_fault_signature)
                no "pstore predecessor record contains a kernel-fault signature" ;;
            unclassified_predecessor_record)
                no "pstore predecessor changed but is neither an orderly reboot nor a classified fault"
                printf '        Read %s before attributing it to Stock or Lineage.\n' \
                    "${pstore_capture}/FAULT-SHA256SUMS" ;;
            console_evidence_unavailable)
                skip "pstore console/dmesg evidence (only non-console records exist)" ;;
            *)
                printf '        classifier output: %s\n' "${classification_output}"
                skip "pstore predecessor classification" ;;
        esac
        # This was `[[ "${classification_rc}" -gt 2 ]] && skip`, which cannot
        # fire: classify-pstore.sh's every exit path is 0, 1 or 2, so the
        # branch was dead and the exit contract it names was never checked at
        # all. Everything above keys off the classification STRING and ignores
        # the status, so a classifier that returned 0 next to
        # kernel_fault_signature would have been believed. Check the agreement
        # the dead branch was reaching for.
        case "${classification}" in
            orderly_controlled_predecessor_reboot) expected_classification_rc=0 ;;
            kernel_fault_signature | stale_pretransition_record | \
            unclassified_predecessor_record)       expected_classification_rc=1 ;;
            console_evidence_unavailable)          expected_classification_rc=2 ;;
            *)                                     expected_classification_rc="" ;;
        esac
        if [[ -n "${expected_classification_rc}" && \
              "${classification_rc}" != "${expected_classification_rc}" ]]; then
            no "pstore classifier broke its exit contract: ${classification} returned ${classification_rc}, not ${expected_classification_rc}"
        fi
        if [[ "${PSTORE_PHASE}" == stock-predecessor ]]; then
            note "stock-predecessor covers the final Stock boot and intentionally cannot complete current-ROM pstore proof"
        elif [[ "${PSTORE_PHASE}" == preflash-predecessor ]]; then
            note "preflash-predecessor covers the prior ROM and intentionally cannot complete current-ROM pstore proof"
        else
            note "lineage-predecessor phase requires a manifest advance and classifies the prior Lineage boot"
        fi
    fi
fi

evaluate_avcs() {
printf '\n== selinux denials ==\n'
# "avc: +denied", not "avc: denied". Two producers, two formats:
#   the kernel  -> type=1400 audit(...): avc: denied  { ... }      (one space)
#   init itself -> selinux: avc:  denied  { set } for property=... (two spaces,
#                                                    and no audit() prefix)
# A single-space literal matches only the first. That is not cosmetic: it hid
# every property_service denial this device produces -- seven unique tuples
# across gsm0710muxd, mtkmal, mtkrild, rild and hal_wifi_default, one of them
# on the VoLTE bring-up path -- from E-023, from the recorded tuple counts, and
# from this check, for two sessions. Read logcat too: the init-side lines reach
# the kernel ring buffer only via logd's auditd bridge and can rotate out of it
# sooner than they leave the log buffers.
# Count BOTH producers. An earlier revision counted dmesg only, which is the
# same subset mistake in a different place: servicemanager and hwservicemanager
# emit `avc:  denied  { find } for service=/interface=` into logcat and NEVER
# into the kernel ring buffer.
late_dmesg="$(sh_ dmesg)"
late_logcat="$(logcat_snapshot)"
must_write_text "${CAPTURE_DIR}/late-dmesg.txt" "${late_dmesg}" || true
must_write_text "${CAPTURE_DIR}/late-logcat-all.txt" "${late_logcat}" || true
getprop_snapshot="$(sh_ getprop)"
must_write_text "${CAPTURE_DIR}/getprop.txt" "${getprop_snapshot}" || true
must_write_text "${CAPTURE_DIR}/telephony-registry.txt" "${registry}" || true

# Close the followers before reading their files so the AVC gate covers the
# complete run, including the active UI/media probes above. EXIT cleanup is
# idempotent and remains armed for every earlier failure path.
logcat_reconnect_overlap="not-required"
if [[ "${logcat_any_reconnect}" == true ]]; then
    logcat_reconnect_overlap="verified"
    logcat_missing_buffers=""
    for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
        [[ "${logcat_stream_needs_reconnect[${logcat_buffer}]}" == true ]] \
            || continue
        logcat_stream_overlap["${logcat_buffer}"]="missing"
        logcat_offset="${logcat_stream_reconnect_offset[${logcat_buffer}]}"
        if [[ "${logcat_offset}" =~ ^[0-9]+$ ]]; then
            logcat_stream_replay_oldest["${logcat_buffer}"]="$(
                tail -c +$((logcat_offset + 1)) \
                    "${logcat_stream_file[${logcat_buffer}]}" 2>/dev/null \
                | LC_ALL=C awk '
                    $1 ~ /^[0-9]+[.][0-9]+$/ { print $1; exit }
                '
            )"
        else
            logcat_stream_replay_oldest["${logcat_buffer}"]="missing"
        fi
        if [[ "${logcat_offset}" =~ ^[0-9]+$ && \
              "${logcat_stream_pre_drop_last[${logcat_buffer}]}" \
                  =~ ^[0-9]+[.][0-9]+$ && \
              "${logcat_stream_replay_oldest[${logcat_buffer}]}" \
                  =~ ^[0-9]+[.][0-9]+$ ]] && \
           LC_ALL=C awk \
              -v oldest="${logcat_stream_replay_oldest[${logcat_buffer}]}" \
              -v last="${logcat_stream_pre_drop_last[${logcat_buffer}]}" \
              'BEGIN { exit !((oldest + 0) <= (last + 0)) }'; then
            logcat_stream_overlap["${logcat_buffer}"]="verified"
        else
            logcat_reconnect_overlap="missing"
            logcat_missing_buffers="${logcat_missing_buffers} ${logcat_buffer}"
        fi
    done
    if [[ "${logcat_reconnect_overlap}" == verified ]]; then
        note "every reconnected logcat ring overlaps its own pre-drop tail"
    else
        skip "continuous logcat reconnect overlap proof for: ${logcat_missing_buffers# }"
    fi
fi
dmesg_reconnect_overlap="not-required"
if [[ "${dmesg_needs_reconnect}" == true ]]; then
    dmesg_reconnect_overlap="missing"
    if [[ "${dmesg_reconnect_offset}" =~ ^[0-9]+$ && \
          -n "${dmesg_reconnect_anchor}" ]] && \
       tail -c +$((dmesg_reconnect_offset + 1)) \
            "${continuous_dmesg_file}" 2>/dev/null \
            | LC_ALL=C grep -aFqx -- "${dmesg_reconnect_anchor}"; then
        dmesg_reconnect_overlap="verified"
        note "continuous dmesg reconnect replay overlaps the pre-drop buffer"
    else
        skip "continuous dmesg reconnect overlap proof"
    fi
fi
reconnect_meta="$({
    printf 'logcat_reconnect=%s\n' "${logcat_any_reconnect}"
    printf 'logcat_reconnect_overlap=%s\n' "${logcat_reconnect_overlap}"
    for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
        printf 'logcat_%s_reconnect=%s\n' "${logcat_buffer}" \
            "${logcat_stream_needs_reconnect[${logcat_buffer}]}"
        printf 'logcat_%s_reconnect_offset=%s\n' "${logcat_buffer}" \
            "${logcat_stream_reconnect_offset[${logcat_buffer}]}"
        printf 'logcat_%s_pre_drop_last_monotonic=%s\n' "${logcat_buffer}" \
            "${logcat_stream_pre_drop_last[${logcat_buffer}]:-missing}"
        printf 'logcat_%s_replay_oldest_monotonic=%s\n' "${logcat_buffer}" \
            "${logcat_stream_replay_oldest[${logcat_buffer}]}"
        printf 'logcat_%s_reconnect_overlap=%s\n' "${logcat_buffer}" \
            "${logcat_stream_overlap[${logcat_buffer}]}"
    done
    printf 'dmesg_reconnect=%s\n' "${dmesg_needs_reconnect}"
    printf 'dmesg_reconnect_offset=%s\n' "${dmesg_reconnect_offset}"
    printf 'dmesg_reconnect_anchor_sha256=%s\n' \
        "${dmesg_reconnect_anchor_hash}"
    printf 'dmesg_reconnect_overlap=%s\n' "${dmesg_reconnect_overlap}"
})"
must_append_text "${CAPTURE_DIR}/META.txt" "${reconnect_meta}" || true
logcat_dead_buffers=""
logcat_empty_buffers=""
for logcat_buffer in "${LOGCAT_PROOF_BUFFERS[@]}"; do
    if ! kill -0 "${logcat_stream_pid[${logcat_buffer}]}" 2>/dev/null; then
        logcat_dead_buffers="${logcat_dead_buffers} ${logcat_buffer}"
    fi
    if [[ ! -s "${logcat_stream_file[${logcat_buffer}]}" ]]; then
        logcat_empty_buffers="${logcat_empty_buffers} ${logcat_buffer}"
    fi
done
if [[ -n "${logcat_dead_buffers}" ]]; then
    skip "continuous logcat rings survived through final probe: ${logcat_dead_buffers# }"
fi
if [[ -n "${logcat_empty_buffers}" ]]; then
    skip "nonempty continuous logcat rings: ${logcat_empty_buffers# }"
fi
if ! kill -0 "${dmesg_pid}" 2>/dev/null; then
    skip "continuous dmesg survived through final probe"
fi
cleanup_streams
continuous_dmesg_snapshot="$(cat "${continuous_dmesg_file}" 2>/dev/null)"
if [[ "${logcat_combine_ok}" != true ]]; then
    skip "combined continuous logcat artifact"
fi
continuous_logcat_snapshot="$(cat "${continuous_logcat_file}" 2>/dev/null)"
if [[ -z "${continuous_dmesg_snapshot}" || -z "${continuous_logcat_snapshot}" ]]; then
    skip "complete continuous AVC coverage"
fi
current_logcat_snapshot="${late_logcat}"
combined_logs="$({
    printf '%s\n' "${early_logcat}"
    printf '%s\n' "${continuous_logcat_snapshot}"
    printf '%s\n' "${late_logcat}"
} | sort -u)"

# --min-evidence-lines: the classifier's own floor below which it answers
# "unread" instead of "no unexpected denial". Measured against the capture this
# expected-tuple list is calibrated on (tier1-verify-20260824T153250Z): 461,583
# lines over these six files, the smallest of them 3,364. A thousand is two
# orders of magnitude under any real capture and far above a truncated one.
avc_output="$("${AVC_CLASSIFIER}" --min-evidence-lines 1000 \
    "${EXPECTED_AVC_FILE}" "${CAPTURE_DIR}" \
    "${CAPTURE_DIR}/early-dmesg.txt" \
    "${CAPTURE_DIR}/early-logcat-all.txt" \
    "${continuous_dmesg_file}" \
    "${continuous_logcat_file}" \
    "${CAPTURE_DIR}/late-dmesg.txt" \
    "${CAPTURE_DIR}/late-logcat-all.txt" 2>&1)"
avc_rc=$?
denial_count="$(sed -n 's/^denial_count=//p' <<<"${avc_output}")"
normalized_count="$(sed -n 's/^normalized_count=//p' <<<"${avc_output}")"
unparsed_count="$(sed -n 's/^unparsed_count=//p' <<<"${avc_output}")"
expected_avc="$(sed -n 's/^expected_count=//p' <<<"${avc_output}")"
unexpected_avc="$(sed -n 's/^unexpected_count=//p' <<<"${avc_output}")"
note "denial lines across continuous plus boundary dmesg/logcat: ${denial_count:-<unreadable>}"
while IFS=$'\t' read -r kind record; do
    case "${kind}" in
        expected)   note "expected AVC: ${record}" ;;
        unexpected) no "unexpected AVC: ${record}" ;;
    esac
done <<<"${avc_output}"
if [[ "${unparsed_count:-1}" -ne 0 ]] 2>/dev/null; then
    no "${unparsed_count:-<unreadable>} AVC line(s) could not be normalized"
fi
if [[ -n "${denial_count}" && -n "${normalized_count}" && \
      "${denial_count}" -ne "${normalized_count}" ]] 2>/dev/null; then
    no "normalized ${normalized_count} of ${denial_count} AVC line(s)"
fi
# WAS BROKEN: rc 0 from the classifier printed PASS even when it had seen ZERO
# denial records in any capture. On this device zero is not a clean policy, it
# is a failed capture: HANDOFF's not-a-defect list documents a NON-ZERO Tier-1
# baseline that fires on every boot -- system_app to apexd/installd/netd/
# wificond/storaged/system_suspend once a minute while Settings enumerates
# native services, the GMS fingerprinting probes, and hal_power_default's
# getattr on a caller's /proc/<pid>. If none of those appear, dmesg wrapped or
# the logcat/dmesg captures came back empty, and "no unexpected denial" is a
# statement about an empty file. Guard the PASS on having actually read some.
if [[ "${avc_rc}" -eq 0 && "${denial_count:-0}" -gt 0 ]] 2>/dev/null; then
    ok "no unexpected AVC record (${expected_avc:-0} qualified of ${denial_count} denial line(s))"
elif [[ "${avc_rc}" -eq 0 ]]; then
    skip "AVC classification: the classifier found ${denial_count:-<unreadable>} denial record(s) across every capture, and this device has a documented non-zero Tier-1 baseline, so the captures are empty rather than the policy clean"
elif [[ "${avc_rc}" -eq 3 ]]; then
    skip "AVC classification: ${avc_output:-<no output>}"
elif [[ "${avc_rc}" -gt 1 ]]; then
    no "AVC classifier failed: ${avc_output:-<no output>}"
elif [[ "${unexpected_avc:-0}" -eq 0 && \
        "${unparsed_count:-0}" -eq 0 ]] 2>/dev/null; then
    no "AVC classifier returned failure without an explained record"
fi
}

# --- session 6 ------------------------------------------------------------
# Each of these is something that was decided statically and can only be
# confirmed here. They check the OUTCOME, not the presence of the input: a file
# that installed but is not parsed is the failure mode this project keeps
# hitting, so where a runtime consequence exists, that is what is asserted.
printf '\n-- session 6 additions --\n'

# HarmonyOS Sans. The .ttf landing in /product/fonts proves nothing; what
# matters is whether SystemFonts parsed the family, which shows up as the
# overlay being installable and the family being resolvable.
check "HarmonyOS Sans installed" 'ls /product/fonts/HarmonyOSSans-Regular.ttf 2>/dev/null'
fam="$(sh_ 'grep -c "name=\"harmonyos\"" /product/etc/fonts_customization.xml')"
if [[ "${fam}" == 1 ]]; then ok "harmonyos family declared"; else no "harmonyos family NOT declared (fonts_customization.xml reverted by a repo sync?)"; fi
check "Styles font overlay present" 'cmd overlay list 2>/dev/null | grep -i harmonyos'

# APNs are a clean Lineage base plus four device-owned IMS rows. Bind the live
# file to the digest extracted from the staged system image, then verify the
# four carrier markers and the TelephonyProvider rows actually imported after
# the mandatory fresh-data flash. A row-count threshold cannot distinguish a
# correct merge from an arbitrary large replacement.
probe_remote 'sha256sum /product/etc/apns-conf.xml 2>/dev/null'
apn_file_hash_rc="${PROBE_RC}"
apn_file_hash_output="${PROBE_OUT}"
apn_file_hash="$(awk 'NR == 1 { print $1 }' <<<"${apn_file_hash_output}")"
if [[ -z "${apn_file_hash_rc}" ]]; then
    skip "installed APN digest"
elif [[ "${apn_file_hash_rc}" != 0 || \
        ! "${apn_file_hash}" =~ ^[0-9a-f]{64}$ ]]; then
    no "installed APN digest is unreadable or malformed (rc=${apn_file_hash_rc})"
elif [[ "${apn_file_hash}" == "${EXPECTED_PRODUCT_APNS_SHA}" ]]; then
    ok "installed APN digest matches staged merge: ${apn_file_hash}"
else
    no "installed APN digest ${apn_file_hash} differs from staged ${EXPECTED_PRODUCT_APNS_SHA}"
fi

# One row per MCC/MNC the CarrierConfig overlay advertises VoLTE for; the two
# lists move together (E-181). The MNC sits in the MIDDLE of each label because
# custom_apns.py matches carrier names as SUBSTRINGS, so "... IMS" and
# "... IMS 46002" would make the merge emit the longer row twice.
APN_CARRIERS=(
    'k50sv1: Vodafone NL IMS'
    'k50sv1: China Telecom MVNO IMS'
    'k50sv1: China Mobile 46000 IMS'
    'k50sv1: China Mobile 46002 IMS'
    'k50sv1: China Mobile 46004 IMS'
    'k50sv1: China Mobile 46007 IMS'
    'k50sv1: China Mobile 46008 IMS'
    'k50sv1: China Unicom 46001 IMS'
    'k50sv1: China Unicom 46006 IMS'
    'k50sv1: China Unicom 46009 IMS'
)
for apn_carrier in "${APN_CARRIERS[@]}"; do
    probe_remote "grep -F -c 'carrier=\"${apn_carrier}\"' /product/etc/apns-conf.xml 2>/dev/null"
    if [[ -z "${PROBE_RC}" ]]; then
        skip "APN marker ${apn_carrier}"
    elif [[ "${PROBE_RC}" == 0 && "${PROBE_OUT}" == 1 ]]; then
        ok "APN marker occurs exactly once: ${apn_carrier}"
    else
        no "APN marker count for ${apn_carrier}: ${PROBE_OUT:-<none>} (rc=${PROBE_RC})"
    fi
done

# Include every Android-Q CARRIERS_UNIQUE_FIELDS component, plus name/type and
# both transport masks. The source validator uses this same identity. Because
# the database enforces that identity without name or masks, a stale zero-mask
# row under another name would displace the expected marker and fail below.
apn_projection='name:numeric:mcc:mnc:apn:type:proxy:port:mmsproxy:mmsport:mmsc:carrier_enabled:bearer:mvno_type:mvno_match_data:profile_id:protocol:roaming_protocol:user_editable:owned_by:apn_set_id:carrier_id:network_type_bitmask:bearer_bitmask'
probe_remote "content query --uri content://telephony/carriers --projection ${apn_projection} --where \"name LIKE 'k50sv1:%'\" 2>/dev/null"
apn_db_rc="${PROBE_RC}"
apn_db_output="${PROBE_OUT}"
must_write_text "${CAPTURE_DIR}/apn-runtime-db.txt" "$({
    printf 'expected_product_apns_sha256=%s\n' "${EXPECTED_PRODUCT_APNS_SHA}"
    printf 'installed_product_apns_sha256=%s\n' "${apn_file_hash:-<unreadable>}"
    printf 'content_query_rc=%s\n' "${apn_db_rc:-<no-sentinel>}"
    printf '%s\n' "${apn_db_output}"
})" || true

# network_type_bitmask is 512903 and NOT 1048575: the old all-bearers mask named
# six CDMA technologies, and DcTracker.createDataProfile() derives the profile
# type from this field alone, so the IMS profile went to the modem as TYPE_3GPP2
# and mtkrild answered RIL_E_REQUEST_NOT_SUPPORTED every time (E-181).
# bearer_bitmask is the converted RIL-technology form of the same set.
APN_EXPECTED_DB_ROWS=(
    'name=k50sv1: Vodafone NL IMS, numeric=20404, mcc=204, mnc=04, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Telecom MVNO IMS, numeric=20404, mcc=204, mnc=04, apn=IMS, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=spn, mvno_match_data=中国电信, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Mobile 46000 IMS, numeric=46000, mcc=460, mnc=00, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Mobile 46002 IMS, numeric=46002, mcc=460, mnc=02, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Mobile 46004 IMS, numeric=46004, mcc=460, mnc=04, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Mobile 46007 IMS, numeric=46007, mcc=460, mnc=07, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Mobile 46008 IMS, numeric=46008, mcc=460, mnc=08, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Unicom 46001 IMS, numeric=46001, mcc=460, mnc=01, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Unicom 46006 IMS, numeric=46006, mcc=460, mnc=06, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
    'name=k50sv1: China Unicom 46009 IMS, numeric=46009, mcc=460, mnc=09, apn=ims, type=ims, proxy=, port=, mmsproxy=, mmsport=, mmsc=, carrier_enabled=1, bearer=0, mvno_type=, mvno_match_data=, profile_id=0, protocol=IPV4V6, roaming_protocol=IPV4V6, user_editable=1, owned_by=1, apn_set_id=0, carrier_id=-1, network_type_bitmask=512903, bearer_bitmask=517895'
)
if [[ -z "${apn_db_rc}" ]]; then
    skip "device-owned APN database rows"
elif [[ "${apn_db_rc}" != 0 ]]; then
    no "device-owned APN database query failed (rc=${apn_db_rc})"
else
    apn_db_row_count="$(grep -Ec '^Row: [0-9]+ ' <<<"${apn_db_output}")"
    if [[ "${apn_db_row_count}" == "${#APN_EXPECTED_DB_ROWS[@]}" ]]; then
        ok "TelephonyProvider contains exactly ${#APN_EXPECTED_DB_ROWS[@]} device-owned APN rows"
    else
        no "TelephonyProvider contains ${apn_db_row_count} device-owned APN rows; expected ${#APN_EXPECTED_DB_ROWS[@]}"
    fi
    for expected_apn_row in "${APN_EXPECTED_DB_ROWS[@]}"; do
        expected_apn_name="${expected_apn_row%%, numeric=*}"
        expected_apn_name="${expected_apn_name#name=}"
        exact_apn_rows="$(sed -n 's/^Row: [0-9][0-9]* //p' \
            <<<"${apn_db_output}" | grep -Fxc "${expected_apn_row}")"
        if [[ "${exact_apn_rows}" == 1 ]]; then
            ok "TelephonyProvider APN identity/masks/protocols: ${expected_apn_name}"
        else
            no "TelephonyProvider APN row differs or is duplicated: ${expected_apn_name}"
        fi
    done
    zero_mask_rows="$(grep -Ec \
        'network_type_bitmask=0|bearer_bitmask=0' <<<"${apn_db_output}")"
    if [[ "${zero_mask_rows}" == 0 ]]; then
        ok "no device-owned APN database identity retained a zero transport mask"
    else
        no "${zero_mask_rows} device-owned APN row(s) retained a zero transport mask"
    fi
fi

# Huawei apps remain Huawei-signed/byte-identical, but they are ordinary
# product apps now. Third-party code must not inherit platform package/user/
# telephony/Wi-Fi/reset powers merely because it was preinstalled.
for package_spec in \
    com.huawei.appmarket:AppGallery \
    com.huawei.hwid:HMSCore; do
    pkg="${package_spec%%:*}"
    module="${package_spec#*:}"
    # `pm list packages <name>` is a SUBSTRING filter, so it would have
    # reported a hypothetical com.huawei.appmarket.stub as com.huawei.appmarket
    # -- and `pm` exits 0 even when it lists nothing at all. Anchor it the way
    # the GApps block above does with has "^package:${p}$".
    check "${pkg} installed" "pm list packages | grep -Fx 'package:${pkg}'"
    # Three-state, because two of the three gates below put their PASS on an
    # absence read out of this dump. The flags gate already distinguished
    # "unreadable"; the permission gate did not, and its PASS fired on an empty
    # dump -- so a dead transport certified that a Huawei package holds none of
    # thirteen forbidden permissions.
    probe_remote "dumpsys package ${pkg} 2>/dev/null"
    package_dump="${PROBE_OUT}"
    package_dump_read=false
    [[ -n "${PROBE_RC}" && -n "${package_dump}" ]] && package_dump_read=true
    must_write_text "${CAPTURE_DIR}/huawei-${pkg}-package.txt" \
        "${package_dump}" || true
    code_path="$(awk -F= '
        /^[[:space:]]*codePath=/ {
            count++
            if (count == 1) print $2
        }
    ' <<<"${package_dump}")"
    # A-only Q has no product partition: /product -> /system/product, and
    # PackageManager reports the resolved path. Both are ordinary product apps.
    if [[ "${package_dump_read}" != true ]]; then
        skip "${pkg} is an ordinary product app"
    elif [[ "${code_path}" == "/product/app/${module}" || \
            "${code_path}" == "/system/product/app/${module}" ]]; then
        ok "${pkg} is an ordinary product app"
    elif [[ -n "${code_path}" ]]; then
        no "${pkg} codePath=${code_path}, expected /product/app/${module} or /system/product/app/${module}"
    else
        no "${pkg} package dump has no readable codePath"
    fi

    huawei_flag_lines="$(grep -E '(^|[[:space:]])(pkg|private)Flags=\[' \
        <<<"${package_dump}")"
    if [[ "${package_dump_read}" != true ]]; then
        skip "${pkg} has no PRIVILEGED package flag"
    elif grep -Eq '(^|[[:space:]])PRIVILEGED([[:space:]]|\])' \
            <<<"${huawei_flag_lines}"; then
        no "${pkg} still carries the PRIVILEGED package flag"
    elif [[ -n "${huawei_flag_lines}" ]]; then
        ok "${pkg} has no PRIVILEGED package flag"
    else
        no "${pkg} package flags are unreadable"
    fi

    unexpected_huawei_permissions=0
    for permission in \
        android.permission.INSTALL_PACKAGES \
        android.permission.DELETE_PACKAGES \
        android.permission.MANAGE_USERS \
        android.permission.MASTER_CLEAR \
        android.permission.MODIFY_PHONE_STATE \
        android.permission.READ_WIFI_CREDENTIAL \
        android.permission.WRITE_APN_SETTINGS \
        android.permission.WRITE_SECURE_SETTINGS \
        android.permission.ACCESS_BACKGROUND_LOCATION \
        android.permission.ACCESS_FINE_LOCATION \
        android.permission.CAMERA \
        android.permission.READ_CONTACTS \
        android.permission.READ_SMS; do
        if [[ "${package_dump_read}" == true ]] && \
           grep -Fq "${permission}: granted=true" <<<"${package_dump}"; then
            no "${pkg} unexpectedly has ${permission}"
            unexpected_huawei_permissions=$((unexpected_huawei_permissions + 1))
        fi
    done
    if [[ "${package_dump_read}" != true ]]; then
        skip "${pkg} has none of the forbidden platform/pre-granted permissions"
    elif [[ "${unexpected_huawei_permissions}" -eq 0 ]]; then
        ok "${pkg} has none of the forbidden platform/pre-granted permissions"
    fi
done
# `ls` prints nothing both when neither exception exists -- the PASS -- and when
# nothing ran at all. The sentinel is what makes the empty answer an answer.
probe_remote 'ls \
    /product/etc/permissions/privapp-permissions-huawei.xml \
    /product/etc/default-permissions/default-permissions-huawei.xml \
    2>/dev/null'
if [[ -z "${PROBE_RC}" ]]; then
    skip "no Huawei privapp/default-permission exception is installed"
elif [[ -z "${PROBE_OUT}" ]]; then
    ok "no Huawei privapp/default-permission exception is installed"
else
    no "obsolete Huawei permission exception remains: ${PROBE_OUT//$'\n'/ }"
fi

# The emergency-call fix. Assert the value the framework actually resolved.
#
# It must be read out of the mConfigFromDefaultApp block, per phone. A bare grep
# is WRONG and reports a false failure: dumpsys prints "Default Values from
# CarrierConfigManager" first, and that section is the hardcoded framework
# default, which still says true and always will -- the CarrierConfig app's
# contribution is merged over it, not into it. This check failed exactly that
# way on its first run against a build where the fix was working.
carrier_config_dump="$(sh_ 'dumpsys carrier_config 2>/dev/null')"
# WAS BROKEN in exactly the way the comment above says this function exists to
# avoid. The awk was
#     /mConfigFromDefaultApp/{f=1} f && $1 == key {print $3; f=0}
# which SET the section flag on the header and cleared it only on a HIT. A phone
# whose mConfigFromDefaultApp did not contain the key therefore left f=1 running
# through "mConfigFromCarrierApp : null", "mOverrideConfigs : null", the next
# "Phone Id = N" line and straight into that phone's "Default Values from
# CarrierConfigManager" block -- the hardcoded framework default this function
# was written to stay out of. Measured layout on this handset (773 lines):
# "Phone Id = N" at column 0, four section headers per phone indented four,
# key lines indented twelve. So clear the flag at EVERY section boundary.
#
# The denominator was wrong too: it counted values FOUND, not slots, so a
# dual-SIM handset where slot 1 contributed nothing printed "on all 1 slot(s)"
# -- a PASS whose own text states the defect. Count "Phone Id =" lines instead
# and tag every value with the phone that produced it.
carrier_config_phones="$(grep -c '^Phone Id[[:space:]]*=' <<<"${carrier_config_dump}")"
config_from_default_app() {
    awk -v key="$1" '
        /^Phone Id[[:space:]]*=/ { phone = $NF; f = 0; next }
        /^[[:space:]]+(Default Values from CarrierConfigManager|mConfigFromDefaultApp|mConfigFromCarrierApp|mOverrideConfigs)[[:space:]]*:/ {
            f = (index($0, "mConfigFromDefaultApp") > 0); next
        }
        f && $1 == key { print phone "=" $3 }
    ' <<<"${carrier_config_dump}"
}
# One gate for both booleans, so the slot arithmetic cannot drift between them.
carrier_config_bool_gate() {
    local key="$1" want="$2" label="$3" values n_have n_want
    values="$(config_from_default_app "${key}")"
    n_have="$(grep -c '=' <<<"${values}")"
    n_want="$(grep -c "=${want}\$" <<<"${values}")"
    if [[ -z "${carrier_config_dump}" || "${carrier_config_phones}" -lt 1 ]]; then
        skip "${key}"
    elif [[ "${n_want}" -eq "${carrier_config_phones}" ]]; then
        ok "${key} = ${want} on all ${carrier_config_phones} slot(s) (${label})"
    elif [[ "${n_have}" -lt "${carrier_config_phones}" ]]; then
        no "${key}: the CarrierConfig app contributed a value on only ${n_have} of ${carrier_config_phones} slot(s) -- the vendor.xml overlay did not reach the rest [${values//$'\n'/ }]"
    else
        no "${key} = ${want} on only ${n_want} of ${carrier_config_phones} slot(s) [${values//$'\n'/ }]"
    fi
}
carrier_config_bool_gate carrier_use_ims_first_for_emergency_bool false 'WI-020 fix live' 

# VoLTE and Wi-Fi calling availability are CARRIER gates, not device-global
# declarations. vendor.xml sets both bools true for the identities the owner
# wants the Settings switches on -- China Mobile (46000/02/04/07/08), China
# Unicom (46001/06/09) and the proven Vodafone NL 20404 allocation -- and
# leaves every other carrier at its AOSP/carrier-app default. Stock reaches the
# same switches through MtkCarrierConfigManager.putDefault(), which flips both
# AOSP defaults to true for every SIM; LineageOS has no such patch, so the
# overlay is the only source of a true here (E-170). A missing
# key in mConfigFromDefaultApp means false; it is not an overlay failure (the
# global emergency key above separately proves that vendor.xml loaded).
volte_values="$(config_from_default_app carrier_volte_available_bool)"
wfc_values="$(config_from_default_app carrier_wfc_ims_available_bool)"
IFS=',' read -r -a sim_home_operators <<<"${sim_operator}"
# carrier_config_phones is a count of "Phone Id =" lines in a dump that sh_()
# returns empty for a dead transport, so a zero here ran the loop body zero
# times: no ok, no no, no skip, and a green run that asserted nothing at all
# about VoLTE. The gate above this one already skips on the same condition.
if [[ -z "${carrier_config_dump}" || "${carrier_config_phones}" -lt 1 ]]; then
    skip "per-slot carrier VoLTE/WFC matrix (dumpsys carrier_config listed no phone)"
fi
for ((phone = 0; phone < carrier_config_phones; phone++)); do
    home_operator="${sim_home_operators[${phone}]:-}"
    actual_volte="$(awk -F= -v phone="${phone}" '$1 == phone { print $2; exit }' \
        <<<"${volte_values}")"
    actual_wfc="$(awk -F= -v phone="${phone}" '$1 == phone { print $2; exit }' \
        <<<"${wfc_values}")"
    [[ -n "${actual_volte}" ]] || actual_volte=false
    [[ -n "${actual_wfc}" ]] || actual_wfc=false
    case "${home_operator}" in
        20404 | 46000 | 46002 | 46004 | 46007 | 46008 | 46001 | 46006 | 46009)
            [[ "${actual_volte}" == true ]] \
                && ok "phone ${phone} home ${home_operator}: carrier VoLTE available (VoLTE switch shown)" \
                || no "phone ${phone} home ${home_operator}: carrier_volte_available_bool=${actual_volte} (expected true; the VoLTE switch is hidden)"
            [[ "${actual_wfc}" == true ]] \
                && ok "phone ${phone} home ${home_operator}: carrier WFC available (Wi-Fi calling switch shown)" \
                || no "phone ${phone} home ${home_operator}: carrier_wfc_ims_available_bool=${actual_wfc} (expected true; the Wi-Fi calling switch is hidden)"
            ;;
        '')
            skip "phone ${phone} carrier VoLTE/WFC matrix (no active home operator)"
            ;;
        *)
            skip "phone ${phone} home ${home_operator}: preserve its AOSP/carrier-app VoLTE/WFC policy"
            ;;
    esac
done

# wlan_assistant. The service must be running (no longer `disabled`) and must
# have completed its push, which it signals with its own output property. The
# MAC is the end-to-end proof: the factory value, not a random one.
# These two used sh_(), which discards the remote status, so a dead transport
# produced the same empty string as an unset property and both reported a hard
# FAIL against a handset nobody had read. probe_remote()'s sentinel separates
# them: with the sentinel back, an empty answer IS the property being unset and
# the FAIL is real; without it, nothing ran.
probe_remote 'getprop init.svc.wlan_assistant'
if [[ -z "${PROBE_RC}" ]]; then skip "init.svc.wlan_assistant"
elif [[ "${PROBE_OUT}" == running ]]; then ok "init.svc.wlan_assistant=running"
else no "init.svc.wlan_assistant=${PROBE_OUT:-<unset>} (expected running)"; fi
probe_remote 'getprop vendor.mtk.nvram.ready'
if [[ -z "${PROBE_RC}" ]]; then skip "vendor.mtk.nvram.ready"
elif [[ "${PROBE_OUT}" == 1 ]]; then ok "wlan_assistant completed its NVRAM push"
elif [[ -n "${PROBE_OUT}" ]]; then no "vendor.mtk.nvram.ready=${PROBE_OUT} -- the push did not complete"
else no "vendor.mtk.nvram.ready is EMPTY -- wlan_assistant never pushed NVRAM (no 5 GHz, random MAC)"; fi
mac="$(sh_ 'cat /sys/class/net/wlan0/address')"
if [[ "${mac}" == "2c:45:67:89:f9:2c" ]]; then ok "wlan0 has the factory NVRAM MAC"
elif [[ -n "${mac}" ]]; then no "wlan0 MAC is ${mac}, not the factory 2c:45:67:89:f9:2c"
else skip "wlan0 MAC"; fi
# The sharpest of the four. This counted 5 GHz channel lines with grep -c on
# the HANDSET, so `iw` being absent, phy0 not existing, or the transport being
# dead all yielded the string "0" -- and the tool then announced "the NVRAM
# regression is back", naming a specific, expensive, already-once-real defect
# (E-047/E-050) on the strength of a missing binary. Establish that `iw` ran and
# said something first; only then is an empty 5 GHz list evidence about NVRAM.
probe_remote 'iw phy phy0 info 2>/dev/null'
if [[ -z "${PROBE_RC}" ]]; then
    skip "5 GHz band"
elif [[ "${PROBE_RC}" != 0 || -z "${PROBE_OUT}" ]]; then
    skip "5 GHz band: 'iw phy phy0 info' exited ${PROBE_RC} with no output -- iw or phy0 is missing, which says nothing about NVRAM"
else
    ch5="$(grep -cE '\* 5[0-9]{3} MHz' <<<"${PROBE_OUT}")"
    if [[ "${ch5}" -gt 0 ]] 2>/dev/null; then ok "5 GHz band present (${ch5} channels listed)"
    else no "iw listed no 5 GHz channels -- the NVRAM regression is back"; fi
fi

# The migrated prebuilts. Every one of these must exist on /vendor and must have
# come from AOSP source, which is what the vendor tree no longer shipping them
# proves at build time; here we only assert they are present and loadable.
for lib in libtinyxml.so libalsautils.so libnbaio_mono.so libsensorndkbridge.so \
           hw/audio.usb.default.so hw/audio.r_submix.default.so \
           hw/android.hardware.audio.effect@5.0-impl.so; do
    check "migrated: ${lib}" "ls /vendor/lib64/${lib} /vendor/lib/${lib} 2>/dev/null | head -1"
done
# The effect chain is the one with a runtime consequence: every effect goes
# through the HAL shim, which dlopens the five wrappers.
# Same shape as the 5 GHz gate: grep -c on the handset turned "lshal could not
# be read" into the number 0, and 0 was reported as a hard FAIL naming the
# migrated shim. Count locally, over output that is proven to exist.
probe_remote 'lshal 2>/dev/null'
if [[ -z "${PROBE_RC}" || -z "${PROBE_OUT}" ]]; then
    skip "audio effect HAL registration (lshal produced nothing)"
else
    eff="$(grep -c 'audio.effect@5.0::IEffectsFactory' <<<"${PROBE_OUT}")"
    if [[ "${eff}" -gt 0 ]] 2>/dev/null; then ok "audio effect HAL registered"
    else no "audio.effect@5.0::IEffectsFactory not registered -- the migrated shim did not come up"; fi
fi

evaluate_avcs

tool_meta="$({
    printf 'tool_verify_post_flash_sha256=%s\n' \
        "$(sha256sum "${TOOL_DIR}/verify-post-flash.sh" | awk '{ print $1 }')"
    printf 'tool_verify_stage_contract_sha256=%s\n' \
        "$(sha256sum "${VERIFY_STAGE_TOOL}" | awk '{ print $1 }')"
    printf 'tool_avc_classifier_sha256=%s\n' \
        "$(sha256sum "${AVC_CLASSIFIER}" | awk '{ print $1 }')"
    printf 'tool_pstore_classifier_sha256=%s\n' \
        "$(sha256sum "${PSTORE_CLASSIFIER}" | awk '{ print $1 }')"
})"
must_append_text "${CAPTURE_DIR}/META.txt" "${tool_meta}" || true

MANDATORY_EVIDENCE=(
    META.txt
    early-dmesg.txt early-logcat-all.txt
    late-dmesg.txt late-logcat-all.txt
    getprop.txt telephony-registry.txt
    setup-state.txt
    launcher-policy.json
    screenrecord-tombstones.txt screenrecord-metadata.txt
    screenrecord-hardware-log.txt
    continuous-dmesg.txt continuous-logcat-all.txt
    continuous-logcat-kernel.txt continuous-logcat-events.txt
    continuous-logcat-main.txt continuous-logcat-system.txt
    continuous-logcat-radio.txt
    huawei-com.huawei.appmarket-package.txt
    huawei-com.huawei.hwid-package.txt
    provenance/SHA256SUMS
    provenance/SOURCE-MANIFEST
    provenance/SOURCE-MANIFEST.sha256
    provenance/K50SV1-BUILD-RECEIPT
    provenance/K50SV1-BUILD-SOURCE-STATE
    provenance/K50SV1-ANDROID-REPO-MANIFEST.xml
    provenance/STAGE-CONTRACT
    provenance/STAGE-CONTRACT.sha256
    provenance/FLASH-RECEIPT
)
# launch_package() only runs behind the post_setup_ready gate, so these four
# artifacts exist only when LineageSetupWizard has completed. Listing them
# unconditionally turned a legitimate, explicitly-skipped pre-setup run into
# four evidence_errors and an INCOMPLETE verdict about evidence nobody had
# asked the handset to produce.
if [[ "${post_setup_ready}" == true ]]; then
    MANDATORY_EVIDENCE+=(
        default-dialer-probes.txt
        launch-com.android.settings.txt
        launch-com.android.vending.txt
        launch-com.android.deskclock.txt
        launch-org.lineageos.etar.txt
    )
fi
validate_evidence_artifact() {
    local evidence_file="$1"
    local evidence_path="${CAPTURE_DIR}/${evidence_file}"
    if [[ ! -f "${evidence_path}" || -L "${evidence_path}" || \
          ! -s "${evidence_path}" ]] || \
       ! LC_ALL=C grep -aq '[^[:space:]]' "${evidence_path}"; then
        evidence_error "mandatory nonempty artifact ${evidence_file}"
    fi
}
for evidence_file in "${MANDATORY_EVIDENCE[@]}"; do
    validate_evidence_artifact "${evidence_file}"
done
if ! unexpected_symlink="$(find "${CAPTURE_DIR}" -type l -print -quit 2>/dev/null)"; then
    evidence_error "cannot scan capture for symlinks"
elif [[ -n "${unexpected_symlink}" ]]; then
    evidence_error "capture contains symlink ${unexpected_symlink}"
fi

# A capture used to hash all of its raw artifacts but omit the verifier's own
# verdict: the PASS/FAIL/UNREAD list and counters existed only on the terminal.
# The verdict is written into the capture, and therefore into the checksum
# manifest, so a hash-valid capture also proves what was checked and how the run
# ended.
#
# ORDER MATTERS, and it was wrong. The verdict used to be derived and written
# BEFORE the manifest, but building the manifest is itself an evidence check
# that calls evidence_error -- so an archived RESULT.txt could read
# `status=PASS exit_code=0` while this process exited 1 on a manifest failure
# that happened after the file was already on disk. Everything except the
# verdict is hashed first; then the verdict is derived from the final counters;
# then it is written and its own digest appended. What remains after the verdict
# is written is only its own write/validate and that one append, and every one
# of those failures leaves the capture with no checkable EVIDENCE-SHA256SUMS at
# all -- so no reader can take the verdict as attested.
EVIDENCE_CHECKSUMS="${CAPTURE_DIR}/EVIDENCE-SHA256SUMS"
EVIDENCE_CHECKSUMS_INCOMPLETE="${EVIDENCE_CHECKSUMS}.incomplete"
evidence_manifest_open=false
if (
    set -o pipefail
    cd "${CAPTURE_DIR}" || exit 1
    find . -type f \
        ! -name 'EVIDENCE-SHA256SUMS' \
        ! -name 'EVIDENCE-SHA256SUMS.incomplete' \
        ! -name 'RESULT.txt' \
        -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum
) >"${EVIDENCE_CHECKSUMS_INCOMPLETE}" && \
   [[ -s "${EVIDENCE_CHECKSUMS_INCOMPLETE}" ]]; then
    evidence_manifest_open=true
else
    rm -f -- "${EVIDENCE_CHECKSUMS_INCOMPLETE}" 2>/dev/null || true
    evidence_error "capture checksum manifest"
fi

if [[ "${fail}" -gt 0 ]]; then
    result_status=FAIL
elif [[ "${unread}" -gt 0 || "${evidence_fatal}" -gt 0 ]]; then
    result_status=INCOMPLETE
else
    result_status=PASS
fi
if [[ "${result_status}" == PASS ]]; then
    result_exit_code=0
else
    result_exit_code=1
fi
result_record="$({
    printf 'result.version=2\n'
    printf 'status=%s\n' "${result_status}"
    printf 'exit_code=%d\n' "${result_exit_code}"
    printf 'passed=%d\nfailed=%d\nunread=%d\nevidence_fatal=%d\ninformational=%d\n' \
        "${pass}" "${fail}" "${unread}" "${evidence_fatal}" "${info}"
    printf 'attested_by=EVIDENCE-SHA256SUMS\n'
    printf 'checks_begin\n%schecks_end\n' "${result_records}"
})"
must_write_text "${CAPTURE_DIR}/RESULT.txt" "${result_record}" || true
validate_evidence_artifact RESULT.txt

if [[ "${evidence_manifest_open}" == true ]]; then
    if ! ( cd "${CAPTURE_DIR}" && sha256sum ./RESULT.txt ) \
            >>"${EVIDENCE_CHECKSUMS_INCOMPLETE}" || \
       ! chmod 0644 "${EVIDENCE_CHECKSUMS_INCOMPLETE}" || \
       ! mv -T "${EVIDENCE_CHECKSUMS_INCOMPLETE}" "${EVIDENCE_CHECKSUMS}" || \
       ! (cd "${CAPTURE_DIR}" && \
            sha256sum --quiet --strict --check EVIDENCE-SHA256SUMS); then
        rm -f -- "${EVIDENCE_CHECKSUMS_INCOMPLETE}" 2>/dev/null || true
        evidence_error "capture checksum manifest"
    fi
fi

printf '\n== summary: %d passed, %d failed, %d unread, %d evidence-fatal, %d informational ==\n' \
    "${pass}" "${fail}" "${unread}" "${evidence_fatal}" "${info}"
if [[ "${evidence_fatal}" -eq 0 ]]; then
    printf 'verified evidence capture: %s\n' "${CAPTURE_DIR}"
else
    printf 'INCOMPLETE evidence capture: %s\n' "${CAPTURE_DIR}" >&2
fi
if [[ "${unread}" -gt 0 ]]; then
    printf 'NOTE: %d check(s) could not read the handset and did not run. That is not\n' "${unread}"
    printf '      a pass. Re-run once the device is idle before drawing conclusions.\n'
fi
# Exit non-zero if anything failed OR if any check could not run. The script's
# own policy at the top says an unread check "has not failed -- it has not run.
# That is not a pass"; the exit code used to disagree with that, so a run where
# half the checks never executed still exited 0.
[[ "${fail}" -eq 0 && "${unread}" -eq 0 && "${evidence_fatal}" -eq 0 ]]
