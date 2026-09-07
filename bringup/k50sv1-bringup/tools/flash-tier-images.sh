#!/usr/bin/env bash
# Flash boot, recovery, system and vendor from a verified stage.
# This helper always wipes userdata, metadata and cache. The owner delegates
# wipe choices; invoking this helper selects a clean install.
# Logo has a separate authorized flasher. Bootloader, modem, identity and
# calibration partitions are excluded from this helper's write set.
# K50SV1_FLASH_REBOOT=0 leaves fastboot active for an explicit userdata fixture;
# the receipt records a deferred reboot and does not claim an Android boot.

set -euo pipefail

FLASH_REBOOT="${K50SV1_FLASH_REBOOT:-1}"
case "${FLASH_REBOOT}" in
    0 | 1) ;;
    *) printf 'K50SV1_FLASH_REBOOT must be 0 or 1\n' >&2; exit 2 ;;
esac

WRITABLE_PARTITIONS=(boot recovery system vendor)
WIPE_PARTITIONS=(userdata metadata cache)
SIMG2IMG="$(command -v simg2img || true)"
UNPACK_BOOTIMG="$(command -v unpack_bootimg || true)"

# Verified against the live GPT, in bytes. Refusing to flash an oversized image
# matters more here than usual: this bootloader will happily start writing and
# run off the end of the partition.
declare -A PARTITION_BYTES=(
    [boot]=16777216
    [recovery]=16777216
    [vendor]=2147483648
    [system]=4294967296
    [metadata]=33554432
    [cache]=452984832
)

# Every sibling tool resolves itself with BASH_SOURCE + cd and pins adb to an
# absolute ADB_BIN; this one used `$(dirname "$0")` for its data file and a
# bare `adb` from PATH. Both are consistency fixes with teeth here: `$0` is
# whatever the caller typed, so a `sh tools/flash-tier-images.sh` from another
# directory looked for .expected-fastboot-product in the wrong place and the
# script would refuse to flash for the wrong reason -- and a PATH adb is not
# necessarily the platform-tools 37 build this device needs, which HANDOFF says
# also requires ADB_LIBUSB=1 to enumerate it at all.
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_STAGE_TOOL="${TOOL_DIR}/verify-stage-contract.sh"
ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
FASTBOOT_BIN="${FASTBOOT_BIN:-/home/desmond/Android/Sdk/platform-tools/fastboot}"
export ADB_LIBUSB="${ADB_LIBUSB:-1}"

IMAGE_DIR="${1:-}"
FLASH_RECEIPT="${2:-}"
if [[ -z "${IMAGE_DIR}" || ! -d "${IMAGE_DIR}" || -z "${FLASH_RECEIPT}" || \
      "$#" -ne 3 ]]; then
    printf 'usage: %s <stage-dir> <new-flash-receipt> <adb-and-fastboot-serial>\n' "$0" >&2
    printf '  stage-dir must be a complete stage-contract bundle\n' >&2
    exit 2
fi
SERIAL="$3"
[[ ! -L "${IMAGE_DIR}" ]] || {
    printf 'stage directory may not be a symlink: %s\n' "${IMAGE_DIR}" >&2
    exit 1
}
IMAGE_DIR="$(realpath -e "${IMAGE_DIR}")"

flash_receipt_parent="$(dirname "${FLASH_RECEIPT}")"
flash_receipt_name="$(basename "${FLASH_RECEIPT}")"
[[ "${flash_receipt_name}" != . && "${flash_receipt_name}" != .. && \
   "${flash_receipt_name}" != / ]] || {
    printf 'unsafe flash-receipt name: %s\n' "${FLASH_RECEIPT}" >&2
    exit 2
}
[[ ! -e "${FLASH_RECEIPT}" && ! -L "${FLASH_RECEIPT}" && \
   ! -e "${FLASH_RECEIPT}.incomplete" && ! -L "${FLASH_RECEIPT}.incomplete" ]] || {
    printf 'flash receipt or incomplete journal already exists: %s\n' \
        "${FLASH_RECEIPT}" >&2
    exit 1
}
[[ -d "${flash_receipt_parent}" && ! -L "${flash_receipt_parent}" ]] || {
    printf 'flash-receipt parent must be an existing ordinary directory: %s\n' \
        "${flash_receipt_parent}" >&2
    exit 2
}
flash_receipt_parent="$(realpath -e "${flash_receipt_parent}")"
FLASH_RECEIPT="${flash_receipt_parent}/${flash_receipt_name}"
FLASH_RECEIPT_INCOMPLETE="${FLASH_RECEIPT}.incomplete"

