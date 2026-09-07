#!/usr/bin/env bash
# Verify the complete, transitive release-bundle contract without trusting any
# ambient build variables. Safe and read-only.

set -euo pipefail

TOOL_PATH="$(realpath -e "${BASH_SOURCE[0]}")"

# manifest_get_exact() is called inside $( ) at some forty sites, and `die`
# there `exit`s the COMMAND SUBSTITUTION SUBSHELL, not this script. A bare
# assignment still aborts -- `X="$(...)"` takes the substitution's status and
# `set -e` acts on it -- but inside `[[ ]]` the status is discarded and the
# parent sees only the empty string. With both operands missing,
# `[[ "" == "" ]]` is TRUE, no `die` on the right-hand side fires, and the run
# walks on to print `status=PASS` with the diagnostics already on stderr. The
# receipt/source tool-digest loop is exactly that shape, for seven tools.
#
# `$$` is the top-level PID even inside a command substitution, so a subshell
# raises SIGUSR1 on the script itself; bash defers the handler until the
# substitution it is waiting on returns, and the trap then exits 1 before the
# comparison is used. Measured: with both operands failing, execution stops at
# the `[[ ]]`, not after it.
trap 'exit 1' USR1
die() {
    printf 'Stage-contract verification failed: %s\n' "$*" >&2
    [[ "${BASHPID}" == "$$" ]] || kill -USR1 "$$" 2>/dev/null
    exit 1
}

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s <stage-directory>\n' "$0" >&2
    exit 2
}

STAGE_DIR="$1"
[[ -d "${STAGE_DIR}" && ! -L "${STAGE_DIR}" ]] \
    || die "stage path is not an ordinary directory: ${STAGE_DIR}"
STAGE_DIR="$(realpath -e "${STAGE_DIR}")"

BUILD_RECEIPT=K50SV1-BUILD-RECEIPT
BUILD_SOURCE_STATE=K50SV1-BUILD-SOURCE-STATE
ANDROID_REPO_MANIFEST=K50SV1-ANDROID-REPO-MANIFEST.xml
RELEASE_KEYSET=K50SV1-RELEASE-KEYSET
KEYSET_MANIFEST_VERIFY_TOOL="$(dirname "${TOOL_PATH}")/verify-tier3-keyset-manifest.sh"
KERNEL_ABI_CHECK_TOOL="$(dirname "${TOOL_PATH}")/kernel/check-module-abi.sh"
LAUNCHER_POLICY_TOOL="$(dirname "${TOOL_PATH}")/check-launcher-policy.py"
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
UNPACK_BOOTIMG="$(command -v unpack_bootimg || true)"
PROJECT_ROOT="$(cd "$(dirname "${TOOL_PATH}")/../../.." && pwd)"
SIMG2IMG="${PROJECT_ROOT}/lineage-17.1/out/host/linux-x86/bin/simg2img"
DEBUGFS="$(command -v debugfs || true)"
[[ -x "${SIMG2IMG}" && -x "${DEBUGFS}" ]] \
    || die "host simg2img/debugfs is unavailable for installed-module verification"
[[ -x "${KEYSET_MANIFEST_VERIFY_TOOL}" ]] \
    || die "Tier-3 keyset-manifest verifier is unavailable"
[[ -x "${KERNEL_ABI_CHECK_TOOL}" ]] \
    || die "source-kernel ABI verifier is unavailable"
[[ -x "${UNPACK_BOOTIMG}" ]] \
    || die "host unpack_bootimg is unavailable"
REQUIRED_FILES=(
    boot.img recovery.img system.img vendor.img
    SHA256SUMS SOURCE-MANIFEST SOURCE-MANIFEST.sha256
    "${BUILD_RECEIPT}" "${BUILD_SOURCE_STATE}" "${ANDROID_REPO_MANIFEST}"
    STAGE-CONTRACT STAGE-CONTRACT.sha256
)
for file in "${REQUIRED_FILES[@]}"; do
    [[ -f "${STAGE_DIR}/${file}" && ! -L "${STAGE_DIR}/${file}" && \
       -s "${STAGE_DIR}/${file}" ]] \
        || die "missing, empty, or symlinked required file: ${file}"
done

file_sha256() {
    sha256sum -- "$1" | awk '{ print $1 }'
}

