#!/usr/bin/env bash
# Atomically stage the four current product images behind the flash contract.

set -euo pipefail

usage() {
    printf 'Usage: %s <new-stage-directory>\n' "$0" >&2
    exit 2
}

die() {
    printf 'Image staging failed: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || usage

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
PRODUCT="k50sv1_64_bsp"
PRODUCT_OUT="${LINEAGE_ROOT}/out/target/product/${PRODUCT}"
SIMG2IMG="${LINEAGE_ROOT}/out/host/linux-x86/bin/simg2img"
DEBUGFS="$(command -v debugfs || true)"
UPSTREAM_INPUT_TOOL="${TOOL_DIR}/apply-upstream-patches.sh"
CARRIER_CONFIG_TOOL="${TOOL_DIR}/check-carrier-config-overlay.py"
PIXEL_IDENTITY_TOOL="${TOOL_DIR}/check-pixel-identity.py"
LAUNCHER_POLICY_TOOL="${TOOL_DIR}/check-launcher-policy.py"
WFC_RESOURCE_TOOL="${TOOL_DIR}/check-wfc-framework-resource.sh"
VERIFY_STAGE_TOOL="${TOOL_DIR}/verify-stage-contract.sh"
VERIFY_POST_FLASH_TOOL="${TOOL_DIR}/verify-post-flash.sh"
BUILD_INPUT_TOOL="${TOOL_DIR}/capture-build-input-state.sh"
KERNEL_ABI_CHECK_TOOL="${TOOL_DIR}/kernel/check-module-abi.sh"
CONNECTIVITY_MODULES=(wmt_drv wmt_chrdev_wifi wlan_drv_gen2 bt_drv gps_drv)
KERNEL_MODULE_RECEIPT_KEYS=(
    kernel.module_mode kernel.module_install kernel.module_strip_tool_sha256
    kernel.module_signature kernel.module_invariant_errors
    kernel.undefined_symbols kernel.versioned_imports
    kernel.module_exports kernel.candidate_exports_ok
)
for kernel_module in "${CONNECTIVITY_MODULES[@]}"; do
    for kernel_field in path sha256 bytes installed_sha256 installed_bytes; do
        KERNEL_MODULE_RECEIPT_KEYS+=("kernel.module.${kernel_module}.${kernel_field}")
    done
done
KEYSET_PREPARE_TOOL="${TOOL_DIR}/prepare-tier3-keyset.sh"
TIER3_PROPERTY_VERIFY_TOOL="${TOOL_DIR}/verify-tier3-signed-properties.sh"
KEYSET_MANIFEST_VERIFY_TOOL="${TOOL_DIR}/verify-tier3-keyset-manifest.sh"
BUILD_RECEIPT_NAME="K50SV1-BUILD-RECEIPT"
BUILD_SOURCE_STATE_NAME="K50SV1-BUILD-SOURCE-STATE"
BUILD_REPO_MANIFEST_NAME="K50SV1-ANDROID-REPO-MANIFEST.xml"
RELEASE_KEYSET_NAME="K50SV1-RELEASE-KEYSET"
UNPACK_BOOTIMG="$(command -v unpack_bootimg || true)"
REQUESTED_BUILD_TIER="${K50SV1_BUILD_TIER:-}"
STAGE_SOURCE_DIR="${K50SV1_STAGE_SOURCE_DIR:-}"
DESTINATION="$1"
DESTINATION_PARENT="$(dirname "${DESTINATION}")"
DESTINATION_NAME="$(basename "${DESTINATION}")"

if [[ -n "${STAGE_SOURCE_DIR}" ]]; then
    PRODUCT_OUT="${STAGE_SOURCE_DIR}"
fi

[[ "${DESTINATION_NAME}" != "." && "${DESTINATION_NAME}" != ".." && \
   "${DESTINATION_NAME}" != "/" ]] || die "unsafe destination name"
[[ ! -e "${DESTINATION}" && ! -L "${DESTINATION}" ]] \
    || die "destination already exists: ${DESTINATION}"
[[ -d "${DESTINATION_PARENT}" && ! -L "${DESTINATION_PARENT}" ]] \
    || die "destination parent must be an existing ordinary directory"
[[ -d "${PRODUCT_OUT}" && ! -L "${PRODUCT_OUT}" ]] \
    || die "image source must be an existing ordinary directory: ${PRODUCT_OUT}"
PRODUCT_OUT="$(realpath -e "${PRODUCT_OUT}")"
[[ -x "${SIMG2IMG}" ]] || die "missing host simg2img: ${SIMG2IMG}"
[[ -x "${DEBUGFS}" ]] || die "missing host debugfs"
[[ -x "${UPSTREAM_INPUT_TOOL}" ]] \
    || die "missing executable vendor/lineage preflight: ${UPSTREAM_INPUT_TOOL}"
[[ -x "${CARRIER_CONFIG_TOOL}" ]] \
    || die "missing executable CarrierConfig preflight: ${CARRIER_CONFIG_TOOL}"
[[ -x "${PIXEL_IDENTITY_TOOL}" ]] \
    || die "missing executable Pixel identity preflight: ${PIXEL_IDENTITY_TOOL}"
[[ -x "${BUILD_INPUT_TOOL}" ]] \
    || die "missing executable build-input capture tool: ${BUILD_INPUT_TOOL}"
[[ -x "${WFC_RESOURCE_TOOL}" ]] \
    || die "missing executable WFC framework-resource check: ${WFC_RESOURCE_TOOL}"
[[ -x "${VERIFY_STAGE_TOOL}" ]] \
    || die "missing executable stage-contract verifier: ${VERIFY_STAGE_TOOL}"
[[ -x "${VERIFY_POST_FLASH_TOOL}" ]] \
    || die "missing executable post-flash verifier: ${VERIFY_POST_FLASH_TOOL}"
[[ -x "${KEYSET_PREPARE_TOOL}" && \
   -x "${TIER3_PROPERTY_VERIFY_TOOL}" && \
   -x "${KEYSET_MANIFEST_VERIFY_TOOL}" ]] \
    || die "missing executable Tier-3 signing verifier"
[[ -x "${UNPACK_BOOTIMG}" ]] || die "missing host unpack_bootimg"

# Staging is a second trust boundary after the build. Refuse to describe a
# source state whose two deliberate upstream changes have already drifted.
"${UPSTREAM_INPUT_TOOL}" --check \
    || die "vendor/lineage inputs no longer match the build preflight"
"${CARRIER_CONFIG_TOOL}" \
    || die "carrier-specific IMS configuration no longer matches its matrix"
"${PIXEL_IDENTITY_TOOL}" \
    || die "public Pixel identity no longer preserves the MTK build boundary"
"${WFC_RESOURCE_TOOL}" \
    || die "source diagnostic/Tier-3 WFC framework gates have drifted"

DESTINATION_PARENT="$(realpath -e "${DESTINATION_PARENT}")"
DESTINATION="${DESTINATION_PARENT}/${DESTINATION_NAME}"
mkdir -- "${DESTINATION}" \
    || die "could not reserve new destination: ${DESTINATION}"
complete=false
FINAL_SOURCE_TMP=""
cleanup() {
    if [[ "${complete:-false}" != true && -d "${DESTINATION:-}" ]]; then
        find "${DESTINATION}" -mindepth 1 -depth -delete
        rmdir "${DESTINATION}"
    fi
    if [[ -n "${FINAL_SOURCE_TMP:-}" && -d "${FINAL_SOURCE_TMP}" && \
          ! -L "${FINAL_SOURCE_TMP}" && \
          "${FINAL_SOURCE_TMP}" == /tmp/k50-stage-source.* ]]; then
        find "${FINAL_SOURCE_TMP}" -mindepth 1 -depth -delete 2>/dev/null || true
        rmdir "${FINAL_SOURCE_TMP}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

PROVENANCE_TMP="${DESTINATION}/.provenance.incomplete"
mkdir -m 0700 -- "${PROVENANCE_TMP}"

file_sha256() {
    local file="$1"
    local digest

    [[ -f "${file}" && ! -L "${file}" && -r "${file}" ]] \
        || die "cannot hash missing, unreadable, or symlinked provenance input: ${file}"
    if ! digest="$(sha256sum -- "${file}" | awk '{ print $1 }')" || \
       [[ ! "${digest}" =~ ^[0-9a-f]{64}$ ]]; then
        die "cannot derive SHA-256 for provenance input: ${file}"
    fi
    printf '%s' "${digest}"
}

manifest_get_exact() {
    local key="$1"
    local manifest="$2"
    local value

    if ! value="$(awk -v key="${key}" '
            index($0, key "=") == 1 {
                count++
                value = substr($0, length(key) + 2)
            }
            END {
                if (count != 1 || value == "") exit 1
                print value
            }
        ' "${manifest}")"; then
        die "manifest does not contain exactly one non-empty ${key}: ${manifest}"
    fi
    [[ "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] \
        || die "manifest field ${key} is unsafe"
    printf '%s' "${value}"
}

# A successful build receipt, not an ambient tier variable or mutable out/
# timestamp, is the authority for these bytes. It binds the clean pre-build
# source snapshot, the pinned repo manifest and all four image hashes.
BUILD_RECEIPT_SOURCE="${PRODUCT_OUT}/${BUILD_RECEIPT_NAME}"
BUILD_SOURCE_STATE_SOURCE="${PRODUCT_OUT}/${BUILD_SOURCE_STATE_NAME}"
BUILD_REPO_MANIFEST_SOURCE="${PRODUCT_OUT}/${BUILD_REPO_MANIFEST_NAME}"
for receipt_input in \
    "${BUILD_RECEIPT_SOURCE}" \
    "${BUILD_SOURCE_STATE_SOURCE}" \
    "${BUILD_REPO_MANIFEST_SOURCE}"; do
    [[ -f "${receipt_input}" && ! -L "${receipt_input}" && -s "${receipt_input}" ]] \
        || die "missing, empty, or symlinked clean-build receipt input: ${receipt_input}"
done

EXPECTED_RECEIPT_KEYS=(
    receipt.version product tier variant pipeline build.targets
    build.clean_output build.started_at_utc build.completed_at_utc
    build.real_fingerprint build.incremental
    source_state.file source_state.sha256
    android_repo_manifest.file android_repo_manifest.sha256
    release_keyset.file release_keyset.sha256
    tool.capture_build_inputs_sha256 tool.run_lineage_build_sha256
    tool.stage_tier_images_sha256 tool.check_wfc_framework_resource_sha256
    tool.prepare_tier3_keyset_sha256 tool.verify_tier3_properties_sha256
    tool.verify_tier3_keyset_manifest_sha256
    kernel.image_gz.path kernel.image_gz.sha256 kernel.image_gz.bytes
    kernel.config.path kernel.config.sha256 kernel.config.bytes
    kernel.module_symvers.path kernel.module_symvers.sha256
    kernel.module_symvers.bytes kernel.vmlinux.path kernel.vmlinux.sha256
    kernel.vmlinux.bytes kernel.mode kernel.image_name kernel.abi.status
    kernel.abi.metadata_errors kernel.abi.module_signature_compatible
    kernel.uts_release kernel.vermagic
    kernel.module_layout kernel.module_layout_vmlinux kernel.modules
    "${KERNEL_MODULE_RECEIPT_KEYS[@]}"
    kernel.expected_pairs kernel.builtin_expected kernel.inter_module_expected
    kernel.module_inter_ok kernel.candidate_builtin_ok kernel.candidate_inter_ok
    tool.check_module_abi_sha256
    image.boot.sha256 image.boot.bytes
    image.recovery.sha256 image.recovery.bytes
    image.system.sha256 image.system.bytes
    image.vendor.sha256 image.vendor.bytes
)
receipt_records="$(awk 'NF { count++ } END { print count + 0 }' \
    "${BUILD_RECEIPT_SOURCE}")"
[[ "${receipt_records}" -eq "${#EXPECTED_RECEIPT_KEYS[@]}" ]] \
    || die "build receipt has ${receipt_records} records; expected ${#EXPECTED_RECEIPT_KEYS[@]}"
declare -A RECEIPT=()
for receipt_key in "${EXPECTED_RECEIPT_KEYS[@]}"; do
    RECEIPT[${receipt_key}]="$(manifest_get_exact \
        "${receipt_key}" "${BUILD_RECEIPT_SOURCE}")"
done

[[ "${RECEIPT[receipt.version]}" == 4 && \
   "${RECEIPT[product]}" == "${PRODUCT}" && \
   "${RECEIPT[build.clean_output]}" == true ]] \
    || die "build receipt is not a clean ${PRODUCT} receipt"
[[ "${RECEIPT[build.real_fingerprint]}" =~ \
   ^XSH/lineage_k50sv1_64_bsp/k50sv1_64_bsp:10/QQ3A\.200805\.001/[0-9A-Za-z._-]+:(userdebug|user)/(test-keys|release-keys)$ && \
   "${RECEIPT[build.incremental]}" =~ ^[0-9A-Za-z._-]+$ ]] \
    || die "build receipt has invalid generated identity metadata"
BUILD_TIER="${RECEIPT[tier]}"
BUILD_VARIANT="${RECEIPT[variant]}"
case "${BUILD_TIER}" in
    1 | 2)
        [[ "${BUILD_VARIANT}" == userdebug && \
           "${RECEIPT[pipeline]}" == android-four-image && \
           "${RECEIPT[build.targets]}" == \
               bootimage,recoveryimage,systemimage,vendorimage ]] \
            || die "Tier ${BUILD_TIER} receipt has the wrong variant/pipeline/targets"
        [[ -z "${STAGE_SOURCE_DIR}" ]] \
            || die "K50SV1_STAGE_SOURCE_DIR is reserved for a Tier-3 receipt"
        [[ "${RECEIPT[release_keyset.file]}" == none && \
           "${RECEIPT[release_keyset.sha256]}" == none ]] \
            || die "diagnostic receipt unexpectedly names a release keyset"
        ;;
    3)
        [[ "${BUILD_VARIANT}" == user && \
           "${RECEIPT[pipeline]}" == tier3-signed-target-files && \
           "${RECEIPT[build.targets]}" == \
               target-files-package,sign-target-files,boot,recovery,system,vendor ]] \
            || die "Tier 3 receipt has the wrong variant/pipeline/targets"
        [[ -n "${STAGE_SOURCE_DIR}" ]] \
            || die "Tier 3 receipt requires the signing pipeline's explicit source directory"
        [[ "${RECEIPT[release_keyset.file]}" == "${RELEASE_KEYSET_NAME}" && \
           "${RECEIPT[release_keyset.sha256]}" =~ ^[0-9a-f]{64}$ && \
           -f "${PRODUCT_OUT}/${RELEASE_KEYSET_NAME}" && \
           ! -L "${PRODUCT_OUT}/${RELEASE_KEYSET_NAME}" && \
           -s "${PRODUCT_OUT}/${RELEASE_KEYSET_NAME}" && \
           "$(file_sha256 "${PRODUCT_OUT}/${RELEASE_KEYSET_NAME}")" == \
                "${RECEIPT[release_keyset.sha256]}" ]] \
            || die "Tier 3 receipt does not bind its public release keyset"
        # The manifest's own shape is verified once, by verify-stage-contract.sh
        # against the completed bundle. Repeating it here and in the build only
        # re-reads the same bytes with the same tool.
        ;;
    *) die "build receipt has invalid tier ${BUILD_TIER}" ;;
esac
if [[ -n "${REQUESTED_BUILD_TIER}" && \
      "${REQUESTED_BUILD_TIER}" != "${BUILD_TIER}" ]]; then
    die "requested Tier ${REQUESTED_BUILD_TIER} disagrees with receipt Tier ${BUILD_TIER}"
fi
[[ "${RECEIPT[source_state.file]}" == "${BUILD_SOURCE_STATE_NAME}" && \
   "${RECEIPT[android_repo_manifest.file]}" == "${BUILD_REPO_MANIFEST_NAME}" ]] \
    || die "build receipt names unexpected source artifacts"
for receipt_time_key in build.started_at_utc build.completed_at_utc; do
    [[ "${RECEIPT[${receipt_time_key}]}" =~ \
       ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || die "build receipt has invalid ${receipt_time_key}"
done
[[ "${RECEIPT[build.started_at_utc]}" < \
   "${RECEIPT[build.completed_at_utc]}" || \
   "${RECEIPT[build.started_at_utc]}" == \
   "${RECEIPT[build.completed_at_utc]}" ]] \
    || die "build receipt completion precedes its start"

[[ "$(file_sha256 "${BUILD_SOURCE_STATE_SOURCE}")" == \
   "${RECEIPT[source_state.sha256]}" ]] \
    || die "build source-state digest disagrees with its receipt"
[[ "$(file_sha256 "${BUILD_REPO_MANIFEST_SOURCE}")" == \
   "${RECEIPT[android_repo_manifest.sha256]}" ]] \
    || die "Android repo-manifest digest disagrees with its receipt"
[[ "$(manifest_get_exact android_repo.revision_manifest_sha256 \
        "${BUILD_SOURCE_STATE_SOURCE}")" == \
   "${RECEIPT[android_repo_manifest.sha256]}" ]] \
    || die "build source state does not bind the pinned Android repo manifest"
[[ "$(manifest_get_exact source_state.version \
        "${BUILD_SOURCE_STATE_SOURCE}")" == 4 ]] \
    || die "build source state does not carry the seven-repository provenance schema"

declare -A EXPECTED_KERNEL_RECEIPT_VALUE=(
    [kernel.mode]=source
    [kernel.image_name]=Image.gz
    [kernel.abi.status]=PASS
    [kernel.abi.metadata_errors]=0
    [kernel.abi.module_signature_compatible]=yes
    [kernel.image_gz.path]=arch/arm64/boot/Image.gz
    [kernel.config.path]=.config
    [kernel.module_symvers.path]=Module.symvers
    [kernel.vmlinux.path]=vmlinux
    [kernel.uts_release]=3.18.119
    [kernel.vermagic]='3.18.119 SMP preempt mod_unload modversions aarch64'
    [kernel.modules]=5
)
for kernel_key in "${!EXPECTED_KERNEL_RECEIPT_VALUE[@]}"; do
    [[ "${RECEIPT[${kernel_key}]}" == \
       "${EXPECTED_KERNEL_RECEIPT_VALUE[${kernel_key}]}" ]] \
        || die "build receipt has invalid source-kernel constant ${kernel_key}"
done
for kernel_artifact in image_gz config module_symvers vmlinux; do
    [[ "${RECEIPT[kernel.${kernel_artifact}.sha256]}" =~ ^[0-9a-f]{64}$ && \
       "${RECEIPT[kernel.${kernel_artifact}.bytes]}" =~ ^[0-9]+$ && \
       "${RECEIPT[kernel.${kernel_artifact}.bytes]}" -gt 0 ]] \
        || die "build receipt has invalid ${kernel_artifact} source metadata"
done
[[ "${RECEIPT[tool.check_module_abi_sha256]}" =~ ^[0-9a-f]{64}$ && \
   "$(file_sha256 "${KERNEL_ABI_CHECK_TOOL}")" == \
       "${RECEIPT[tool.check_module_abi_sha256]}" ]] \
    || die "source-kernel ABI checker differs from the build-receipt authority"
"${KERNEL_ABI_CHECK_TOOL}" --verify-contract "${BUILD_RECEIPT_SOURCE}" >/dev/null \
    || die "source-module receipt does not describe a complete ABI inventory"
# verify-post-flash.sh is deliberately NOT in this list. A verifier is not an
# input to the bytes it verifies, and binding it here meant a verifier bug could
# only be fixed by a 35-minute rebuild -- twice in one session the project
# instead restored the known-buggy verifier so the digest would match, and ran
# that (E-142, E-143). Everything that produces the bytes, gates their content,
# or writes them to the device is still bound.
declare -A APPROVED_TOOL_PATH=(
    [apply]="${TOOL_DIR}/apply-upstream-patches.sh"
    [capture]="${BUILD_INPUT_TOOL}"
    [build]="${TOOL_DIR}/run-lineage-build.sh"
    [carrier]="${TOOL_DIR}/check-carrier-config-overlay.py"
    [pixel]="${TOOL_DIR}/check-pixel-identity.py"
    [launcher_policy]="${LAUNCHER_POLICY_TOOL}"
    [wfc_resource]="${WFC_RESOURCE_TOOL}"
    [keyset_prepare]="${KEYSET_PREPARE_TOOL}"
    [tier3_properties]="${TIER3_PROPERTY_VERIFY_TOOL}"
    [keyset_manifest]="${KEYSET_MANIFEST_VERIFY_TOOL}"
    [kernel_abi]="${KERNEL_ABI_CHECK_TOOL}"
    [verify_stage]="${VERIFY_STAGE_TOOL}"
    [stage]="${TOOL_DIR}/stage-tier-images.sh"
    [flash]="${TOOL_DIR}/flash-tier-images.sh"
)
declare -A APPROVED_TOOL_SHA=()
APPROVED_TOOL_SHA[capture]="${RECEIPT[tool.capture_build_inputs_sha256]}"
APPROVED_TOOL_SHA[build]="${RECEIPT[tool.run_lineage_build_sha256]}"
APPROVED_TOOL_SHA[stage]="${RECEIPT[tool.stage_tier_images_sha256]}"
APPROVED_TOOL_SHA[wfc_resource]="${RECEIPT[tool.check_wfc_framework_resource_sha256]}"
APPROVED_TOOL_SHA[keyset_prepare]="${RECEIPT[tool.prepare_tier3_keyset_sha256]}"
APPROVED_TOOL_SHA[tier3_properties]="${RECEIPT[tool.verify_tier3_properties_sha256]}"
APPROVED_TOOL_SHA[keyset_manifest]="${RECEIPT[tool.verify_tier3_keyset_manifest_sha256]}"
APPROVED_TOOL_SHA[kernel_abi]="${RECEIPT[tool.check_module_abi_sha256]}"
for tool_label in "${!APPROVED_TOOL_PATH[@]}"; do
    if [[ -z "${APPROVED_TOOL_SHA[${tool_label}]:-}" ]]; then
        APPROVED_TOOL_SHA[${tool_label}]="$(file_sha256 \
            "${APPROVED_TOOL_PATH[${tool_label}]}")"
    fi
done
verify_approved_tools() {
    local tool_label
    for tool_label in "${!APPROVED_TOOL_PATH[@]}"; do
        [[ "$(file_sha256 "${APPROVED_TOOL_PATH[${tool_label}]}")" == \
           "${APPROVED_TOOL_SHA[${tool_label}]}" ]] \
            || die "approved ${tool_label} tool changed during build/staging"
    done
}
verify_approved_tools

CURRENT_SOURCE_STATE="${PROVENANCE_TMP}/current-source-state"
CURRENT_REPO_MANIFEST="${PROVENANCE_TMP}/current-repo-manifest.xml"
"${BUILD_INPUT_TOOL}" --repo-manifest "${CURRENT_REPO_MANIFEST}" \
    >"${CURRENT_SOURCE_STATE}" \
    || die "cannot recapture source state at staging time"
cmp -s "${BUILD_SOURCE_STATE_SOURCE}" "${CURRENT_SOURCE_STATE}" \
    || die "source state changed after the successful build"
cmp -s "${BUILD_REPO_MANIFEST_SOURCE}" "${CURRENT_REPO_MANIFEST}" \
    || die "Android repo revisions changed after the successful build"

declare -A RECEIPT_IMAGE_SHA=()
declare -A RECEIPT_IMAGE_BYTES=()
for image in boot recovery system vendor; do
    RECEIPT_IMAGE_SHA[${image}]="${RECEIPT[image.${image}.sha256]}"
    RECEIPT_IMAGE_BYTES[${image}]="${RECEIPT[image.${image}.bytes]}"
    [[ "${RECEIPT_IMAGE_SHA[${image}]}" =~ ^[0-9a-f]{64}$ && \
       "${RECEIPT_IMAGE_BYTES[${image}]}" =~ ^[0-9]+$ && \
       "${RECEIPT_IMAGE_BYTES[${image}]}" -gt 0 ]] \
        || die "build receipt has invalid ${image}.img metadata"
done

declare -A partition_bytes=(
    [boot]=16777216
    [recovery]=16777216
    [system]=4294967296
    [vendor]=2147483648
)

for image in boot recovery system vendor; do
    source_image="${PRODUCT_OUT}/${image}.img"
    staged_image="${DESTINATION}/${image}.img"
    [[ -f "${source_image}" && ! -L "${source_image}" && -s "${source_image}" ]] \
        || die "missing, empty, or symlinked product image: ${source_image}"
    size="$(stat -c %s "${source_image}")"
    [[ "${size}" == "${RECEIPT_IMAGE_BYTES[${image}]}" ]] \
        || die "${image}.img size disagrees with the successful build receipt"
    [[ "$(file_sha256 "${source_image}")" == \
       "${RECEIPT_IMAGE_SHA[${image}]}" ]] \
        || die "${image}.img digest disagrees with the successful build receipt"
    (( size <= partition_bytes[${image}] )) \
        || die "${image}.img exceeds its partition (${size} > ${partition_bytes[${image}]})"
    cp --reflink=auto -- "${source_image}" "${staged_image}"
    chmod 0644 "${staged_image}"
    [[ -f "${staged_image}" && ! -L "${staged_image}" && \
       "$(stat -c %h "${staged_image}")" -eq 1 ]] \
        || die "staged ${image}.img is not an independent ordinary file"
    cmp -s "${source_image}" "${staged_image}" \
        || die "staged ${image}.img differs from product output"
    [[ "$(file_sha256 "${staged_image}")" == \
       "${RECEIPT_IMAGE_SHA[${image}]}" ]] \
        || die "staged ${image}.img digest disagrees with the build receipt"
done

# boot/recovery are as destructive as the sparse partitions. Parse both and
# prove that they embed the ABI-gated source Image.gz while retaining the sole
# committed stock DT table and exact recovery-DTBO. This validates only; no
# DTBO partition is added to the flash set.
STOCK_PREBUILT_DIR="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp/prebuilt"
STOCK_DTB_DIR="${STOCK_PREBUILT_DIR}/dtb"
STOCK_DTB="${STOCK_DTB_DIR}/stock.dtb"
STOCK_RECOVERY_DTBO="${STOCK_PREBUILT_DIR}/recovery_dtbo"
EXPECTED_STOCK_DTB_SHA=3bf76b640714efc8df9547c5a10f71b3623e4c9c7f01e145ff8cb3cc1b1e2907
EXPECTED_STOCK_DTB_BYTES=68438
EXPECTED_STOCK_RECOVERY_DTBO_SHA=21c8f45333222c3dd4adcd18f91178492de6fe28512eb009f47891d30c3d2db6
EXPECTED_STOCK_RECOVERY_DTBO_BYTES=39063
[[ -d "${STOCK_DTB_DIR}" && ! -L "${STOCK_DTB_DIR}" ]] \
    || die "stock DT authority is not an ordinary directory"
stock_dtb_entries=()
while IFS= read -r -d '' stock_dtb_entry; do
    stock_dtb_entries+=("${stock_dtb_entry}")
done < <(find "${STOCK_DTB_DIR}" -mindepth 1 -maxdepth 1 -print0)
[[ "${#stock_dtb_entries[@]}" -eq 1 && \
   "${stock_dtb_entries[0]}" == "${STOCK_DTB}" && \
   -f "${STOCK_DTB}" && ! -L "${STOCK_DTB}" && -s "${STOCK_DTB}" ]] \
    || die "stock DT authority must contain only one ordinary stock.dtb"
for authority in "${STOCK_DTB}" "${STOCK_RECOVERY_DTBO}"; do
    [[ -f "${authority}" && ! -L "${authority}" && -s "${authority}" ]] \
        || die "missing stock boot authority: ${authority}"
done
[[ "$(file_sha256 "${STOCK_DTB}")" == "${EXPECTED_STOCK_DTB_SHA}" && \
   "$(stat -c %s "${STOCK_DTB}")" == "${EXPECTED_STOCK_DTB_BYTES}" && \
   "$(file_sha256 "${STOCK_RECOVERY_DTBO}")" == \
       "${EXPECTED_STOCK_RECOVERY_DTBO_SHA}" && \
   "$(stat -c %s "${STOCK_RECOVERY_DTBO}")" == \
       "${EXPECTED_STOCK_RECOVERY_DTBO_BYTES}" ]] \
    || die "committed stock DT/recovery-DTBO authority changed"
declare -A BOOT_PAYLOAD_SHA=()
declare -A BOOT_PAYLOAD_BYTES=()
for image in boot recovery; do
    unpack_dir="${PROVENANCE_TMP}/${image}-unpacked"
    unpack_info="${PROVENANCE_TMP}/${image}-unpack-info.txt"
    mkdir -- "${unpack_dir}"
    "${UNPACK_BOOTIMG}" --boot_img "${DESTINATION}/${image}.img" \
        --out "${unpack_dir}" --format info >"${unpack_info}" \
        || die "unpack_bootimg rejected ${image}.img"
    for payload in kernel ramdisk dtb; do
        [[ -f "${unpack_dir}/${payload}" && ! -L "${unpack_dir}/${payload}" && \
           -s "${unpack_dir}/${payload}" ]] \
            || die "${image}.img has no complete ${payload} payload"
        BOOT_PAYLOAD_SHA[${image}.${payload}]="$(file_sha256 \
            "${unpack_dir}/${payload}")"
        BOOT_PAYLOAD_BYTES[${image}.${payload}]="$(stat -c %s \
            "${unpack_dir}/${payload}")"
    done
    [[ "${BOOT_PAYLOAD_SHA[${image}.kernel]}" == \
           "${RECEIPT[kernel.image_gz.sha256]}" && \
       "${BOOT_PAYLOAD_BYTES[${image}.kernel]}" == \
           "${RECEIPT[kernel.image_gz.bytes]}" ]] \
        || die "${image}.img does not contain the ABI-gated source Image.gz"
    cmp -s "${unpack_dir}/dtb" "${STOCK_DTB}" \
        || die "${image}.img does not contain the pinned stock DTB"
    grep -Fxq 'boot magic: ANDROID!' "${unpack_info}" \
        || die "${image}.img has no Android boot magic"
    grep -Fxq 'page size: 2048' "${unpack_info}" \
        || die "${image}.img has an unexpected boot page size"
    grep -Fxq 'os version: 10.0.0' "${unpack_info}" \
        || die "${image}.img is not an Android 10 boot image"
    grep -Fxq 'boot image header version: 2' "${unpack_info}" \
        || die "${image}.img has an unexpected boot header version"
    ! grep -Eq '(^|[[:space:]])module\.sig_enforce=1([[:space:]]|$)' \
        "${unpack_info}" \
        || die "${image}.img would reject the unsigned connectivity modules"
    expected_buildvariant="buildvariant=${BUILD_VARIANT}"
    [[ "$(grep -Eo '(^|[[:space:]])buildvariant=[^[:space:]]+' \
            "${unpack_info}" | sed 's/^[[:space:]]//' | grep -Fxc \
            "${expected_buildvariant}" || true)" -eq 1 ]] \
        || die "${image}.img cmdline does not carry exactly ${expected_buildvariant}"
    selinux_tokens="$(grep -Eo '(^|[[:space:]])androidboot\.selinux=[^[:space:]]+' \
        "${unpack_info}" | sed 's/^[[:space:]]//' || true)"
    if [[ "${BUILD_TIER}" == 1 ]]; then
        [[ "$(grep -Fxc 'androidboot.selinux=permissive' \
                <<<"${selinux_tokens}" || true)" -eq 1 && \
           "$(awk 'NF { count++ } END { print count + 0 }' \
                <<<"${selinux_tokens}")" -eq 1 ]] \
            || die "Tier 1 ${image}.img is not exactly permissive"
    elif [[ -n "${selinux_tokens}" ]]; then
        die "Tier ${BUILD_TIER} ${image}.img carries a forbidden SELinux cmdline override"
    fi
    if [[ "${image}" == recovery ]]; then
        [[ -f "${unpack_dir}/recovery_dtbo" && \
           ! -L "${unpack_dir}/recovery_dtbo" && \
           -s "${unpack_dir}/recovery_dtbo" ]] \
            || die "recovery.img has no recovery-DTBO payload"
        cmp -s "${unpack_dir}/recovery_dtbo" \
            "${STOCK_RECOVERY_DTBO}" \
            || die "recovery.img does not contain the pinned stock recovery DTBO"
        BOOT_PAYLOAD_SHA[recovery.recovery_dtbo]="$(file_sha256 \
            "${unpack_dir}/recovery_dtbo")"
        BOOT_PAYLOAD_BYTES[recovery.recovery_dtbo]="$(stat -c %s \
            "${unpack_dir}/recovery_dtbo")"
    elif [[ -e "${unpack_dir}/recovery_dtbo" || \
            -L "${unpack_dir}/recovery_dtbo" ]]; then
        die "boot.img unexpectedly contains a recovery-DTBO payload"
    fi
done
cmp -s "${PROVENANCE_TMP}/boot-unpacked/kernel" \
    "${PROVENANCE_TMP}/recovery-unpacked/kernel" \
    || die "boot.img and recovery.img contain different source kernels"
cmp -s "${PROVENANCE_TMP}/boot-unpacked/dtb" \
    "${PROVENANCE_TMP}/recovery-unpacked/dtb" \
    || die "boot.img and recovery.img contain different stock DT tables"

for image in system vendor; do
    read -r block_size block_count < <(
        od -An -tu4 -j12 -N8 "${DESTINATION}/${image}.img"
    )
    [[ "${block_size}" -eq 4096 ]] \
        || die "${image}.img has unexpected sparse block size: ${block_size}"
    expanded_size=$((block_size * block_count))
    (( expanded_size <= partition_bytes[${image}] )) \
        || die "${image}.img expands past its partition (${expanded_size} > ${partition_bytes[${image}]})"
    "${SIMG2IMG}" "${DESTINATION}/${image}.img" /dev/null \
        || die "${image}.img sparse structure is invalid"
done

read_image_property() {
    local property="$1"
    local property_file="$2"
    local value

    if ! value="$({
        awk -v property="${property}" '
            index($0, property "=") == 1 {
                count++
                print substr($0, length(property) + 2)
            }
            END { if (count != 1) exit 1 }
        ' "${property_file}"
    })"; then
        die "system image does not contain exactly one ${property} property"
    fi
    if [[ -z "${value}" || "${value}" == *$'\n'* || \
          ! "${value}" =~ ^[[:print:]]+$ ]]; then
        die "system image property ${property} is empty or unsafe for the source manifest"
    fi
    printf '%s' "${value}"
}

# Device product.prop is appended after buildinfo_common's structural product
# values. Android init deliberately resolves repeated keys last-wins while it
# builds its boot property map; mirror that only for the five public product
# identity keys. All structural/system identity checks above remain exact-one.
read_image_property_last() {
    local property="$1"
    local property_file="$2"
    local value

    if ! value="$(awk -v property="${property}" '
            index($0, property "=") == 1 {
                count++
                value = substr($0, length(property) + 2)
            }
            END {
                if (count < 1) exit 1
                print value
            }
        ' "${property_file}")"; then
        die "product image contains no ${property} property"
    fi
    [[ -n "${value}" && "${value}" != *$'\n'* && \
       "${value}" =~ ^[[:print:]]+$ ]] \
        || die "product image property ${property} is empty or unsafe"
    printf '%s' "${value}"
}

# Read identity from the staged filesystem itself. The loose product-output
# build.prop can be newer than system.img after an interrupted incremental
# build, so it is not accepted as evidence about these four bytes.
SYSTEM_RAW="${PROVENANCE_TMP}/system.raw"
SYSTEM_BUILD_PROP="${PROVENANCE_TMP}/system-build.prop"
PRODUCT_BUILD_PROP="${PROVENANCE_TMP}/product-build.prop"
FRAMEWORK_RES_APK="${PROVENANCE_TMP}/framework-res.apk"
PRODUCT_APNS="${PROVENANCE_TMP}/product-apns-conf.xml"
SYSTEM_DEBUGFS_LOG="${PROVENANCE_TMP}/system-debugfs.log"
VENDOR_RAW="${PROVENANCE_TMP}/vendor.raw"
VENDOR_BUILD_PROP="${PROVENANCE_TMP}/vendor-build.prop"
VENDOR_DEBUGFS_LOG="${PROVENANCE_TMP}/vendor-debugfs.log"
"${SIMG2IMG}" "${DESTINATION}/system.img" "${SYSTEM_RAW}" \
    || die "cannot expand staged system.img for build identity extraction"
[[ -f "${SYSTEM_RAW}" && ! -L "${SYSTEM_RAW}" && -s "${SYSTEM_RAW}" ]] \
    || die "expanded staged system image is not an ordinary non-empty file"
if ! "${DEBUGFS}" -R 'cat /system/build.prop' "${SYSTEM_RAW}" \
        >"${SYSTEM_BUILD_PROP}" 2>"${SYSTEM_DEBUGFS_LOG}"; then
    die "debugfs cannot extract /system/build.prop from staged system.img"
fi
[[ -s "${SYSTEM_BUILD_PROP}" ]] \
    || die "staged system.img contains no readable /system/build.prop"
if ! "${DEBUGFS}" -R 'cat /system/product/build.prop' "${SYSTEM_RAW}" \
        >"${PRODUCT_BUILD_PROP}" 2>>"${SYSTEM_DEBUGFS_LOG}"; then
    die "debugfs cannot extract /system/product/build.prop from staged system.img"
fi
[[ -s "${PRODUCT_BUILD_PROP}" ]] \
    || die "staged system.img contains no readable /system/product/build.prop"
if ! "${DEBUGFS}" -R \
        "dump /system/framework/framework-res.apk ${FRAMEWORK_RES_APK}" \
        "${SYSTEM_RAW}" >/dev/null 2>>"${SYSTEM_DEBUGFS_LOG}"; then
    die "debugfs cannot extract framework-res.apk from staged system.img"
fi
WFC_EXPECTED_VALUE=true
[[ "${BUILD_TIER}" == 3 ]] && WFC_EXPECTED_VALUE=false
"${WFC_RESOURCE_TOOL}" --expect "${WFC_EXPECTED_VALUE}" \
    --framework-res "${FRAMEWORK_RES_APK}" \
    || die "built framework-res has the wrong Tier-${BUILD_TIER} WFC capability"
if ! "${DEBUGFS}" -R \
        "dump /system/product/etc/apns-conf.xml ${PRODUCT_APNS}" \
        "${SYSTEM_RAW}" >/dev/null 2>>"${SYSTEM_DEBUGFS_LOG}"; then
    die "debugfs cannot extract the merged product APN list from staged system.img"
fi
[[ -f "${PRODUCT_APNS}" && ! -L "${PRODUCT_APNS}" && -s "${PRODUCT_APNS}" ]] \
    || die "staged system.img contains no ordinary merged product APN list"
IMAGE_PRODUCT_APNS_SHA="$(file_sha256 "${PRODUCT_APNS}")"
EXPECTED_PRODUCT_APNS_SHA="$(manifest_get_exact apns.merged_sha256 \
    "${BUILD_SOURCE_STATE_SOURCE}")"
[[ "${EXPECTED_PRODUCT_APNS_SHA}" =~ ^[0-9a-f]{64}$ && \
   "${IMAGE_PRODUCT_APNS_SHA}" == "${EXPECTED_PRODUCT_APNS_SHA}" ]] \
    || die "staged product APNs do not match the source-validated Lineage merge"
"${SIMG2IMG}" "${DESTINATION}/vendor.img" "${VENDOR_RAW}" \
    || die "cannot expand staged vendor.img for build identity extraction"
[[ -f "${VENDOR_RAW}" && ! -L "${VENDOR_RAW}" && -s "${VENDOR_RAW}" ]] \
    || die "expanded staged vendor image is not an ordinary non-empty file"
if ! "${DEBUGFS}" -R 'cat /build.prop' "${VENDOR_RAW}" \
        >"${VENDOR_BUILD_PROP}" 2>"${VENDOR_DEBUGFS_LOG}"; then
    die "debugfs cannot extract /build.prop from staged vendor.img"
fi
[[ -s "${VENDOR_BUILD_PROP}" ]] \
    || die "staged vendor.img contains no readable /build.prop"

SOURCE_MODULE_DIR="${PROVENANCE_TMP}/source-modules"
mkdir "${SOURCE_MODULE_DIR}"
for module in "${CONNECTIVITY_MODULES[@]}"; do
    "${DEBUGFS}" -R "cat /lib/modules/${module}.ko" "${VENDOR_RAW}" \
        >"${SOURCE_MODULE_DIR}/${module}.ko" 2>>"${VENDOR_DEBUGFS_LOG}" \
        || die "cannot extract ${module}.ko from staged vendor.img"
done
"${KERNEL_ABI_CHECK_TOOL}" --verify-contract "${BUILD_RECEIPT_SOURCE}" \
    --verify-installed "${SOURCE_MODULE_DIR}" >/dev/null \
    || die "staged vendor modules differ from the ABI-gated modules_install outputs"
for module in "${CONNECTIVITY_MODULES[@]}"; do
    rm -- "${SOURCE_MODULE_DIR}/${module}.ko"
done
rmdir "${SOURCE_MODULE_DIR}"

IMAGE_PRODUCT="$(read_image_property ro.product.system.device "${SYSTEM_BUILD_PROP}")"
IMAGE_VARIANT="$(read_image_property ro.system.build.type "${SYSTEM_BUILD_PROP}")"
IMAGE_SYSTEM_FINGERPRINT="$(read_image_property ro.system.build.fingerprint "${SYSTEM_BUILD_PROP}")"
IMAGE_PUBLIC_FINGERPRINT="$(read_image_property ro.build.fingerprint "${SYSTEM_BUILD_PROP}")"
IMAGE_INCREMENTAL="$(read_image_property ro.system.build.version.incremental "${SYSTEM_BUILD_PROP}")"
IMAGE_BUILD_PRODUCT="$(read_image_property ro.build.product "${SYSTEM_BUILD_PROP}")"
IMAGE_BUILD_ID="$(read_image_property ro.build.id "${SYSTEM_BUILD_PROP}")"
IMAGE_DISPLAY_ID="$(read_image_property ro.build.display.id "${SYSTEM_BUILD_PROP}")"
IMAGE_DESCRIPTION="$(read_image_property ro.build.description "${SYSTEM_BUILD_PROP}")"
IMAGE_PLATFORM_SPL="$(read_image_property ro.build.version.security_patch "${SYSTEM_BUILD_PROP}")"
IMAGE_SYSTEM_RELEASE="$(read_image_property ro.system.build.version.release "${SYSTEM_BUILD_PROP}")"
IMAGE_SYSTEM_SDK="$(read_image_property ro.system.build.version.sdk "${SYSTEM_BUILD_PROP}")"
IMAGE_BUILD_RELEASE="$(read_image_property ro.build.version.release "${SYSTEM_BUILD_PROP}")"
IMAGE_BUILD_SDK="$(read_image_property ro.build.version.sdk "${SYSTEM_BUILD_PROP}")"
IMAGE_LINEAGE_VERSION="$(read_image_property ro.lineage.build.version "${SYSTEM_BUILD_PROP}")"
IMAGE_LINEAGE_DEVICE="$(read_image_property ro.lineage.device "${SYSTEM_BUILD_PROP}")"
IMAGE_VENDOR_FINGERPRINT="$(read_image_property ro.vendor.build.fingerprint "${VENDOR_BUILD_PROP}")"
IMAGE_BOOT_FINGERPRINT="$(read_image_property ro.bootimage.build.fingerprint "${VENDOR_BUILD_PROP}")"
IMAGE_VENDOR_INCREMENTAL="$(read_image_property ro.vendor.build.version.incremental "${VENDOR_BUILD_PROP}")"
IMAGE_VENDOR_RELEASE="$(read_image_property ro.vendor.build.version.release "${VENDOR_BUILD_PROP}")"
IMAGE_VENDOR_SDK="$(read_image_property ro.vendor.build.version.sdk "${VENDOR_BUILD_PROP}")"
IMAGE_VENDOR_SPL="$(read_image_property ro.vendor.build.security_patch "${VENDOR_BUILD_PROP}")"
IMAGE_FIRST_API="$(read_image_property ro.product.first_api_level "${VENDOR_BUILD_PROP}")"
[[ "${IMAGE_PRODUCT}" == "${PRODUCT}" ]] \
    || die "staged image product is ${IMAGE_PRODUCT}, expected ${PRODUCT}"
[[ "${IMAGE_VARIANT}" == "${BUILD_VARIANT}" ]] \
    || die "Tier ${BUILD_TIER} requires ${BUILD_VARIANT}, but staged system.img is ${IMAGE_VARIANT}"
[[ "${IMAGE_BUILD_PRODUCT}" == "${PRODUCT}" ]] \
    || die "ro.build.product is ${IMAGE_BUILD_PRODUCT}, expected the real ${PRODUCT}"
[[ "${IMAGE_BUILD_ID}" == QQ3A.200805.001 && \
   "${IMAGE_DISPLAY_ID}" == QQ3A.200805.001 ]] \
    || die "staged image lost the Android-10 Coral build/display ID"
[[ "${IMAGE_PUBLIC_FINGERPRINT}" == \
   google/coral/coral:10/QQ3A.200805.001/6578210:user/release-keys ]] \
    || die "staged image does not carry the exact public Coral fingerprint"
[[ "${IMAGE_DESCRIPTION}" == \
   'coral-user 10 QQ3A.200805.001 6578210 release-keys' ]] \
    || die "staged image does not carry the exact public Coral description"
[[ "${IMAGE_SYSTEM_FINGERPRINT}" != "${IMAGE_PUBLIC_FINGERPRINT}" ]] \
    || die "public spoof leaked into the real system partition fingerprint"

[[ "${IMAGE_SYSTEM_RELEASE}" == 10 && "${IMAGE_BUILD_RELEASE}" == 10 && \
   "${IMAGE_VENDOR_RELEASE}" == 10 && "${IMAGE_SYSTEM_SDK}" == 29 && \
   "${IMAGE_BUILD_SDK}" == 29 && "${IMAGE_VENDOR_SDK}" == 29 && \
   "${IMAGE_LINEAGE_VERSION}" == 17.1 && \
   "${IMAGE_LINEAGE_DEVICE}" == "${PRODUCT}" ]] \
    || die "staged images are not consistently Android 10 / SDK 29 / LineageOS 17.1"
[[ "${IMAGE_PLATFORM_SPL}" == 2023-02-05 && \
   "${IMAGE_VENDOR_SPL}" == 2020-08-05 && "${IMAGE_FIRST_API}" == 26 ]] \
    || die "staged image SPL/launch-API metadata drifted from the truthful MTK values"
[[ "${IMAGE_SYSTEM_FINGERPRINT}" == "${RECEIPT[build.real_fingerprint]}" && \
   "${IMAGE_VENDOR_FINGERPRINT}" == "${IMAGE_SYSTEM_FINGERPRINT}" && \
   "${IMAGE_BOOT_FINGERPRINT}" == "${IMAGE_SYSTEM_FINGERPRINT}" && \
   "${IMAGE_INCREMENTAL}" == "${RECEIPT[build.incremental]}" && \
   "${IMAGE_VENDOR_INCREMENTAL}" == "${IMAGE_INCREMENTAL}" ]] \
    || die "system/vendor/bootimage identities disagree with the clean-build receipt"
if [[ "${BUILD_TIER}" == 3 ]]; then
    REAL_TAGS=release-keys
else
    REAL_TAGS=test-keys
fi
REAL_FINGERPRINT_PATTERN="^XSH/lineage_k50sv1_64_bsp/k50sv1_64_bsp:10/QQ3A\\.200805\\.001/[0-9A-Za-z._-]+:${BUILD_VARIANT}/${REAL_TAGS}$"
[[ "${IMAGE_SYSTEM_FINGERPRINT}" =~ ${REAL_FINGERPRINT_PATTERN} ]] \
    || die "real system/vendor fingerprint lost the XSH Android-10 build identity"

# This A-only target has no product partition image; /system/product/build.prop
# therefore contains only additional product properties and intentionally has
# no ro.product.build.fingerprint. Require absence so an injected fifth,
# unbound partition identity cannot slip past the four-image contract.
PRODUCT_FINGERPRINT_COUNT="$(awk '
    index($0, "ro.product.build.fingerprint=") == 1 { count++ }
    END { print count + 0 }
' "${PRODUCT_BUILD_PROP}")"
[[ "${PRODUCT_FINGERPRINT_COUNT}" -eq 0 ]] \
    || die "unexpected ro.product.build.fingerprint on a target with no product image"

declare -A expected_real_identity=(
    [brand]=XSH
    [device]=k50sv1_64_bsp
    [manufacturer]=XSH
    [model]=F212
    [name]=lineage_k50sv1_64_bsp
)
for identity_field in "${!expected_real_identity[@]}"; do
    system_identity="$(read_image_property \
        "ro.product.system.${identity_field}" "${SYSTEM_BUILD_PROP}")"
    vendor_identity="$(read_image_property \
        "ro.product.vendor.${identity_field}" "${VENDOR_BUILD_PROP}")"
    [[ "${system_identity}" == "${expected_real_identity[${identity_field}]}" && \
       "${vendor_identity}" == "${expected_real_identity[${identity_field}]}" ]] \
        || die "real system/vendor product identity drifted at ${identity_field}"
done

declare -A expected_product_identity=(
    [ro.product.product.brand]=google
    [ro.product.product.device]=coral
    [ro.product.product.manufacturer]=Google
    [ro.product.product.model]='Pixel 4 XL'
    [ro.product.product.name]=coral
)
for identity_key in "${!expected_product_identity[@]}"; do
    identity_value="$(read_image_property_last "${identity_key}" "${PRODUCT_BUILD_PROP}")"
    [[ "${identity_value}" == "${expected_product_identity[${identity_key}]}" ]] \
        || die "${identity_key}=${identity_value}, expected ${expected_product_identity[${identity_key}]}"
done
rm -f -- "${SYSTEM_RAW}" "${SYSTEM_BUILD_PROP}" "${PRODUCT_BUILD_PROP}" \
    "${FRAMEWORK_RES_APK}" "${PRODUCT_APNS}" "${SYSTEM_DEBUGFS_LOG}" \
    "${VENDOR_RAW}" "${VENDOR_BUILD_PROP}" \
    "${VENDOR_DEBUGFS_LOG}"

# Carry the exact receipt inputs into the release bundle. They are copied only
# after current source state matched them byte-for-byte above. Tier 3 also
# carries its public key/posture manifest; no private key leaves /tmp.
receipt_artifacts=(
    "${BUILD_RECEIPT_NAME}" \
    "${BUILD_SOURCE_STATE_NAME}" \
    "${BUILD_REPO_MANIFEST_NAME}"
)
if [[ "${BUILD_TIER}" == 3 ]]; then
    receipt_artifacts+=("${RELEASE_KEYSET_NAME}")
fi
for receipt_name in "${receipt_artifacts[@]}"; do
    cp -- "${PRODUCT_OUT}/${receipt_name}" "${DESTINATION}/${receipt_name}"
    chmod 0644 "${DESTINATION}/${receipt_name}"
    cmp -s "${PRODUCT_OUT}/${receipt_name}" "${DESTINATION}/${receipt_name}" \
        || die "staged receipt artifact changed during copy: ${receipt_name}"
done
BUILD_RECEIPT_SHA="$(file_sha256 "${DESTINATION}/${BUILD_RECEIPT_NAME}")"
BUILD_SOURCE_STATE_SHA="$(file_sha256 "${DESTINATION}/${BUILD_SOURCE_STATE_NAME}")"
BUILD_REPO_MANIFEST_SHA="$(file_sha256 "${DESTINATION}/${BUILD_REPO_MANIFEST_NAME}")"
if [[ "${BUILD_TIER}" == 3 ]]; then
    RELEASE_KEYSET_FILE="${RELEASE_KEYSET_NAME}"
    RELEASE_KEYSET_SHA="$(file_sha256 \
        "${DESTINATION}/${RELEASE_KEYSET_NAME}")"
else
    RELEASE_KEYSET_FILE=none
    RELEASE_KEYSET_SHA=none
fi

OWNED_REPO_LABELS=(work device vendor kernel gapps google_webview huawei_hms)

TOOL_APPLY_SHA="${APPROVED_TOOL_SHA[apply]}"
TOOL_CAPTURE_SHA="${APPROVED_TOOL_SHA[capture]}"
TOOL_BUILD_SHA="${APPROVED_TOOL_SHA[build]}"
TOOL_CARRIER_SHA="${APPROVED_TOOL_SHA[carrier]}"
TOOL_PIXEL_SHA="${APPROVED_TOOL_SHA[pixel]}"
TOOL_LAUNCHER_POLICY_SHA="${APPROVED_TOOL_SHA[launcher_policy]}"
TOOL_WFC_RESOURCE_SHA="${APPROVED_TOOL_SHA[wfc_resource]}"
TOOL_KEYSET_PREPARE_SHA="${APPROVED_TOOL_SHA[keyset_prepare]}"
TOOL_TIER3_PROPERTIES_SHA="${APPROVED_TOOL_SHA[tier3_properties]}"
TOOL_KEYSET_MANIFEST_SHA="${APPROVED_TOOL_SHA[keyset_manifest]}"
TOOL_KERNEL_ABI_SHA="${APPROVED_TOOL_SHA[kernel_abi]}"
TOOL_VERIFY_STAGE_SHA="${APPROVED_TOOL_SHA[verify_stage]}"
TOOL_STAGE_SHA="${APPROVED_TOOL_SHA[stage]}"
TOOL_FLASH_SHA="${APPROVED_TOOL_SHA[flash]}"

STAGED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
[[ "${STAGED_AT_UTC}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || die "cannot derive a strict UTC staging timestamp"

# Produce the canonical image list before SOURCE-MANIFEST so provenance can
# commit to its digest. This one-way cross-link avoids a self-hash cycle while
# preventing a checksum list from one stage being paired with another source
# manifest.
(
    cd "${DESTINATION}"
    sha256sum boot.img recovery.img system.img vendor.img >SHA256SUMS.incomplete
    chmod 0644 SHA256SUMS.incomplete
    [[ "$(awk 'NF {count++} END {print count + 0}' SHA256SUMS.incomplete)" -eq 4 ]] \
        || die "generated manifest does not contain exactly four records"
    sha256sum --quiet --strict --check SHA256SUMS.incomplete
    mv -- SHA256SUMS.incomplete SHA256SUMS
)
SHA256SUMS_SHA="$(file_sha256 "${DESTINATION}/SHA256SUMS")"

SOURCE_MANIFEST_INCOMPLETE="${DESTINATION}/SOURCE-MANIFEST.incomplete"
: >"${SOURCE_MANIFEST_INCOMPLETE}"
manifest_put() {
    local key="$1"
    local value="$2"

    [[ "${key}" =~ ^[a-z0-9_.]+$ && -n "${value}" && \
       "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] \
        || die "unsafe SOURCE-MANIFEST field: ${key}"
    printf '%s=%s\n' "${key}" "${value}" >>"${SOURCE_MANIFEST_INCOMPLETE}"
}

manifest_put manifest.version 7
manifest_put product "${PRODUCT}"
manifest_put tier "${BUILD_TIER}"
manifest_put variant "${BUILD_VARIANT}"
manifest_put staged_at_utc "${STAGED_AT_UTC}"
manifest_put bundle.sha256sums_file SHA256SUMS
manifest_put bundle.sha256sums_sha256 "${SHA256SUMS_SHA}"
manifest_put bundle.build_receipt_file "${BUILD_RECEIPT_NAME}"
manifest_put bundle.build_receipt_sha256 "${BUILD_RECEIPT_SHA}"
manifest_put bundle.build_source_state_file "${BUILD_SOURCE_STATE_NAME}"
manifest_put bundle.build_source_state_sha256 "${BUILD_SOURCE_STATE_SHA}"
manifest_put bundle.android_repo_manifest_file "${BUILD_REPO_MANIFEST_NAME}"
manifest_put bundle.android_repo_manifest_sha256 "${BUILD_REPO_MANIFEST_SHA}"
manifest_put bundle.release_keyset_file "${RELEASE_KEYSET_FILE}"
manifest_put bundle.release_keyset_sha256 "${RELEASE_KEYSET_SHA}"
manifest_put image.build_fingerprint "${IMAGE_PUBLIC_FINGERPRINT}"
manifest_put image.system_build_fingerprint "${IMAGE_SYSTEM_FINGERPRINT}"
manifest_put image.vendor_build_fingerprint "${IMAGE_VENDOR_FINGERPRINT}"
manifest_put image.bootimage_build_fingerprint "${IMAGE_BOOT_FINGERPRINT}"
manifest_put image.build_incremental "${IMAGE_INCREMENTAL}"
manifest_put image.build_id "${IMAGE_BUILD_ID}"
manifest_put image.build_description "${IMAGE_DESCRIPTION}"
manifest_put image.platform_security_patch "${IMAGE_PLATFORM_SPL}"
manifest_put image.vendor_security_patch "${IMAGE_VENDOR_SPL}"
manifest_put image.first_api_level "${IMAGE_FIRST_API}"
manifest_put image.android_release "${IMAGE_BUILD_RELEASE}"
manifest_put image.android_sdk "${IMAGE_BUILD_SDK}"
manifest_put image.lineage_version "${IMAGE_LINEAGE_VERSION}"
manifest_put image.lineage_device "${IMAGE_LINEAGE_DEVICE}"
manifest_put image.product_apns_sha256 "${IMAGE_PRODUCT_APNS_SHA}"
for image in boot recovery system vendor; do
    manifest_put "image.${image}.sha256" "${RECEIPT_IMAGE_SHA[${image}]}"
    manifest_put "image.${image}.bytes" "${RECEIPT_IMAGE_BYTES[${image}]}"
done
for kernel_key in \
    kernel.image_gz.path kernel.image_gz.sha256 kernel.image_gz.bytes \
    kernel.config.path kernel.config.sha256 kernel.config.bytes \
    kernel.module_symvers.path kernel.module_symvers.sha256 \
    kernel.module_symvers.bytes kernel.vmlinux.path kernel.vmlinux.sha256 \
    kernel.vmlinux.bytes kernel.mode kernel.image_name kernel.abi.status \
    kernel.abi.metadata_errors kernel.abi.module_signature_compatible \
    kernel.uts_release kernel.vermagic \
    kernel.module_layout kernel.module_layout_vmlinux kernel.modules \
    "${KERNEL_MODULE_RECEIPT_KEYS[@]}" \
    kernel.expected_pairs kernel.builtin_expected \
    kernel.inter_module_expected kernel.module_inter_ok \
    kernel.candidate_builtin_ok kernel.candidate_inter_ok; do
    manifest_put "${kernel_key}" "${RECEIPT[${kernel_key}]}"
done
for payload_key in \
    boot.kernel boot.ramdisk boot.dtb \
    recovery.kernel recovery.ramdisk recovery.dtb \
    recovery.recovery_dtbo; do
    manifest_put "payload.${payload_key}.sha256" \
        "${BOOT_PAYLOAD_SHA[${payload_key}]}"
    manifest_put "payload.${payload_key}.bytes" \
        "${BOOT_PAYLOAD_BYTES[${payload_key}]}"
done
manifest_put android_repo.project_count "$(manifest_get_exact \
    android_repo.project_count "${BUILD_SOURCE_STATE_SOURCE}")"
manifest_put android_repo.revision_manifest_sha256 "${BUILD_REPO_MANIFEST_SHA}"
for repo_label in "${OWNED_REPO_LABELS[@]}"; do
    for repo_field in path head tree dirty; do
        manifest_put "repo.${repo_label}.${repo_field}" "$(manifest_get_exact \
            "repo.${repo_label}.${repo_field}" "${BUILD_SOURCE_STATE_SOURCE}")"
    done
done
for vendor_lineage_field in \
    path base_head status_sha256 font_diff_sha256 font_result_sha256; do
    manifest_put "vendor_lineage.${vendor_lineage_field}" "$(manifest_get_exact \
        "vendor_lineage.${vendor_lineage_field}" "${BUILD_SOURCE_STATE_SOURCE}")"
done
for apn_field in \
    default_path default_sha256 override_path override_sha256 \
    merge_tool_path merge_tool_sha256 merged_sha256; do
    manifest_put "apns.${apn_field}" "$(manifest_get_exact \
        "apns.${apn_field}" "${BUILD_SOURCE_STATE_SOURCE}")"
done
manifest_put revision.work "$(manifest_get_exact repo.work.head "${BUILD_SOURCE_STATE_SOURCE}")"
manifest_put revision.device "$(manifest_get_exact repo.device.head "${BUILD_SOURCE_STATE_SOURCE}")"
manifest_put revision.vendor "$(manifest_get_exact repo.vendor.head "${BUILD_SOURCE_STATE_SOURCE}")"
manifest_put revision.kernel "$(manifest_get_exact repo.kernel.head "${BUILD_SOURCE_STATE_SOURCE}")"
manifest_put tool.apply_upstream_patches_sha256 "${TOOL_APPLY_SHA}"
manifest_put tool.capture_build_inputs_sha256 "${TOOL_CAPTURE_SHA}"
manifest_put tool.run_lineage_build_sha256 "${TOOL_BUILD_SHA}"
manifest_put tool.check_carrier_config_sha256 "${TOOL_CARRIER_SHA}"
manifest_put tool.check_pixel_identity_sha256 "${TOOL_PIXEL_SHA}"
manifest_put tool.check_launcher_policy_sha256 "${TOOL_LAUNCHER_POLICY_SHA}"
manifest_put tool.check_wfc_framework_resource_sha256 "${TOOL_WFC_RESOURCE_SHA}"
manifest_put tool.prepare_tier3_keyset_sha256 "${TOOL_KEYSET_PREPARE_SHA}"
manifest_put tool.verify_tier3_properties_sha256 "${TOOL_TIER3_PROPERTIES_SHA}"
manifest_put tool.verify_tier3_keyset_manifest_sha256 "${TOOL_KEYSET_MANIFEST_SHA}"
manifest_put tool.check_module_abi_sha256 "${TOOL_KERNEL_ABI_SHA}"
manifest_put tool.verify_stage_contract_sha256 "${TOOL_VERIFY_STAGE_SHA}"
manifest_put tool.stage_tier_images_sha256 "${TOOL_STAGE_SHA}"
manifest_put tool.flash_tier_images_sha256 "${TOOL_FLASH_SHA}"
chmod 0644 "${SOURCE_MANIFEST_INCOMPLETE}"

find "${PROVENANCE_TMP}" -mindepth 1 -depth -delete
rmdir "${PROVENANCE_TMP}"

(
    cd "${DESTINATION}"
    mv -- SOURCE-MANIFEST.incomplete SOURCE-MANIFEST
    sha256sum SOURCE-MANIFEST >SOURCE-MANIFEST.sha256.incomplete
    chmod 0644 SOURCE-MANIFEST.sha256.incomplete
    [[ "$(awk 'NF {count++} END {print count + 0}' \
            SOURCE-MANIFEST.sha256.incomplete)" -eq 1 ]] \
        || die "generated source-manifest digest does not contain exactly one record"
    sha256sum --quiet --strict --check SOURCE-MANIFEST.sha256.incomplete
    mv -- SOURCE-MANIFEST.sha256.incomplete SOURCE-MANIFEST.sha256

    stage_contract_files=(
        SHA256SUMS
        SOURCE-MANIFEST
        SOURCE-MANIFEST.sha256
        "${BUILD_RECEIPT_NAME}"
        "${BUILD_SOURCE_STATE_NAME}"
        "${BUILD_REPO_MANIFEST_NAME}"
    )
    if [[ "${BUILD_TIER}" == 3 ]]; then
        stage_contract_files+=("${RELEASE_KEYSET_NAME}")
    fi
    sha256sum "${stage_contract_files[@]}" >STAGE-CONTRACT.incomplete
    chmod 0644 STAGE-CONTRACT.incomplete
    [[ "$(awk 'NF { count++ } END { print count + 0 }' \
            STAGE-CONTRACT.incomplete)" -eq "${#stage_contract_files[@]}" ]] \
        || die "generated stage contract has the wrong record count"
    sha256sum --quiet --strict --check STAGE-CONTRACT.incomplete
    mv -- STAGE-CONTRACT.incomplete STAGE-CONTRACT
    sha256sum STAGE-CONTRACT >STAGE-CONTRACT.sha256.incomplete
    chmod 0644 STAGE-CONTRACT.sha256.incomplete
    sha256sum --quiet --strict --check STAGE-CONTRACT.sha256.incomplete
    mv -- STAGE-CONTRACT.sha256.incomplete STAGE-CONTRACT.sha256

    # Validate the complete transitive chain once more from its top-level
    # digest: stage contract -> source/checksum manifests -> four images.
    sha256sum --quiet --strict --check STAGE-CONTRACT.sha256
    sha256sum --quiet --strict --check STAGE-CONTRACT
    sha256sum --quiet --strict --check SOURCE-MANIFEST.sha256
    sha256sum --quiet --strict --check SHA256SUMS
)

verify_approved_tools
FINAL_SOURCE_TMP="$(mktemp -d /tmp/k50-stage-source.XXXXXX)"
"${BUILD_INPUT_TOOL}" --repo-manifest \
    "${FINAL_SOURCE_TMP}/repo-manifest.xml" \
    >"${FINAL_SOURCE_TMP}/source-state" \
    || die "cannot recapture final source state before publishing the stage"
cmp -s "${BUILD_SOURCE_STATE_SOURCE}" "${FINAL_SOURCE_TMP}/source-state" \
    || die "source state changed while staging images"
cmp -s "${BUILD_REPO_MANIFEST_SOURCE}" \
    "${FINAL_SOURCE_TMP}/repo-manifest.xml" \
    || die "Android repo revisions changed while staging images"
"${VERIFY_STAGE_TOOL}" "${DESTINATION}" >/dev/null \
    || die "independent stage-contract verifier rejected the completed bundle"
find "${FINAL_SOURCE_TMP}" -mindepth 1 -depth -delete
rmdir "${FINAL_SOURCE_TMP}"
FINAL_SOURCE_TMP=""

complete=true

printf 'Staged and cross-verified four images plus source provenance at %s\n' \
    "${DESTINATION}"