[[ -x "${VERIFY_STAGE_TOOL}" ]] || {
    printf 'stage-contract verifier is unavailable: %s\n' "${VERIFY_STAGE_TOOL}" >&2
    exit 1
}
[[ -x "${ADB_BIN}" && -f "${ADB_BIN}" && ! -L "${ADB_BIN}" ]] || {
    printf 'pinned adb binary is unavailable or unsafe: %s\n' "${ADB_BIN}" >&2
    exit 1
}
[[ -x "${FASTBOOT_BIN}" && -f "${FASTBOOT_BIN}" && ! -L "${FASTBOOT_BIN}" ]] || {
    printf 'pinned fastboot binary is unavailable or unsafe: %s\n' "${FASTBOOT_BIN}" >&2
    exit 1
}
[[ "$(dirname "$(realpath -e "${ADB_BIN}")")" == \
   "$(dirname "$(realpath -e "${FASTBOOT_BIN}")")" ]] || {
    printf 'adb and fastboot must come from one pinned platform-tools directory\n' >&2
    exit 1
}
ADB_BIN_SHA="$(sha256sum "${ADB_BIN}" | awk '{ print $1 }')"
FASTBOOT_BIN_SHA="$(sha256sum "${FASTBOOT_BIN}" | awk '{ print $1 }')"
FASTBOOT_VERSION="$({ "${FASTBOOT_BIN}" --version 2>&1 || true; } | sed -n '1p')"
[[ "${ADB_BIN_SHA}" =~ ^[0-9a-f]{64}$ && \
   "${FASTBOOT_BIN_SHA}" =~ ^[0-9a-f]{64}$ && \
   -n "${FASTBOOT_VERSION}" ]] || {
    printf 'cannot identify pinned platform-tools binaries\n' >&2
    exit 1
}
if ! stage_contract_report="$("${VERIFY_STAGE_TOOL}" "${IMAGE_DIR}")"; then
    printf 'refusing to flash: stage contract is invalid\n' >&2
    exit 1