manifest_get_exact() {
    local key="$1"
    local manifest="$2"
    local value

    value="$(awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++
            value = substr($0, length(key) + 2)
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    ' "${manifest}")" \
        || die "${manifest##*/} does not contain exactly one non-empty ${key}"
    [[ "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] \
        || die "unsafe ${key} value in ${manifest##*/}"
    printf '%s' "${value}"
}

require_exact_digest_records() {
    local manifest="$1"
    shift
    local expected=("$@")
    local records file count

    records="$(awk 'NF { count++ } END { print count + 0 }' "${manifest}")"
    [[ "${records}" -eq "${#expected[@]}" ]] \
        || die "${manifest##*/} has ${records} records; expected ${#expected[@]}"
    for file in "${expected[@]}"; do
        count="$(awk -v file="${file}" '$2 == file { count++ } END { print count + 0 }' \
            "${manifest}")"
        [[ "${count}" -eq 1 ]] \
            || die "${manifest##*/} must name ${file} exactly once"
    done
}

require_exact_key_records() {
    local manifest="$1"
    shift
    local expected=("$@")
    local records key count

    records="$(awk 'NF { count++ } END { print count + 0 }' "${manifest}")"
    [[ "${records}" -eq "${#expected[@]}" ]] \
        || die "${manifest##*/} has ${records} records; expected ${#expected[@]}"
    for key in "${expected[@]}"; do
        count="$(awk -v key="${key}" \
            'index($0, key "=") == 1 { count++ } END { print count + 0 }' \
            "${manifest}")"
        [[ "${count}" -eq 1 ]] \
            || die "${manifest##*/} must contain ${key} exactly once"
    done
}

SOURCE="${STAGE_DIR}/SOURCE-MANIFEST"
RECEIPT="${STAGE_DIR}/${BUILD_RECEIPT}"
SOURCE_STATE="${STAGE_DIR}/${BUILD_SOURCE_STATE}"
REPO_MANIFEST="${STAGE_DIR}/${ANDROID_REPO_MANIFEST}"

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
require_exact_key_records "${RECEIPT}" "${EXPECTED_RECEIPT_KEYS[@]}"

EXPECTED_SOURCE_KEYS=(
    manifest.version product tier variant staged_at_utc
    bundle.sha256sums_file bundle.sha256sums_sha256
    bundle.build_receipt_file bundle.build_receipt_sha256
    bundle.build_source_state_file bundle.build_source_state_sha256
    bundle.android_repo_manifest_file bundle.android_repo_manifest_sha256
    bundle.release_keyset_file bundle.release_keyset_sha256
    image.build_fingerprint image.system_build_fingerprint
    image.vendor_build_fingerprint image.bootimage_build_fingerprint
    image.build_incremental image.build_id image.build_description
    image.platform_security_patch image.vendor_security_patch
    image.first_api_level image.android_release image.android_sdk
    image.lineage_version image.lineage_device image.product_apns_sha256
)
for image in boot recovery system vendor; do
    EXPECTED_SOURCE_KEYS+=("image.${image}.sha256" "image.${image}.bytes")
done
EXPECTED_SOURCE_KEYS+=(
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
)
for payload in \
    boot.kernel boot.ramdisk boot.dtb \
    recovery.kernel recovery.ramdisk recovery.dtb \
    recovery.recovery_dtbo; do
    EXPECTED_SOURCE_KEYS+=("payload.${payload}.sha256" "payload.${payload}.bytes")
done
EXPECTED_SOURCE_KEYS+=(
    android_repo.project_count android_repo.revision_manifest_sha256
)
for repo_label in work device vendor kernel gapps google_webview huawei_hms; do
    for repo_field in path head tree dirty; do
        EXPECTED_SOURCE_KEYS+=("repo.${repo_label}.${repo_field}")
    done
done
for vendor_lineage_field in \
    path base_head status_sha256 font_diff_sha256 font_result_sha256; do
    EXPECTED_SOURCE_KEYS+=("vendor_lineage.${vendor_lineage_field}")
done
for apn_field in \
    default_path default_sha256 override_path override_sha256 \
    merge_tool_path merge_tool_sha256 merged_sha256; do
    EXPECTED_SOURCE_KEYS+=("apns.${apn_field}")
done
for revision_label in work device vendor kernel; do
    EXPECTED_SOURCE_KEYS+=("revision.${revision_label}")
done
EXPECTED_SOURCE_KEYS+=(
    tool.apply_upstream_patches_sha256 tool.capture_build_inputs_sha256
    tool.run_lineage_build_sha256 tool.check_carrier_config_sha256
    tool.check_pixel_identity_sha256 tool.check_wfc_framework_resource_sha256
    tool.check_launcher_policy_sha256
    tool.prepare_tier3_keyset_sha256 tool.verify_tier3_properties_sha256
    tool.verify_tier3_keyset_manifest_sha256 tool.check_module_abi_sha256
    tool.verify_stage_contract_sha256 tool.stage_tier_images_sha256
    tool.flash_tier_images_sha256
)
require_exact_key_records "${SOURCE}" "${EXPECTED_SOURCE_KEYS[@]}"

EXPECTED_SOURCE_STATE_KEYS=(
    source_state.version android_repo.project_count
    android_repo.revision_manifest_sha256
)
for repo_label in work device vendor kernel gapps google_webview huawei_hms; do
    for repo_field in path head tree dirty; do
        EXPECTED_SOURCE_STATE_KEYS+=("repo.${repo_label}.${repo_field}")
    done
done
for vendor_lineage_field in \
    path base_head status_sha256 font_diff_sha256 font_result_sha256; do
    EXPECTED_SOURCE_STATE_KEYS+=("vendor_lineage.${vendor_lineage_field}")
done
for apn_field in \
    default_path default_sha256 override_path override_sha256 \
    merge_tool_path merge_tool_sha256 merged_sha256; do
    EXPECTED_SOURCE_STATE_KEYS+=("apns.${apn_field}")
done
require_exact_key_records "${SOURCE_STATE}" "${EXPECTED_SOURCE_STATE_KEYS[@]}"

[[ "$(manifest_get_exact manifest.version "${SOURCE}")" == 7 && \
   "$(manifest_get_exact product "${SOURCE}")" == k50sv1_64_bsp ]] \
    || die "SOURCE-MANIFEST has the wrong schema/product"
TIER="$(manifest_get_exact tier "${SOURCE}")"
VARIANT="$(manifest_get_exact variant "${SOURCE}")"
case "${TIER}:${VARIANT}" in
    1:userdebug | 2:userdebug | 3:user) ;;
    *) die "invalid tier/variant pair ${TIER}:${VARIANT}" ;;
esac

stage_contract_files=(
    SHA256SUMS SOURCE-MANIFEST SOURCE-MANIFEST.sha256
    "${BUILD_RECEIPT}" "${BUILD_SOURCE_STATE}" "${ANDROID_REPO_MANIFEST}"
)
if [[ "${TIER}" == 3 ]]; then
    [[ -f "${STAGE_DIR}/${RELEASE_KEYSET}" && \
       ! -L "${STAGE_DIR}/${RELEASE_KEYSET}" && \
       -s "${STAGE_DIR}/${RELEASE_KEYSET}" ]] \
        || die "Tier 3 stage has no ordinary public release-keyset manifest"
    stage_contract_files+=("${RELEASE_KEYSET}")
elif [[ -e "${STAGE_DIR}/${RELEASE_KEYSET}" || \
        -L "${STAGE_DIR}/${RELEASE_KEYSET}" ]]; then
    die "diagnostic stage unexpectedly contains a release-keyset manifest"
fi

require_exact_digest_records "${STAGE_DIR}/STAGE-CONTRACT.sha256" STAGE-CONTRACT
(
    cd "${STAGE_DIR}"
    sha256sum --quiet --strict --check STAGE-CONTRACT.sha256
)
require_exact_digest_records "${STAGE_DIR}/STAGE-CONTRACT" \
    "${stage_contract_files[@]}"
(
    cd "${STAGE_DIR}"
    sha256sum --quiet --strict --check STAGE-CONTRACT
)
require_exact_digest_records "${STAGE_DIR}/SOURCE-MANIFEST.sha256" SOURCE-MANIFEST
(
    cd "${STAGE_DIR}"
    sha256sum --quiet --strict --check SOURCE-MANIFEST.sha256
)
require_exact_digest_records "${STAGE_DIR}/SHA256SUMS" \
    boot.img recovery.img system.img vendor.img
(
    cd "${STAGE_DIR}"
    sha256sum --quiet --strict --check SHA256SUMS
)

declare -A expected_bundle_file=(
    [sha256sums]=SHA256SUMS
    [build_receipt]="${BUILD_RECEIPT}"
    [build_source_state]="${BUILD_SOURCE_STATE}"
    [android_repo_manifest]="${ANDROID_REPO_MANIFEST}"
)
for bundle_key in "${!expected_bundle_file[@]}"; do
    file="$(manifest_get_exact "bundle.${bundle_key}_file" "${SOURCE}")"
    digest="$(manifest_get_exact "bundle.${bundle_key}_sha256" "${SOURCE}")"
    [[ "${file}" == "${expected_bundle_file[${bundle_key}]}" && \
       "${digest}" =~ ^[0-9a-f]{64}$ && \
       "$(file_sha256 "${STAGE_DIR}/${file}")" == "${digest}" ]] \
        || die "SOURCE-MANIFEST does not bind ${bundle_key}"
done
SOURCE_RELEASE_KEYSET_FILE="$(manifest_get_exact \
    bundle.release_keyset_file "${SOURCE}")"
SOURCE_RELEASE_KEYSET_SHA="$(manifest_get_exact \
    bundle.release_keyset_sha256 "${SOURCE}")"
RECEIPT_RELEASE_KEYSET_FILE="$(manifest_get_exact \
    release_keyset.file "${RECEIPT}")"
RECEIPT_RELEASE_KEYSET_SHA="$(manifest_get_exact \
    release_keyset.sha256 "${RECEIPT}")"
if [[ "${TIER}" == 3 ]]; then
    [[ "${SOURCE_RELEASE_KEYSET_FILE}" == "${RELEASE_KEYSET}" && \
       "${RECEIPT_RELEASE_KEYSET_FILE}" == "${RELEASE_KEYSET}" && \
       "${SOURCE_RELEASE_KEYSET_SHA}" =~ ^[0-9a-f]{64}$ && \
       "${RECEIPT_RELEASE_KEYSET_SHA}" == "${SOURCE_RELEASE_KEYSET_SHA}" && \
       "$(file_sha256 "${STAGE_DIR}/${RELEASE_KEYSET}")" == \
            "${SOURCE_RELEASE_KEYSET_SHA}" ]] \
        || die "Tier 3 receipt/source/stage do not bind one release keyset"
    "${KEYSET_MANIFEST_VERIFY_TOOL}" \
        "${STAGE_DIR}/${RELEASE_KEYSET}" >/dev/null \
        || die "Tier 3 public release-keyset manifest is invalid"
else
    [[ "${SOURCE_RELEASE_KEYSET_FILE}" == none && \
       "${SOURCE_RELEASE_KEYSET_SHA}" == none && \
       "${RECEIPT_RELEASE_KEYSET_FILE}" == none && \
       "${RECEIPT_RELEASE_KEYSET_SHA}" == none ]] \
        || die "diagnostic stage carries Tier-3 release-keyset metadata"
fi

for image in boot recovery system vendor; do
    expected_sha="$(manifest_get_exact "image.${image}.sha256" "${SOURCE}")"
    expected_bytes="$(manifest_get_exact "image.${image}.bytes" "${SOURCE}")"
    checksum_sha="$(awk -v file="${image}.img" '$2 == file { print $1 }' \
        "${STAGE_DIR}/SHA256SUMS")"
    [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ && \
       "${expected_bytes}" =~ ^[0-9]+$ && "${expected_bytes}" -gt 0 && \
       "${checksum_sha}" == "${expected_sha}" && \
       "$(file_sha256 "${STAGE_DIR}/${image}.img")" == "${expected_sha}" && \
       "$(stat -c %s "${STAGE_DIR}/${image}.img")" == "${expected_bytes}" ]] \
        || die "${image}.img does not match the source/checksum manifests"