fi
report_get_exact() {
    local key="$1"
    awk -F= -v key="${key}" '
        $1 == key { count++; value = substr($0, length(key) + 2) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' <<<"${stage_contract_report}"
}
STAGE_CONTRACT_SHA="$(report_get_exact stage_contract_sha256)" || {
    printf 'stage verifier returned no unique top-level digest\n' >&2
    exit 1
}
SOURCE_MANIFEST_SHA="$(report_get_exact source_manifest_sha256)"
BUILD_RECEIPT_SHA="$(report_get_exact build_receipt_sha256)"
BUILD_TIER="$(report_get_exact tier)"
BUILD_VARIANT="$(report_get_exact variant)"
PUBLIC_FINGERPRINT="$(report_get_exact public_fingerprint)"
SYSTEM_FINGERPRINT="$(report_get_exact system_fingerprint)"
BUILD_INCREMENTAL="$(report_get_exact build_incremental)"
[[ "$(report_get_exact status)" == PASS ]] || {
    printf 'stage verifier did not report PASS\n' >&2
    exit 1
}
stage_manifest_get() {
    local key="$1"
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++; value = substr($0, length(key) + 2)
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${IMAGE_DIR}/SOURCE-MANIFEST"
}
APPROVED_FLASH_TOOL_SHA="$(stage_manifest_get tool.flash_tier_images_sha256)"
APPROVED_VERIFY_STAGE_SHA="$(stage_manifest_get tool.verify_stage_contract_sha256)"
[[ "${APPROVED_FLASH_TOOL_SHA}" == \
        "$(sha256sum "${TOOL_DIR}/flash-tier-images.sh" | awk '{ print $1 }')" && \
   "${APPROVED_VERIFY_STAGE_SHA}" == \
        "$(sha256sum "${VERIFY_STAGE_TOOL}" | awk '{ print $1 }')" ]] || {
    printf 'flash/stage verifier differs from tooling bound into the stage contract\n' >&2
    exit 1
}

declare -A VERIFIED_PAYLOAD_SHA=()
declare -A VERIFIED_PAYLOAD_BYTES=()
for payload in \
    boot.kernel boot.ramdisk boot.dtb \
    recovery.kernel recovery.ramdisk recovery.dtb \
    recovery.recovery_dtbo; do
    VERIFIED_PAYLOAD_SHA[${payload}]="$(stage_manifest_get \
        "payload.${payload}.sha256")"
    VERIFIED_PAYLOAD_BYTES[${payload}]="$(stage_manifest_get \
        "payload.${payload}.bytes")"
    [[ "${VERIFIED_PAYLOAD_SHA[${payload}]}" =~ ^[0-9a-f]{64}$ && \
       "${VERIFIED_PAYLOAD_BYTES[${payload}]}" =~ ^[0-9]+$ && \
       "${VERIFIED_PAYLOAD_BYTES[${payload}]}" -gt 0 ]] || {
        printf 'verified stage has invalid %s payload metadata\n' "${payload}" >&2
        exit 1
    }
done

for part in "${WRITABLE_PARTITIONS[@]}"; do
    img="${IMAGE_DIR}/${part}.img"
    if [[ ! -f "${img}" || -L "${img}" || ! -s "${img}" ]]; then
        printf 'missing, empty, or symlinked image: %s\n' "${img}" >&2
        exit 1
    fi
    size=$(stat -c %s "${img}")
    if (( size > PARTITION_BYTES[${part}] )); then
        printf '%s.img is %d bytes, larger than the %d-byte %s partition\n' \
            "${part}" "${size}" "${PARTITION_BYTES[${part}]}" "${part}" >&2
        exit 1
    fi
    printf '  %-9s %10d / %10d bytes\n' "${part}.img" "${size}" "${PARTITION_BYTES[${part}]}"
done

[[ -x "${SIMG2IMG}" ]] || {
    printf 'host simg2img is required to validate sparse images\n' >&2
    exit 1
}
[[ -x "${UNPACK_BOOTIMG}" ]] || {
    printf 'host unpack_bootimg is required to validate boot images\n' >&2
    exit 1
}

validate_boot_payloads() (
    local directory="$1"
    local validation_tmp image payload info selinux_tokens expected_variant
    local payload_path payload_key payload_sha payload_bytes

    validation_tmp="$(mktemp -d /tmp/k50-boot-validate.XXXXXX)"
    cleanup_boot_validation() {
        if [[ -d "${validation_tmp:-}" && ! -L "${validation_tmp}" && \
              "${validation_tmp}" == /tmp/k50-boot-validate.* ]]; then
            find "${validation_tmp}" -mindepth 1 -depth -delete
            rmdir "${validation_tmp}"
        fi
    }
    trap cleanup_boot_validation EXIT
    for image in boot recovery; do
        mkdir "${validation_tmp}/${image}"
        info="${validation_tmp}/${image}.info"
        "${UNPACK_BOOTIMG}" --boot_img "${directory}/${image}.img" \
            --out "${validation_tmp}/${image}" --format info >"${info}" || {
            return 1
        }
        for payload in kernel ramdisk dtb; do
            payload_path="${validation_tmp}/${image}/${payload}"
            payload_key="${image}.${payload}"
            [[ -f "${payload_path}" && ! -L "${payload_path}" && \
               -s "${payload_path}" ]] || return 1
            payload_sha="$(sha256sum "${payload_path}" | awk '{ print $1 }')"
            payload_bytes="$(stat -c %s "${payload_path}")"
            [[ "${payload_sha}" == "${VERIFIED_PAYLOAD_SHA[${payload_key}]}" && \
               "${payload_bytes}" == \
                   "${VERIFIED_PAYLOAD_BYTES[${payload_key}]}" ]] || return 1
        done
        grep -Fxq 'boot magic: ANDROID!' "${info}" || return 1
        grep -Fxq 'page size: 2048' "${info}" || return 1
        grep -Fxq 'os version: 10.0.0' "${info}" || return 1
        grep -Fxq 'boot image header version: 2' "${info}" || return 1
        ! grep -Eq '(^|[[:space:]])module\.sig_enforce=1([[:space:]]|$)' \
            "${info}" || return 1
        expected_variant="buildvariant=${BUILD_VARIANT}"
        [[ "$(grep -Eo '(^|[[:space:]])buildvariant=[^[:space:]]+' "${info}" \
                | sed 's/^[[:space:]]//' | grep -Fxc "${expected_variant}" || true)" \
           -eq 1 ]] || return 1
        selinux_tokens="$(grep -Eo \
            '(^|[[:space:]])androidboot\.selinux=[^[:space:]]+' "${info}" \
            | sed 's/^[[:space:]]//' || true)"
        if [[ "${BUILD_TIER}" == 1 ]]; then
            [[ "${selinux_tokens}" == androidboot.selinux=permissive ]] || return 1
        else
            [[ -z "${selinux_tokens}" ]] || return 1
        fi
        if [[ "${image}" == recovery ]]; then
            [[ -f "${validation_tmp}/recovery/recovery_dtbo" && \
               ! -L "${validation_tmp}/recovery/recovery_dtbo" && \
               -s "${validation_tmp}/recovery/recovery_dtbo" ]] || return 1
            payload_sha="$(sha256sum \
                "${validation_tmp}/recovery/recovery_dtbo" | awk '{ print $1 }')"
            payload_bytes="$(stat -c %s \
                "${validation_tmp}/recovery/recovery_dtbo")"
            [[ "${payload_sha}" == \
                   "${VERIFIED_PAYLOAD_SHA[recovery.recovery_dtbo]}" && \
               "${payload_bytes}" == \
                   "${VERIFIED_PAYLOAD_BYTES[recovery.recovery_dtbo]}" ]] \
                || return 1
        elif [[ -e "${validation_tmp}/boot/recovery_dtbo" || \
                -L "${validation_tmp}/boot/recovery_dtbo" ]]; then
            return 1
        fi
    done
    cmp -s "${validation_tmp}/boot/kernel" \
        "${validation_tmp}/recovery/kernel" || return 1
    cmp -s "${validation_tmp}/boot/dtb" \
        "${validation_tmp}/recovery/dtb" || return 1
)

validate_boot_payloads "${IMAGE_DIR}" || {
    printf 'boot/recovery structure or receipt-bound payload validation failed\n' >&2
    exit 1
}
printf 'boot/recovery headers and receipt-bound source-kernel/stock-DT payloads verified\n'
for part in system vendor; do
    img="${IMAGE_DIR}/${part}.img"
    read -r block_size block_count < <(od -An -tu4 -j12 -N8 "${img}")
    if [[ "${block_size}" -ne 4096 ]]; then
        printf '%s.img has unexpected sparse block size %s\n' \
            "${part}" "${block_size}" >&2
        exit 1
    fi
    expanded_size=$((block_size * block_count))
    if (( expanded_size > PARTITION_BYTES[${part}] )); then
        printf '%s.img expands to %d bytes, larger than its %d-byte partition\n' \
            "${part}" "${expanded_size}" "${PARTITION_BYTES[${part}]}" >&2
        exit 1
    fi
    "${SIMG2IMG}" "${img}" /dev/null \
        || { printf '%s.img has invalid sparse structure\n' "${part}" >&2; exit 1; }
done
printf 'sparse image structures and expanded sizes verified\n'

manifest="${IMAGE_DIR}/SHA256SUMS"
if [[ ! -f "${manifest}" || -L "${manifest}" || ! -r "${manifest}" ]]; then
    printf 'missing, unreadable, or symlinked mandatory checksum manifest: %s\n' \
        "${manifest}" >&2
    exit 1
fi
digest_records="$(awk 'NF { n++ } END { print n + 0 }' "${manifest}")"
if [[ "${digest_records}" -ne "${#WRITABLE_PARTITIONS[@]}" ]]; then
    printf 'SHA256SUMS has %s non-empty records; expected exactly %d\n' \
        "${digest_records}" "${#WRITABLE_PARTITIONS[@]}" >&2
    exit 1
fi
for part in "${WRITABLE_PARTITIONS[@]}"; do
    digest_count="$(awk -v image="${part}.img" '$2 == image { n++ } END { print n + 0 }' \
        "${manifest}")"
    if [[ "${digest_count}" -ne 1 ]]; then
        printf 'SHA256SUMS must name %s.img exactly once (found %s)\n' \
            "${part}" "${digest_count}" >&2
        exit 1
    fi
done
( cd "${IMAGE_DIR}" && sha256sum --quiet --strict --check SHA256SUMS )
printf 'image digests verified\n'

# From this point onward, flash only a private copy-on-write snapshot. The
# caller's stage directory may otherwise be rebuilt or replaced during the
# reboot/fastboot wait after its hashes were approved. Copying to a random
# private directory and verifying again binds all later writes to one byte set.
SOURCE_IMAGE_DIR="${IMAGE_DIR}"
approved_manifest_hash="$(sha256sum "${manifest}" | awk '{print $1}')"
SNAPSHOT_DIR="$(mktemp -d /tmp/k50-flash-images.XXXXXX)"
chmod 0700 "${SNAPSHOT_DIR}"
cleanup_snapshot() {
    if [[ -n "${SNAPSHOT_DIR:-}" && -d "${SNAPSHOT_DIR}" && \
          ! -L "${SNAPSHOT_DIR}" && \
          "${SNAPSHOT_DIR}" == /tmp/k50-flash-images.* ]]; then
        find "${SNAPSHOT_DIR}" -mindepth 1 -depth -delete
        rmdir "${SNAPSHOT_DIR}"
    fi
}
trap cleanup_snapshot EXIT
for part in "${WRITABLE_PARTITIONS[@]}"; do
    cp --reflink=auto -- "${SOURCE_IMAGE_DIR}/${part}.img" \
        "${SNAPSHOT_DIR}/${part}.img"
done
CONTRACT_FILES=(
    SHA256SUMS SOURCE-MANIFEST SOURCE-MANIFEST.sha256
    K50SV1-BUILD-RECEIPT K50SV1-BUILD-SOURCE-STATE
    K50SV1-ANDROID-REPO-MANIFEST.xml
    STAGE-CONTRACT STAGE-CONTRACT.sha256
)
# TIER 3 COULD NOT BE FLASHED AT ALL WITHOUT THIS. stage-tier-images.sh writes
# K50SV1-RELEASE-KEYSET into a Tier-3 stage and verify-stage-contract.sh:119-124
# hard-requires it, so the private snapshot re-verified below at
# "${VERIFY_STAGE_TOOL}" "${IMAGE_DIR}" would have failed for every Tier-3
# bundle -- the file simply was not copied. It failed closed, so nothing unsafe
# ever shipped; it just made the last step of the release pipeline unreachable,
# which is why eight hostile-fixture harnesses could all report PASS while the
# pipeline had never run end to end.
#
# Conditional, because verify-stage-contract.sh:125-127 REJECTS a diagnostic
# stage that carries the file.
if [[ "${BUILD_TIER}" == 3 ]]; then
    CONTRACT_FILES+=(K50SV1-RELEASE-KEYSET)
fi
for contract_file in "${CONTRACT_FILES[@]}"; do
    cp -- "${SOURCE_IMAGE_DIR}/${contract_file}" \
        "${SNAPSHOT_DIR}/${contract_file}"
done
IMAGE_DIR="${SNAPSHOT_DIR}"
manifest="${IMAGE_DIR}/SHA256SUMS"
[[ "$(sha256sum "${manifest}" | awk '{print $1}')" == \
   "${approved_manifest_hash}" ]] \
    || { printf 'private snapshot manifest changed during copy\n' >&2; exit 1; }
( cd "${IMAGE_DIR}" && sha256sum --quiet --strict --check SHA256SUMS )
if ! snapshot_contract_report="$("${VERIFY_STAGE_TOOL}" "${IMAGE_DIR}")"; then
    printf 'private flash snapshot failed the complete stage contract\n' >&2
    exit 1
fi
snapshot_stage_sha="$(awk -F= '$1 == "stage_contract_sha256" {
        count++; value = substr($0, length($1) + 2)
    } END { if (count != 1) exit 1; print value }' \
    <<<"${snapshot_contract_report}")" || {
    printf 'private snapshot verifier returned no unique stage digest\n' >&2
    exit 1
}
[[ "${snapshot_stage_sha}" == "${STAGE_CONTRACT_SHA}" ]] || {
    printf 'private snapshot belongs to a different stage contract\n' >&2
    exit 1
}
validate_boot_payloads "${IMAGE_DIR}" || {
    printf 'private snapshot boot/recovery payload validation failed\n' >&2
    exit 1
}
printf 'private flash snapshot verified from %s\n' "${SOURCE_IMAGE_DIR}"