done

[[ "$(manifest_get_exact receipt.version "${RECEIPT}")" == 4 && \
   "$(manifest_get_exact product "${RECEIPT}")" == k50sv1_64_bsp && \
   "$(manifest_get_exact tier "${RECEIPT}")" == "${TIER}" && \
   "$(manifest_get_exact variant "${RECEIPT}")" == "${VARIANT}" && \
   "$(manifest_get_exact build.clean_output "${RECEIPT}")" == true && \
   "$(manifest_get_exact build.real_fingerprint "${RECEIPT}")" == \
        "$(manifest_get_exact image.system_build_fingerprint "${SOURCE}")" && \
   "$(manifest_get_exact build.incremental "${RECEIPT}")" == \
        "$(manifest_get_exact image.build_incremental "${SOURCE}")" ]] \
    || die "clean-build receipt disagrees with SOURCE-MANIFEST"
[[ "$(manifest_get_exact source_state.file "${RECEIPT}")" == \
        "${BUILD_SOURCE_STATE}" && \
   "$(manifest_get_exact source_state.sha256 "${RECEIPT}")" == \
        "$(file_sha256 "${SOURCE_STATE}")" && \
   "$(manifest_get_exact android_repo_manifest.file "${RECEIPT}")" == \
        "${ANDROID_REPO_MANIFEST}" && \
   "$(manifest_get_exact android_repo_manifest.sha256 "${RECEIPT}")" == \
        "$(file_sha256 "${REPO_MANIFEST}")" ]] \
    || die "clean-build receipt does not bind its source inputs"