# Reboot into the bootloader if the handset is still in Android.
if [[ -n "${SERIAL}" ]] && [[ -x "${ADB_BIN}" ]] && \
   "${ADB_BIN}" -s "${SERIAL}" shell true >/dev/null 2>&1; then
    printf 'rebooting %s into the bootloader\n' "${SERIAL}"
    "${ADB_BIN}" -s "${SERIAL}" reboot bootloader
fi

# Wait for the bootloader by POLLING, not by letting `fastboot getvar` block.
#
# The obvious spelling of this,
#     fastboot getvar product 2>&1 | head -1
# is a SIGPIPE trap and it cost a whole flash cycle. `fastboot getvar` blocks
# printing "< waiting for any device >", and when the handset finally appears it
# writes more output into a pipe whose reader (`head -1`) has already exited. The
# write takes SIGPIPE, the pipeline reports 141, and `set -o pipefail` turns that
# into a script abort -- AFTER the device is in fastboot, so it looks like the
# bootloader is at fault. This is the same class of bug already recorded against
# verify-post-flash.sh in notes/HANDOFF.md; the lesson evidently did not
# generalise, so it is spelled out here too: never pipe a long-running producer
# into a short-circuiting consumer under pipefail.
requested_fb_serial="${K50SV1_FASTBOOT_SERIAL:-${SERIAL}}"
if [[ -n "${K50SV1_FASTBOOT_SERIAL:-}" && \
      "${K50SV1_FASTBOOT_SERIAL}" != "${SERIAL}" ]]; then
    printf 'refusing split device identity: adb serial %s but requested fastboot serial %s\n' \
        "${SERIAL}" "${K50SV1_FASTBOOT_SERIAL}" >&2
    exit 1
fi
printf 'waiting for fastboot%s\n' \
    "${requested_fb_serial:+ serial ${requested_fb_serial}}"
fb_devices=()
fastboot_ready=false
for _ in $(seq 1 120); do
    mapfile -t fb_devices < <("${FASTBOOT_BIN}" devices 2>/dev/null | awk 'NF {print $1}')
    if [[ -n "${requested_fb_serial}" ]]; then
        for attached in "${fb_devices[@]}"; do
            if [[ "${attached}" == "${requested_fb_serial}" ]]; then
                fastboot_ready=true
                break
            fi
        done
    elif (( ${#fb_devices[@]} > 0 )); then
        fastboot_ready=true
    fi
    [[ "${fastboot_ready}" == true ]] && break
    sleep 1
done

# Select exactly one device, and pin every later fastboot call to its serial.
#
# This machine routinely has two adb transports for the same handset (USB and
# network), and the habit of writing bare `adb`/`fastboot` carries over. In
# fastboot there is normally only one, but "normally" is not a guard when the
# operation is an unrecoverable partition write: an unrelated board left plugged
# in would be flashed instead, silently and completely.
if [[ "${fastboot_ready}" != true ]]; then
    if [[ -n "${requested_fb_serial}" ]]; then
        printf 'requested fastboot serial %s did not appear within 120 s' \
            "${requested_fb_serial}" >&2
        if (( ${#fb_devices[@]} > 0 )); then
            printf '; attached devices:\n' >&2
            printf '  %s\n' "${fb_devices[@]}" >&2
        else
            printf '\n' >&2
        fi
    else
        printf 'no fastboot device after 120 s\n' >&2
    fi
    exit 1
fi
if [[ -n "${requested_fb_serial}" ]]; then
    selected=false
    for attached in "${fb_devices[@]}"; do
        if [[ "${attached}" == "${requested_fb_serial}" ]]; then
            selected=true
            break
        fi
    done
    if [[ "${selected}" != true ]]; then
        printf 'requested fastboot serial %s is not attached; attached devices:\n' \
            "${requested_fb_serial}" >&2
        printf '  %s\n' "${fb_devices[@]}" >&2
        exit 1
    fi
    FB_SERIAL="${requested_fb_serial}"
elif (( ${#fb_devices[@]} > 1 )); then
    printf 'refusing to flash: %d devices in fastboot:\n' "${#fb_devices[@]}" >&2
    printf '  %s\n' "${fb_devices[@]}" >&2
    printf 'set K50SV1_FASTBOOT_SERIAL to one attached serial, or unplug the others\n' >&2
    exit 1
else
    FB_SERIAL="${fb_devices[0]}"
fi
fb() { "${FASTBOOT_BIN}" -s "${FB_SERIAL}" "$@"; }
printf 'fastboot device %s\n' "${FB_SERIAL}"

# Identity check. An earlier revision printed `product` under a comment claiming
# it guarded against flashing the wrong handset, and then never compared it to
# anything -- a guard that exists only in its own comment is worse than none,
# because it stops anyone adding a real one. The expected value is committed in
# the tool directory (or supplied explicitly) and is mandatory before writing.
#
# Capture first, then filter: `fastboot getvar ... | sed | head` is the same
# SIGPIPE trap documented above.
if ! getvar_out="$(fb getvar product 2>&1)"; then
    printf 'refusing to flash: cannot query product from %s:\n%s\n' \
        "${FB_SERIAL}" "${getvar_out}" >&2
    exit 1
fi
product_lines="$(sed -n 's/^product: *//p' <<<"${getvar_out}")"
product="${product_lines%%$'\n'*}"
printf 'bootloader reports product=%s\n' "${product:-<unset>}"

EXPECT_FILE="${TOOL_DIR}/.expected-fastboot-product"
expected="${K50SV1_EXPECT_PRODUCT:-}"
if [[ -z "${expected}" && -r "${EXPECT_FILE}" ]]; then
    expected="$(cat "${EXPECT_FILE}")"
fi
if [[ -z "${expected}" ]]; then
    printf 'refusing to flash: no expected product; restore %s or set K50SV1_EXPECT_PRODUCT\n' \
        "${EXPECT_FILE}" >&2
    exit 1
fi
if [[ "${product}" != "${expected}" ]]; then
    printf 'refusing to flash: bootloader product is %s, expected %s\n' \
        "${product:-<unset>}" "${expected}" >&2
    printf 'if this really is the right handset, update %s deliberately\n' "${EXPECT_FILE}" >&2
    exit 1
fi
printf 'product matches the recorded expectation\n'

# Revalidate the private snapshot after the potentially long device wait and
# immediately before the first destructive operation.
[[ -f "${manifest}" && ! -L "${manifest}" && \
   "$(sha256sum "${manifest}" | awk '{print $1}')" == \
   "${approved_manifest_hash}" ]] \
    || { printf 'private flash manifest changed during device wait\n' >&2; exit 1; }
for part in "${WRITABLE_PARTITIONS[@]}"; do
    img="${IMAGE_DIR}/${part}.img"
    [[ -f "${img}" && ! -L "${img}" && -s "${img}" ]] \
        || { printf 'private %s.img changed type during device wait\n' "${part}" >&2; exit 1; }
    size="$(stat -c %s "${img}")"
    (( size <= PARTITION_BYTES[${part}] )) \
        || { printf 'private %s.img exceeds its partition after device wait\n' "${part}" >&2; exit 1; }
done
for part in system vendor; do
    img="${IMAGE_DIR}/${part}.img"
    read -r block_size block_count < <(od -An -tu4 -j12 -N8 "${img}")
    expanded_size=$((block_size * block_count))
    [[ "${block_size}" -eq 4096 ]] && \
        (( expanded_size <= PARTITION_BYTES[${part}] )) && \
        "${SIMG2IMG}" "${img}" /dev/null \
        || { printf 'private %s.img sparse gate changed during device wait\n' "${part}" >&2; exit 1; }
done
( cd "${IMAGE_DIR}" && sha256sum --quiet --strict --check SHA256SUMS )
if ! prewrite_contract_report="$("${VERIFY_STAGE_TOOL}" "${IMAGE_DIR}")" || \
   ! grep -Fxq "stage_contract_sha256=${STAGE_CONTRACT_SHA}" \
        <<<"${prewrite_contract_report}"; then
    printf 'private stage contract changed during the device wait\n' >&2
    exit 1
fi
validate_boot_payloads "${IMAGE_DIR}" || {
    printf 'private boot/recovery payloads changed during the device wait\n' >&2
    exit 1
}
[[ "$(sha256sum "${TOOL_DIR}/flash-tier-images.sh" | awk '{ print $1 }')" == \
        "${APPROVED_FLASH_TOOL_SHA}" && \
   "$(sha256sum "${VERIFY_STAGE_TOOL}" | awk '{ print $1 }')" == \
        "${APPROVED_VERIFY_STAGE_SHA}" && \
   "$(sha256sum "${ADB_BIN}" | awk '{ print $1 }')" == "${ADB_BIN_SHA}" && \
   "$(sha256sum "${FASTBOOT_BIN}" | awk '{ print $1 }')" == \
        "${FASTBOOT_BIN_SHA}" ]] || {
    printf 'flash/stage/platform tooling changed during the device wait\n' >&2
    exit 1
}
printf 'private flash snapshot revalidated immediately before wipes\n'

# Wipe sizes come from the DEVICE, and are resolved before anything is written.
#
# erase_or_zero()'s fallback writes a zero image of exactly ${bytes} to a
# partition. It is the only destructive write in this script whose payload
# length comes purely from a source constant rather than from the artifact being
# written, and the header above records that this bootloader will happily start
# writing and run off the end of a partition. `fastboot getvar partition-size:`
# is the bootloader's own answer for the layout it is about to write into.
#
# userdata was in WIPE_PARTITIONS with no PARTITION_BYTES entry at all, so on an
# LK build without `erase` the run aborted on the FIRST wipe -- after the
# incomplete-receipt journal had been created, and that journal then refused
# every later run. Resolving every size here, before the journal exists, makes
# an unresolvable size an ordinary clean refusal.
#
# The table stays as a cross-check. It is documented as verified against the
# live GPT, so a device answer that disagrees with it means one of the two
# describes a different layout, and neither may size a destructive write.
# MEASURED, and do not "correct" it: this bootloader reports userdata as
# 0xce46fbe00 = 55,372,135,936 bytes, exactly 1 MiB LESS than the 55,373,184,512
# GPT size in notes/hardware-verification.md. Both are right about different
# things -- the GPT entry spans the partition, the bootloader answers for the
# region it will write into. The smaller number is the safe one for a zero-fill
# and is the one used. There is deliberately no userdata entry in the table
# above; adding the GPT figure there would make the cross-check below refuse
# every flash.
declare -A RESOLVED_PARTITION_BYTES=()
declare -A RESOLVED_PARTITION_SOURCE=()
partition_size_from_device() {
    local part="$1" getvar_out value
    getvar_out="$(fb getvar "partition-size:${part}" 2>&1)" || return 1
    # fastboot prints `partition-size:<name>: <value>`, some builds behind a
    # `(bootloader) ` prefix, followed by a `Finished.` line. Take the value
    # lines only and require exactly one; anything else is a format this cannot
    # verify, and an unverified length is not usable here.
    value="$(awk -v key="partition-size:${part}:" '
        {
            line = $0
            sub(/^\(bootloader\)[[:space:]]*/, "", line)
            if (index(line, key) == 1) {
                v = substr(line, length(key) + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                print v
            }
        }' <<<"${getvar_out}")"
    [[ "$(grep -c . <<<"${value}")" -eq 1 ]] || return 1
    # ALWAYS hex, prefix or not. This is fastboot's own rule, not an inference:
    # system/core/fastboot/fastboot.cpp:1439-1446 fb_fix_numeric_var() prepends
    # "0x" to any value that lacks it, with the comment "Some bootloaders
    # (hammerhead, for example) use implicit hex. This code used to use strtol
    # with base 16."
    #
    # An earlier version of this function also accepted a bare decimal, which is
    # worse than merely failing on this bootloader -- it silently mis-sizes a
    # destructive write. This LK reports metadata as `2000000`, which is a valid
    # decimal AND a valid hex string: as decimal it is 2,000,000 bytes, as hex it
    # is the real 33,554,432. A zero-flash sized from the decimal reading would
    # have cleared 6% of the partition and reported success.
    value="${value#0[xX]}"
    [[ "${value}" =~ ^[0-9a-fA-F]{1,16}$ ]] || return 1
    printf '%d\n' "$(( 16#${value} ))"
}
printf '\n== resolving wipe partition sizes from the bootloader ==\n'
for part in "${WIPE_PARTITIONS[@]}"; do
    table_bytes="${PARTITION_BYTES[${part}]:-}"
    if device_bytes="$(partition_size_from_device "${part}")" && \
       [[ "${device_bytes}" =~ ^[0-9]+$ && "${device_bytes}" -gt 0 && \
          $(( device_bytes % 512 )) -eq 0 ]]; then
        if [[ -n "${table_bytes}" && "${device_bytes}" -ne "${table_bytes}" ]]; then
            printf 'refusing to flash: the bootloader reports %s as %d bytes and the table verified against the live GPT says %d; one of them describes a different layout\n' \
                "${part}" "${device_bytes}" "${table_bytes}" >&2
            exit 1
        fi
        RESOLVED_PARTITION_BYTES["${part}"]="${device_bytes}"
        RESOLVED_PARTITION_SOURCE["${part}"]=bootloader
        printf '  %-9s %12d bytes (bootloader)\n' "${part}" "${device_bytes}"
    elif [[ -n "${table_bytes}" ]]; then
        printf 'WARNING: cannot read a usable partition-size:%s from the bootloader.\n' "${part}" >&2
        printf 'WARNING: falling back to the %d-byte table entry. If %s has to be\n' \
            "${table_bytes}" "${part}" >&2
        printf 'WARNING: zero-flashed, its payload length will come from a source\n' >&2
        printf 'WARNING: constant rather than from the device.\n' >&2
        RESOLVED_PARTITION_BYTES["${part}"]="${table_bytes}"
        RESOLVED_PARTITION_SOURCE["${part}"]=table
        printf '  %-9s %12d bytes (table, UNVERIFIED against this device)\n' \
            "${part}" "${table_bytes}"
    else
        printf 'refusing to flash: cannot read partition-size:%s from the bootloader and no table entry exists for it\n' \
            "${part}" >&2
        exit 1
    fi
done

erase_or_zero() {
    local part="$1"
    if fb erase "${part}"; then
        LAST_WIPE_METHOD=erase
        return 0
    fi
    # Some MTK LK builds implement flash but not erase. Fall back to writing a
    # zero image of the exact partition size, which is what erase would leave.
    local bytes="${RESOLVED_PARTITION_BYTES[${part}]:-}"
    if [[ -z "${bytes}" ]]; then
        printf 'cannot erase %s and its size was never resolved; refusing to guess\n' "${part}" >&2
        return 1
    fi
    printf 'erase unsupported for %s; writing a %d-byte zero image instead (size from %s)\n' \
        "${part}" "${bytes}" "${RESOLVED_PARTITION_SOURCE[${part}]}"
    local zero
    zero="$(mktemp)"
    trap 'rm -f -- "${zero}"' RETURN
    head -c "${bytes}" /dev/zero >"${zero}"
    # A short zero image is a destructive write of the wrong length, which is
    # the same class of fault as an oversized one. head exits 0 on a full temp
    # filesystem, so check the bytes rather than the status.
    if [[ "$(stat -c %s "${zero}")" -ne "${bytes}" ]]; then
        printf 'could not stage a %d-byte zero image for %s; refusing to write a short one\n' \
            "${bytes}" "${part}" >&2
        return 1
    fi
    fb flash "${part}" "${zero}"
    LAST_WIPE_METHOD=zero-flash
}

FLASH_STARTED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
[[ "${FLASH_STARTED_AT_UTC}" =~ \
   ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
    printf 'cannot derive strict UTC flash-start timestamp\n' >&2
    exit 1
}
: >"${FLASH_RECEIPT_INCOMPLETE}"
chmod 0600 "${FLASH_RECEIPT_INCOMPLETE}"
flash_receipt_put() {
    local key="$1"
    local value="$2"
    [[ "${key}" =~ ^[a-z0-9_.]+$ && -n "${value}" && \
       "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] || {
        printf 'unsafe flash-receipt field: %s\n' "${key}" >&2
        return 1
    }
    printf '%s=%s\n' "${key}" "${value}" >>"${FLASH_RECEIPT_INCOMPLETE}"
}
flash_receipt_put flash_receipt.version 1
flash_receipt_put status.initial IN_PROGRESS
flash_receipt_put flash.started_at_utc "${FLASH_STARTED_AT_UTC}"
flash_receipt_put stage.source_path "${SOURCE_IMAGE_DIR}"
flash_receipt_put stage.contract_sha256 "${STAGE_CONTRACT_SHA}"
flash_receipt_put stage.source_manifest_sha256 "${SOURCE_MANIFEST_SHA}"
flash_receipt_put stage.build_receipt_sha256 "${BUILD_RECEIPT_SHA}"
flash_receipt_put stage.tier "${BUILD_TIER}"
flash_receipt_put stage.variant "${BUILD_VARIANT}"
flash_receipt_put stage.public_fingerprint "${PUBLIC_FINGERPRINT}"
flash_receipt_put stage.system_fingerprint "${SYSTEM_FINGERPRINT}"
flash_receipt_put stage.build_incremental "${BUILD_INCREMENTAL}"
flash_receipt_put device.fastboot_serial "${FB_SERIAL}"
flash_receipt_put device.bootloader_product "${product}"
flash_receipt_put tool.flash_tier_images_sha256 \
    "${APPROVED_FLASH_TOOL_SHA}"
flash_receipt_put tool.verify_stage_contract_sha256 \
    "${APPROVED_VERIFY_STAGE_SHA}"
flash_receipt_put host.adb_sha256 "${ADB_BIN_SHA}"
flash_receipt_put host.fastboot_sha256 "${FASTBOOT_BIN_SHA}"
flash_receipt_put host.fastboot_version "${FASTBOOT_VERSION}"
for part in "${WRITABLE_PARTITIONS[@]}"; do
    flash_receipt_put "image.${part}.sha256" \
        "$(stage_manifest_get "image.${part}.sha256")"
    flash_receipt_put "image.${part}.bytes" \
        "$(stage_manifest_get "image.${part}.bytes")"
done
# Which length each wipe was sized from, and whether the device or the table
# supplied it. A zero-flash writes exactly this many bytes.
for part in "${WIPE_PARTITIONS[@]}"; do
    flash_receipt_put "wipe.${part}.bytes" \
        "${RESOLVED_PARTITION_BYTES[${part}]}"
    flash_receipt_put "wipe.${part}.bytes_source" \
        "${RESOLVED_PARTITION_SOURCE[${part}]}"
done

for part in "${WIPE_PARTITIONS[@]}"; do
    printf '\n== wiping %s ==\n' "${part}"
    erase_or_zero "${part}"
    flash_receipt_put "operation.wipe.${part}" "success:${LAST_WIPE_METHOD}"
done

for part in "${WRITABLE_PARTITIONS[@]}"; do
    printf '\n== flashing %s ==\n' "${part}"
    fb flash "${part}" "${IMAGE_DIR}/${part}.img"
    flash_receipt_put "operation.flash.${part}" success
done

printf '\nall four images written and userdata/metadata/cache wiped\n'
printf 'first boot no longer runs cryptfs enablecrypto: userdata is unencrypted\n'
if [[ "${FLASH_REBOOT}" == 1 ]]; then
    fb reboot
    flash_receipt_put operation.reboot success
else
    flash_receipt_put operation.reboot deferred
    printf 'reboot deferred by K50SV1_FLASH_REBOOT=0; device remains in fastboot\n'
fi
FLASH_COMPLETED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
flash_receipt_put flash.completed_at_utc "${FLASH_COMPLETED_AT_UTC}"
flash_receipt_put status PASS
chmod 0644 "${FLASH_RECEIPT_INCOMPLETE}"
mv -T "${FLASH_RECEIPT_INCOMPLETE}" "${FLASH_RECEIPT}"
printf 'atomic flash receipt: %s (sha256=%s)\n' "${FLASH_RECEIPT}" \
    "$(sha256sum "${FLASH_RECEIPT}" | awk '{ print $1 }')"