[[ "$(manifest_get_exact android_repo.revision_manifest_sha256 "${SOURCE_STATE}")" == \
   "$(file_sha256 "${REPO_MANIFEST}")" ]] \
    || die "build source state does not bind the pinned repo manifest"
[[ "$(manifest_get_exact source_state.version "${SOURCE_STATE}")" == 4 ]] \
    || die "build source state has no seven-repository provenance"

declare -A EXPECTED_KERNEL_VALUE=(
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
for kernel_key in "${!EXPECTED_KERNEL_VALUE[@]}"; do
    [[ "$(manifest_get_exact "${kernel_key}" "${RECEIPT}")" == \
           "${EXPECTED_KERNEL_VALUE[${kernel_key}]}" && \
       "$(manifest_get_exact "${kernel_key}" "${SOURCE}")" == \
           "${EXPECTED_KERNEL_VALUE[${kernel_key}]}" ]] \
        || die "source-kernel constant is invalid: ${kernel_key}"
done
for kernel_artifact in image_gz config module_symvers vmlinux; do
    receipt_kernel_sha="$(manifest_get_exact \
        "kernel.${kernel_artifact}.sha256" "${RECEIPT}")"
    receipt_kernel_bytes="$(manifest_get_exact \
        "kernel.${kernel_artifact}.bytes" "${RECEIPT}")"
    [[ "${receipt_kernel_sha}" =~ ^[0-9a-f]{64}$ && \
       "${receipt_kernel_bytes}" =~ ^[0-9]+$ && \
       "${receipt_kernel_bytes}" -gt 0 && \
       "$(manifest_get_exact "kernel.${kernel_artifact}.sha256" "${SOURCE}")" == \
           "${receipt_kernel_sha}" && \
       "$(manifest_get_exact "kernel.${kernel_artifact}.bytes" "${SOURCE}")" == \
           "${receipt_kernel_bytes}" ]] \
        || die "receipt/source do not bind one ${kernel_artifact} artifact"
done
RECEIPT_KERNEL_IMAGE_SHA="$(manifest_get_exact kernel.image_gz.sha256 "${RECEIPT}")"
RECEIPT_KERNEL_IMAGE_BYTES="$(manifest_get_exact kernel.image_gz.bytes "${RECEIPT}")"
RECEIPT_KERNEL_ABI_TOOL_SHA="$(manifest_get_exact \
    tool.check_module_abi_sha256 "${RECEIPT}")"
[[ "${RECEIPT_KERNEL_ABI_TOOL_SHA}" =~ ^[0-9a-f]{64}$ && \
   "$(manifest_get_exact tool.check_module_abi_sha256 "${SOURCE}")" == \
       "${RECEIPT_KERNEL_ABI_TOOL_SHA}" && \
   "$(file_sha256 "${KERNEL_ABI_CHECK_TOOL}")" == \
       "${RECEIPT_KERNEL_ABI_TOOL_SHA}" ]] \
    || die "source-kernel ABI checker is not the receipt/source authority"
"${KERNEL_ABI_CHECK_TOOL}" --verify-contract "${RECEIPT}" >/dev/null \
    || die "source-module receipt does not describe a complete ABI inventory"
for kernel_key in "${EXPECTED_RECEIPT_KEYS[@]}"; do
    [[ "${kernel_key}" == kernel.* ]] || continue
    [[ "$(manifest_get_exact "${kernel_key}" "${RECEIPT}")" == \
       "$(manifest_get_exact "${kernel_key}" "${SOURCE}")" ]] \
        || die "receipt/source disagree about ${kernel_key}"
done

# Independently unpack the staged boot images. Whole-image fixity alone cannot
# prove which kernel/DT payload a self-consistent replacement bundle contains.
BOOT_VERIFY_TMP="$(mktemp -d /tmp/k50-stage-boot-verify.XXXXXX)"
cleanup_boot_verify() {
    if [[ -d "${BOOT_VERIFY_TMP:-}" && ! -L "${BOOT_VERIFY_TMP}" && \
          "${BOOT_VERIFY_TMP}" == /tmp/k50-stage-boot-verify.* ]]; then
        find "${BOOT_VERIFY_TMP}" -mindepth 1 -depth -delete
        rmdir "${BOOT_VERIFY_TMP}"
    fi
}
trap cleanup_boot_verify EXIT

# Check installed module bytes independently of the stage producer and out/.
VENDOR_VERIFY_RAW="${BOOT_VERIFY_TMP}/vendor.raw"
SOURCE_MODULE_DIR="${BOOT_VERIFY_TMP}/source-modules"
"${SIMG2IMG}" "${STAGE_DIR}/vendor.img" "${VENDOR_VERIFY_RAW}" \
    || die "cannot expand staged vendor.img for source-module verification"
mkdir "${SOURCE_MODULE_DIR}"
for module in "${CONNECTIVITY_MODULES[@]}"; do
    "${DEBUGFS}" -R "cat /lib/modules/${module}.ko" "${VENDOR_VERIFY_RAW}" \
        >"${SOURCE_MODULE_DIR}/${module}.ko" 2>>"${BOOT_VERIFY_TMP}/vendor-debugfs.log" \
        || die "cannot extract staged source module ${module}.ko"
done
"${KERNEL_ABI_CHECK_TOOL}" --verify-contract "${RECEIPT}" \
    --verify-installed "${SOURCE_MODULE_DIR}" >/dev/null \
    || die "staged vendor modules differ from the receipt-bound modules_install outputs"
rm -- "${VENDOR_VERIFY_RAW}"
declare -A VERIFIED_PAYLOAD_SHA=()
declare -A VERIFIED_PAYLOAD_BYTES=()
for image in boot recovery; do
    mkdir "${BOOT_VERIFY_TMP}/${image}"
    "${UNPACK_BOOTIMG}" --boot_img "${STAGE_DIR}/${image}.img" \
        --out "${BOOT_VERIFY_TMP}/${image}" --format info \
        >"${BOOT_VERIFY_TMP}/${image}.info" \
        || die "unpack_bootimg rejected staged ${image}.img"
    for payload in kernel ramdisk dtb; do
        payload_path="${BOOT_VERIFY_TMP}/${image}/${payload}"
        [[ -f "${payload_path}" && ! -L "${payload_path}" && \
           -s "${payload_path}" ]] \
            || die "${image}.img has no complete ${payload} payload"
        VERIFIED_PAYLOAD_SHA[${image}.${payload}]="$(file_sha256 "${payload_path}")"
        VERIFIED_PAYLOAD_BYTES[${image}.${payload}]="$(stat -c %s "${payload_path}")"
        [[ "$(manifest_get_exact "payload.${image}.${payload}.sha256" \
                "${SOURCE}")" == "${VERIFIED_PAYLOAD_SHA[${image}.${payload}]}" && \
           "$(manifest_get_exact "payload.${image}.${payload}.bytes" \
                "${SOURCE}")" == "${VERIFIED_PAYLOAD_BYTES[${image}.${payload}]}" ]] \
            || die "SOURCE-MANIFEST does not bind ${image}.${payload}"
    done
    grep -Fxq 'boot magic: ANDROID!' "${BOOT_VERIFY_TMP}/${image}.info" \
        || die "${image}.img has no Android boot magic"
    grep -Fxq 'page size: 2048' "${BOOT_VERIFY_TMP}/${image}.info" \
        || die "${image}.img has an unexpected boot page size"
    grep -Fxq 'os version: 10.0.0' "${BOOT_VERIFY_TMP}/${image}.info" \
        || die "${image}.img is not an Android 10 boot image"
    grep -Fxq 'boot image header version: 2' "${BOOT_VERIFY_TMP}/${image}.info" \
        || die "${image}.img has an unexpected boot header version"
    ! grep -Eq '(^|[[:space:]])module\.sig_enforce=1([[:space:]]|$)' \
        "${BOOT_VERIFY_TMP}/${image}.info" \
        || die "${image}.img would reject unsigned connectivity modules"
    expected_variant="buildvariant=${VARIANT}"
    [[ "$(grep -Eo '(^|[[:space:]])buildvariant=[^[:space:]]+' \
            "${BOOT_VERIFY_TMP}/${image}.info" | sed 's/^[[:space:]]//' \
            | grep -Fxc "${expected_variant}" || true)" -eq 1 ]] \
        || die "${image}.img does not carry exactly ${expected_variant}"
    selinux_tokens="$(grep -Eo \
        '(^|[[:space:]])androidboot\.selinux=[^[:space:]]+' \
        "${BOOT_VERIFY_TMP}/${image}.info" | sed 's/^[[:space:]]//' || true)"
    if [[ "${TIER}" == 1 ]]; then
        [[ "${selinux_tokens}" == androidboot.selinux=permissive ]] \
            || die "Tier 1 ${image}.img is not exactly permissive"
    elif [[ -n "${selinux_tokens}" ]]; then
        die "Tier ${TIER} ${image}.img carries a forbidden SELinux override"
    fi
    if [[ "${image}" == recovery ]]; then
        recovery_dtbo_path="${BOOT_VERIFY_TMP}/recovery/recovery_dtbo"
        [[ -f "${recovery_dtbo_path}" && ! -L "${recovery_dtbo_path}" && \
           -s "${recovery_dtbo_path}" ]] \
            || die "recovery.img has no recovery-DTBO payload"
        VERIFIED_PAYLOAD_SHA[recovery.recovery_dtbo]="$(file_sha256 \
            "${recovery_dtbo_path}")"
        VERIFIED_PAYLOAD_BYTES[recovery.recovery_dtbo]="$(stat -c %s \
            "${recovery_dtbo_path}")"
        [[ "$(manifest_get_exact payload.recovery.recovery_dtbo.sha256 \
                "${SOURCE}")" == \
                "${VERIFIED_PAYLOAD_SHA[recovery.recovery_dtbo]}" && \
           "$(manifest_get_exact payload.recovery.recovery_dtbo.bytes \
                "${SOURCE}")" == \
                "${VERIFIED_PAYLOAD_BYTES[recovery.recovery_dtbo]}" ]] \
            || die "SOURCE-MANIFEST does not bind recovery.recovery_dtbo"
    elif [[ -e "${BOOT_VERIFY_TMP}/boot/recovery_dtbo" || \
            -L "${BOOT_VERIFY_TMP}/boot/recovery_dtbo" ]]; then
        die "boot.img unexpectedly contains a recovery-DTBO payload"
    fi
done

[[ "${VERIFIED_PAYLOAD_SHA[boot.kernel]}" == "${RECEIPT_KERNEL_IMAGE_SHA}" && \
   "${VERIFIED_PAYLOAD_BYTES[boot.kernel]}" == \
       "${RECEIPT_KERNEL_IMAGE_BYTES}" && \
   "${VERIFIED_PAYLOAD_SHA[recovery.kernel]}" == \
       "${RECEIPT_KERNEL_IMAGE_SHA}" && \
   "${VERIFIED_PAYLOAD_BYTES[recovery.kernel]}" == \
       "${RECEIPT_KERNEL_IMAGE_BYTES}" ]] \
    || die "boot/recovery do not embed the receipt-bound source Image.gz"
cmp -s "${BOOT_VERIFY_TMP}/boot/kernel" \
    "${BOOT_VERIFY_TMP}/recovery/kernel" \
    || die "boot/recovery source-kernel payloads differ"
cmp -s "${BOOT_VERIFY_TMP}/boot/dtb" "${BOOT_VERIFY_TMP}/recovery/dtb" \
    || die "boot/recovery stock DT payloads differ"
[[ "${VERIFIED_PAYLOAD_SHA[boot.dtb]}" == \
       3bf76b640714efc8df9547c5a10f71b3623e4c9c7f01e145ff8cb3cc1b1e2907 && \
   "${VERIFIED_PAYLOAD_BYTES[boot.dtb]}" == 68438 && \
   "${VERIFIED_PAYLOAD_SHA[recovery.dtb]}" == \
       3bf76b640714efc8df9547c5a10f71b3623e4c9c7f01e145ff8cb3cc1b1e2907 && \
   "${VERIFIED_PAYLOAD_BYTES[recovery.dtb]}" == 68438 && \
   "${VERIFIED_PAYLOAD_SHA[recovery.recovery_dtbo]}" == \
       21c8f45333222c3dd4adcd18f91178492de6fe28512eb009f47891d30c3d2db6 && \
   "${VERIFIED_PAYLOAD_BYTES[recovery.recovery_dtbo]}" == 39063 ]] \
    || die "staged boot images do not retain the exact stock DT/DTBO payloads"
cleanup_boot_verify
trap - EXIT

declare -A expected_owned_repo_path=(
    [work]=work
    [device]=lineage-17.1/device/xsh/k50sv1_64_bsp
    [vendor]=lineage-17.1/vendor/xsh/k50sv1_64_bsp
    [kernel]=lineage-17.1/kernel/xsh/k50sv1_64_bsp
    [gapps]=lineage-17.1/vendor/gapps
    [google_webview]=lineage-17.1/vendor/google_webview
    [huawei_hms]=lineage-17.1/vendor/huawei/hms
)
for repo_label in work device vendor kernel gapps google_webview huawei_hms; do
    repo_path="$(manifest_get_exact "repo.${repo_label}.path" "${SOURCE_STATE}")"
    repo_head="$(manifest_get_exact "repo.${repo_label}.head" "${SOURCE_STATE}")"
    repo_tree="$(manifest_get_exact "repo.${repo_label}.tree" "${SOURCE_STATE}")"
    repo_dirty="$(manifest_get_exact "repo.${repo_label}.dirty" "${SOURCE_STATE}")"
    [[ "${repo_path}" == "${expected_owned_repo_path[${repo_label}]}" && \
       "${repo_head}" =~ ^[0-9a-f]{40,64}$ && \
       "${repo_tree}" =~ ^[0-9a-f]{40,64}$ && \
       "${repo_dirty}" == false ]] \
        || die "build source state has invalid ${repo_label} repository provenance"
    for repo_field in path head tree dirty; do
        [[ "$(manifest_get_exact "repo.${repo_label}.${repo_field}" "${SOURCE}")" == \
           "$(manifest_get_exact "repo.${repo_label}.${repo_field}" "${SOURCE_STATE}")" ]] \
            || die "SOURCE-MANIFEST disagrees about ${repo_label}.${repo_field}"
    done
done
for revision_label in work device vendor kernel; do
    [[ "$(manifest_get_exact "revision.${revision_label}" "${SOURCE}")" == \
       "$(manifest_get_exact "repo.${revision_label}.head" "${SOURCE_STATE}")" ]] \
        || die "SOURCE-MANIFEST legacy revision disagrees about ${revision_label}"
done

declare -A expected_apn_path=(
    [default]=lineage-17.1/vendor/lineage/prebuilt/common/etc/apns-conf.xml
    [override]=lineage-17.1/device/xsh/k50sv1_64_bsp/configs/apns-conf.xml
    [merge_tool]=lineage-17.1/vendor/lineage/tools/custom_apns.py
)
for apn_input in default override merge_tool; do
    apn_path="$(manifest_get_exact "apns.${apn_input}_path" "${SOURCE_STATE}")"
    apn_digest="$(manifest_get_exact "apns.${apn_input}_sha256" "${SOURCE_STATE}")"
    [[ "${apn_path}" == "${expected_apn_path[${apn_input}]}" && \
       "${apn_digest}" =~ ^[0-9a-f]{64}$ && \
       "$(manifest_get_exact "apns.${apn_input}_path" "${SOURCE}")" == \
            "${apn_path}" && \
       "$(manifest_get_exact "apns.${apn_input}_sha256" "${SOURCE}")" == \
            "${apn_digest}" ]] \
        || die "source bundle does not bind the ${apn_input} APN input"
done
PRODUCT_APNS_SHA="$(manifest_get_exact image.product_apns_sha256 "${SOURCE}")"
[[ "${PRODUCT_APNS_SHA}" =~ ^[0-9a-f]{64}$ && \
   "$(manifest_get_exact apns.merged_sha256 "${SOURCE_STATE}")" == \
        "${PRODUCT_APNS_SHA}" && \
   "$(manifest_get_exact apns.merged_sha256 "${SOURCE}")" == \
        "${PRODUCT_APNS_SHA}" ]] \
    || die "staged product APNs do not bind the validated merged digest"
for receipt_tool_field in \
    capture_build_inputs run_lineage_build stage_tier_images \
    check_wfc_framework_resource prepare_tier3_keyset \
    verify_tier3_properties verify_tier3_keyset_manifest \
    check_module_abi; do
    [[ "$(manifest_get_exact "tool.${receipt_tool_field}_sha256" "${RECEIPT}")" == \
       "$(manifest_get_exact "tool.${receipt_tool_field}_sha256" "${SOURCE}")" ]] \
        || die "receipt/source tool digest mismatch: ${receipt_tool_field}"
done

for image in boot recovery system vendor; do
    [[ "$(manifest_get_exact "image.${image}.sha256" "${RECEIPT}")" == \
            "$(manifest_get_exact "image.${image}.sha256" "${SOURCE}")" && \
       "$(manifest_get_exact "image.${image}.bytes" "${RECEIPT}")" == \
            "$(manifest_get_exact "image.${image}.bytes" "${SOURCE}")" ]] \
        || die "build receipt disagrees about ${image}.img"
done

PUBLIC_FINGERPRINT="$(manifest_get_exact image.build_fingerprint "${SOURCE}")"
SYSTEM_FINGERPRINT="$(manifest_get_exact image.system_build_fingerprint "${SOURCE}")"
VENDOR_FINGERPRINT="$(manifest_get_exact image.vendor_build_fingerprint "${SOURCE}")"
BOOT_FINGERPRINT="$(manifest_get_exact image.bootimage_build_fingerprint "${SOURCE}")"
if [[ "${TIER}" == 3 ]]; then
    REAL_TAGS=release-keys
else
    REAL_TAGS=test-keys
fi
REAL_FINGERPRINT_PATTERN="^XSH/lineage_k50sv1_64_bsp/k50sv1_64_bsp:10/QQ3A\\.200805\\.001/[0-9A-Za-z._-]+:${VARIANT}/${REAL_TAGS}$"
[[ "${PUBLIC_FINGERPRINT}" == \
   google/coral/coral:10/QQ3A.200805.001/6578210:user/release-keys && \
   "${SYSTEM_FINGERPRINT}" == "${VENDOR_FINGERPRINT}" && \
   "${SYSTEM_FINGERPRINT}" == "${BOOT_FINGERPRINT}" && \
   "${SYSTEM_FINGERPRINT}" != "${PUBLIC_FINGERPRINT}" && \
   "${SYSTEM_FINGERPRINT}" =~ ${REAL_FINGERPRINT_PATTERN} ]] \
    || die "public/real identity boundary is inconsistent"
[[ "$(manifest_get_exact image.android_release "${SOURCE}")" == 10 && \
   "$(manifest_get_exact image.android_sdk "${SOURCE}")" == 29 && \
   "$(manifest_get_exact image.lineage_version "${SOURCE}")" == 17.1 && \
   "$(manifest_get_exact image.lineage_device "${SOURCE}")" == k50sv1_64_bsp && \
   "$(manifest_get_exact image.platform_security_patch "${SOURCE}")" == 2023-02-05 && \
   "$(manifest_get_exact image.vendor_security_patch "${SOURCE}")" == 2020-08-05 && \
   "$(manifest_get_exact image.first_api_level "${SOURCE}")" == 26 ]] \
    || die "Android/Lineage/SPL/launch-API identity is inconsistent"
[[ "$(manifest_get_exact tool.verify_stage_contract_sha256 "${SOURCE}")" == \
   "$(file_sha256 "${TOOL_PATH}")" ]] \
    || die "stage-contract verifier differs from the tool bound at staging time"
[[ "$(manifest_get_exact tool.verify_tier3_keyset_manifest_sha256 "${SOURCE}")" == \
   "$(file_sha256 "${KEYSET_MANIFEST_VERIFY_TOOL}")" ]] \
    || die "Tier-3 keyset verifier differs from the tool bound at staging time"
[[ "$(manifest_get_exact tool.check_module_abi_sha256 "${SOURCE}")" == \
   "$(file_sha256 "${KERNEL_ABI_CHECK_TOOL}")" ]] \
    || die "source-kernel ABI verifier differs from the tool bound at build time"
[[ "$(manifest_get_exact tool.check_launcher_policy_sha256 "${SOURCE}")" == \
   "$(file_sha256 "${LAUNCHER_POLICY_TOOL}")" ]] \
    || die "launcher policy checker differs from the tool bound at staging time"

STAGE_CONTRACT_SHA="$(file_sha256 "${STAGE_DIR}/STAGE-CONTRACT")"
[[ "${STAGE_CONTRACT_SHA}" =~ ^[0-9a-f]{64}$ ]] \
    || die "could not derive top-level stage digest"

printf 'stage_contract_sha256=%s\n' "${STAGE_CONTRACT_SHA}"
printf 'source_manifest_sha256=%s\n' "$(file_sha256 "${SOURCE}")"
printf 'build_receipt_sha256=%s\n' "$(file_sha256 "${RECEIPT}")"
printf 'tier=%s\n' "${TIER}"
printf 'variant=%s\n' "${VARIANT}"
printf 'public_fingerprint=%s\n' "${PUBLIC_FINGERPRINT}"
printf 'system_fingerprint=%s\n' "${SYSTEM_FINGERPRINT}"
printf 'product_apns_sha256=%s\n' "${PRODUCT_APNS_SHA}"
printf 'release_keyset_sha256=%s\n' "${SOURCE_RELEASE_KEYSET_SHA}"
printf 'kernel_image_gz_sha256=%s\n' "${RECEIPT_KERNEL_IMAGE_SHA}"
printf 'boot_dtb_sha256=%s\n' "${VERIFIED_PAYLOAD_SHA[boot.dtb]}"
printf 'recovery_dtbo_sha256=%s\n' \
    "${VERIFIED_PAYLOAD_SHA[recovery.recovery_dtbo]}"
printf 'build_incremental=%s\n' \
    "$(manifest_get_exact image.build_incremental "${SOURCE}")"
printf 'status=PASS\n'
