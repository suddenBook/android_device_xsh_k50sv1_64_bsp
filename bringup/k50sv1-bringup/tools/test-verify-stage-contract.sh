#!/usr/bin/env bash
# Disposable relational/fixity fixtures for verify-stage-contract.sh.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY="${TOOL_DIR}/verify-stage-contract.sh"
KEYSET_VERIFY="${TOOL_DIR}/verify-tier3-keyset-manifest.sh"
KEYSET_PREPARE="${TOOL_DIR}/prepare-tier3-keyset.sh"
PROPERTIES_VERIFY="${TOOL_DIR}/verify-tier3-signed-properties.sh"
KERNEL_ABI_VERIFY="${TOOL_DIR}/kernel/check-module-abi.sh"
MKBOOTIMG="$(command -v mkbootimg || true)"
UNPACK_BOOTIMG="$(command -v unpack_bootimg || true)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
IMG2SIMG="$(command -v img2simg || true)"
SIMG2IMG="${PROJECT_ROOT}/lineage-17.1/out/host/linux-x86/bin/simg2img"
CROSS_STRIP="${PROJECT_ROOT}/lineage-17.1/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android-strip"
CONNECTIVITY_MODULES=(wmt_drv wmt_chrdev_wifi wlan_drv_gen2 bt_drv gps_drv)
declare -A SOURCE_MODULE_PATH=(
    [wmt_drv]=common/wmt_drv.ko
    [wmt_chrdev_wifi]=wlan/adaptor/wmt_chrdev_wifi.ko
    [wlan_drv_gen2]=wlan/core/gen2/wlan_drv_gen2.ko
    [bt_drv]=bt/legacy/bt_drv.ko
    [gps_drv]=gps/gps_drv.ko
)
KERNEL_MODULE_RECEIPT_KEYS=(
    kernel.module_mode kernel.module_install kernel.module_strip_tool_sha256
    kernel.module_signature kernel.module_invariant_errors
    kernel.undefined_symbols kernel.versioned_imports
    kernel.module_exports kernel.candidate_exports_ok
)
for module in "${CONNECTIVITY_MODULES[@]}"; do
    for field in path sha256 bytes installed_sha256 installed_bytes; do
        KERNEL_MODULE_RECEIPT_KEYS+=("kernel.module.${module}.${field}")
    done
done
STOCK_DTB="${PROJECT_ROOT}/lineage-17.1/device/xsh/k50sv1_64_bsp/prebuilt/dtb/stock.dtb"
STOCK_RECOVERY_DTBO="${PROJECT_ROOT}/lineage-17.1/device/xsh/k50sv1_64_bsp/prebuilt/recovery_dtbo"
TEST_ROOT="$(mktemp -d /tmp/k50-stage-contract-test.XXXXXX)"

[[ -x "${MKBOOTIMG}" && -x "${UNPACK_BOOTIMG}" && \
   -x "${KERNEL_ABI_VERIFY}" && -x "${IMG2SIMG}" && -x "${SIMG2IMG}" && \
   -x "${CROSS_STRIP}" ]] \
    || { printf 'boot-image/ABI fixture tools are unavailable\n' >&2; exit 2; }
[[ -f "${STOCK_DTB}" && ! -L "${STOCK_DTB}" && \
   -f "${STOCK_RECOVERY_DTBO}" && ! -L "${STOCK_RECOVERY_DTBO}" ]] \
    || { printf 'stock DT fixture inputs are unavailable\n' >&2; exit 2; }

cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-stage-contract-test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT

file_sha() { sha256sum "$1" | awk '{ print $1 }'; }

OWNED_REPO_LABELS=(work device vendor kernel gapps google_webview huawei_hms)
declare -A OWNED_REPO_PATH=(
    [work]=work
    [device]=lineage-17.1/device/xsh/k50sv1_64_bsp
    [vendor]=lineage-17.1/vendor/xsh/k50sv1_64_bsp
    [kernel]=lineage-17.1/kernel/xsh/k50sv1_64_bsp
    [gapps]=lineage-17.1/vendor/gapps
    [google_webview]=lineage-17.1/vendor/google_webview
    [huawei_hms]=lineage-17.1/vendor/huawei/hms
)

manifest_put() {
    printf '%s=%s\n' "$1" "$2" >>"$3"
}

refresh_source_and_contract() {
    local directory="$1"
    (
        cd "${directory}"
        sha256sum SOURCE-MANIFEST >SOURCE-MANIFEST.sha256
        contract_files=(
            SHA256SUMS SOURCE-MANIFEST SOURCE-MANIFEST.sha256
            K50SV1-BUILD-RECEIPT K50SV1-BUILD-SOURCE-STATE
            K50SV1-ANDROID-REPO-MANIFEST.xml
        )
        [[ ! -f K50SV1-RELEASE-KEYSET ]] \
            || contract_files+=(K50SV1-RELEASE-KEYSET)
        sha256sum "${contract_files[@]}" >STAGE-CONTRACT
        sha256sum STAGE-CONTRACT >STAGE-CONTRACT.sha256
    )
}

refresh_contract_only() {
    local directory="$1"
    (
        cd "${directory}"
        contract_files=(
            SHA256SUMS SOURCE-MANIFEST SOURCE-MANIFEST.sha256
            K50SV1-BUILD-RECEIPT K50SV1-BUILD-SOURCE-STATE
            K50SV1-ANDROID-REPO-MANIFEST.xml
        )
        [[ ! -f K50SV1-RELEASE-KEYSET ]] \
            || contract_files+=(K50SV1-RELEASE-KEYSET)
        sha256sum "${contract_files[@]}" >STAGE-CONTRACT
        sha256sum STAGE-CONTRACT >STAGE-CONTRACT.sha256
    )
}

delete_field() {
    local manifest="$1"
    local key="$2"
    local temporary="${manifest}.delete"
    awk -v key="${key}" 'index($0, key "=") == 1 { next } { print }' \
        "${manifest}" >"${temporary}"
    mv -T "${temporary}" "${manifest}"
}

replace_field() {
    local manifest="$1"
    local key="$2"
    local value="$3"
    local temporary="${manifest}.replace"
    awk -v key="${key}" -v value="${value}" '
        index($0, key "=") == 1 { print key "=" value; next }
        { print }
    ' "${manifest}" >"${temporary}"
    mv -T "${temporary}" "${manifest}"
}

repack_fixture_payload() {
    local directory="$1"
    local image="$2"
    local payload="$3"
    local repack_tmp tier variant cmdline output
    local -a repack_args

    repack_tmp="$(mktemp -d /tmp/k50-stage-repack.XXXXXX)"
    "${UNPACK_BOOTIMG}" --boot_img "${directory}/${image}.img" \
        --out "${repack_tmp}" --format info >"${repack_tmp}/info"
    [[ -f "${repack_tmp}/${payload}" && ! -L "${repack_tmp}/${payload}" ]] \
        || { printf 'fixture cannot mutate %s.%s\n' "${image}" "${payload}" >&2; return 1; }
    printf 'hostile-%s-%s\n' "${image}" "${payload}" >>"${repack_tmp}/${payload}"
    tier="$(awk -F= '$1 == "tier" { print $2 }' "${directory}/SOURCE-MANIFEST")"
    variant="$(awk -F= '$1 == "variant" { print $2 }' "${directory}/SOURCE-MANIFEST")"
    cmdline="buildvariant=${variant}"
    [[ "${tier}" != 1 ]] || cmdline+=" androidboot.selinux=permissive"
    output="${repack_tmp}/${image}.img"
    repack_args=(
        --kernel "${repack_tmp}/kernel"
        --ramdisk "${repack_tmp}/ramdisk"
        --dtb "${repack_tmp}/dtb"
        --header_version 2 --pagesize 2048
        --os_version 10.0.0 --os_patch_level 2023-02
        --cmdline "${cmdline}" --output "${output}"
    )
    if [[ "${image}" == recovery ]]; then
        repack_args+=(--recovery_dtbo "${repack_tmp}/recovery_dtbo")
    fi
    "${MKBOOTIMG}" "${repack_args[@]}"
    mv -T "${output}" "${directory}/${image}.img"
    find "${repack_tmp}" -mindepth 1 -depth -delete
    rmdir "${repack_tmp}"
}

refresh_image_payload_contract() {
    local directory="$1"
    local refresh_tmp image payload payload_key source receipt

    source="${directory}/SOURCE-MANIFEST"
    receipt="${directory}/K50SV1-BUILD-RECEIPT"
    refresh_tmp="$(mktemp -d /tmp/k50-stage-payload-refresh.XXXXXX)"
    for image in boot recovery; do
        mkdir "${refresh_tmp}/${image}"
        "${UNPACK_BOOTIMG}" --boot_img "${directory}/${image}.img" \
            --out "${refresh_tmp}/${image}" --format info \
            >"${refresh_tmp}/${image}.info"
        for payload in kernel ramdisk dtb; do
            payload_key="payload.${image}.${payload}"
            replace_field "${source}" "${payload_key}.sha256" \
                "$(file_sha "${refresh_tmp}/${image}/${payload}")"
            replace_field "${source}" "${payload_key}.bytes" \
                "$(stat -c %s "${refresh_tmp}/${image}/${payload}")"
        done
    done
    replace_field "${source}" payload.recovery.recovery_dtbo.sha256 \
        "$(file_sha "${refresh_tmp}/recovery/recovery_dtbo")"
    replace_field "${source}" payload.recovery.recovery_dtbo.bytes \
        "$(stat -c %s "${refresh_tmp}/recovery/recovery_dtbo")"
    (
        cd "${directory}"
        sha256sum boot.img recovery.img system.img vendor.img >SHA256SUMS
    )
    for image in boot recovery system vendor; do
        replace_field "${receipt}" "image.${image}.sha256" \
            "$(file_sha "${directory}/${image}.img")"
        replace_field "${receipt}" "image.${image}.bytes" \
            "$(stat -c %s "${directory}/${image}.img")"
        replace_field "${source}" "image.${image}.sha256" \
            "$(file_sha "${directory}/${image}.img")"
        replace_field "${source}" "image.${image}.bytes" \
            "$(stat -c %s "${directory}/${image}.img")"
    done
    replace_field "${source}" bundle.sha256sums_sha256 \
        "$(file_sha "${directory}/SHA256SUMS")"
    replace_field "${source}" bundle.build_receipt_sha256 \
        "$(file_sha "${receipt}")"
    find "${refresh_tmp}" -mindepth 1 -depth -delete
    rmdir "${refresh_tmp}"
    refresh_source_and_contract "${directory}"
}

write_bundle() {
    local directory="$1"
    local seed="$2"
    local tier="${3:-1}"
    local variant tags pipeline targets cmdline
    if [[ "${tier}" == 3 ]]; then
        variant=user
        tags=release-keys
        pipeline=tier3-signed-target-files
        targets=target-files-package,sign-target-files,boot,recovery,system,vendor
        cmdline="buildvariant=${variant}"
    else
        variant=userdebug
        tags=test-keys
        pipeline=android-four-image
        targets=bootimage,recoveryimage,systemimage,vendorimage
        cmdline="buildvariant=${variant} androidboot.selinux=permissive"
    fi
    local real_fingerprint="XSH/lineage_k50sv1_64_bsp/k50sv1_64_bsp:10/QQ3A.200805.001/${seed}:${variant}/${tags}"
    local incremental="eng.fixture.${seed}"
    local apn_merged_sha
    local verify_sha kernel_abi_sha payload_dir

    mkdir "${directory}"
    payload_dir="${TEST_ROOT}/payload-${seed}"
    mkdir "${payload_dir}"
    printf '%s-source-Image.gz\n' "${seed}" >"${payload_dir}/kernel"
    printf '%s-boot-ramdisk\n' "${seed}" >"${payload_dir}/boot-ramdisk"
    printf '%s-recovery-ramdisk\n' "${seed}" >"${payload_dir}/recovery-ramdisk"
    cp -- "${STOCK_DTB}" "${payload_dir}/stock.dtb"
    cp -- "${STOCK_RECOVERY_DTBO}" "${payload_dir}/recovery_dtbo"
    "${MKBOOTIMG}" --kernel "${payload_dir}/kernel" \
        --ramdisk "${payload_dir}/boot-ramdisk" \
        --dtb "${payload_dir}/stock.dtb" --header_version 2 --pagesize 2048 \
        --os_version 10.0.0 --os_patch_level 2023-02 \
        --cmdline "${cmdline}" --output "${directory}/boot.img"
    "${MKBOOTIMG}" --kernel "${payload_dir}/kernel" \
        --ramdisk "${payload_dir}/recovery-ramdisk" \
        --dtb "${payload_dir}/stock.dtb" \
        --recovery_dtbo "${payload_dir}/recovery_dtbo" \
        --header_version 2 --pagesize 2048 --os_version 10.0.0 \
        --os_patch_level 2023-02 --cmdline "${cmdline}" \
        --output "${directory}/recovery.img"
    printf '%s-system-image\n' "${seed}" >"${directory}/system.img"
    printf '%s-vendor-image\n' "${seed}" >"${directory}/vendor.img"
    printf '<manifest seed="%s"/>\n' "${seed}" \
        >"${directory}/K50SV1-ANDROID-REPO-MANIFEST.xml"
    repo_sha="$(file_sha "${directory}/K50SV1-ANDROID-REPO-MANIFEST.xml")"
    apn_merged_sha="$(printf '%s-merged-apns\n' "${seed}" | sha256sum | awk '{ print $1 }')"
    source_state="${directory}/K50SV1-BUILD-SOURCE-STATE"
    : >"${source_state}"
    manifest_put source_state.version 4 "${source_state}"
    manifest_put android_repo.project_count 1 "${source_state}"
    manifest_put android_repo.revision_manifest_sha256 "${repo_sha}" "${source_state}"
    for repo_label in "${OWNED_REPO_LABELS[@]}"; do
        manifest_put "repo.${repo_label}.path" \
            "${OWNED_REPO_PATH[${repo_label}]}" "${source_state}"
        manifest_put "repo.${repo_label}.head" "${repo_sha}" "${source_state}"
        manifest_put "repo.${repo_label}.tree" "${repo_sha}" "${source_state}"
        manifest_put "repo.${repo_label}.dirty" false "${source_state}"
    done
    manifest_put vendor_lineage.path lineage-17.1/vendor/lineage "${source_state}"
    manifest_put vendor_lineage.base_head "${repo_sha}" "${source_state}"
    manifest_put vendor_lineage.status_sha256 "${repo_sha}" "${source_state}"
    manifest_put vendor_lineage.font_diff_sha256 "${repo_sha}" "${source_state}"
    manifest_put vendor_lineage.font_result_sha256 "${repo_sha}" "${source_state}"
    manifest_put apns.default_path \
        lineage-17.1/vendor/lineage/prebuilt/common/etc/apns-conf.xml "${source_state}"
    manifest_put apns.default_sha256 "${repo_sha}" "${source_state}"
    manifest_put apns.override_path \
        lineage-17.1/device/xsh/k50sv1_64_bsp/configs/apns-conf.xml "${source_state}"
    manifest_put apns.override_sha256 "${repo_sha}" "${source_state}"
    manifest_put apns.merge_tool_path \
        lineage-17.1/vendor/lineage/tools/custom_apns.py "${source_state}"
    manifest_put apns.merge_tool_sha256 "${repo_sha}" "${source_state}"
    manifest_put apns.merged_sha256 "${apn_merged_sha}" "${source_state}"
    source_state_sha="$(file_sha "${directory}/K50SV1-BUILD-SOURCE-STATE")"
    verify_sha="$(file_sha "${VERIFY}")"
    kernel_abi_sha="$(file_sha "${KERNEL_ABI_VERIFY}")"

    receipt="${directory}/K50SV1-BUILD-RECEIPT"
    : >"${receipt}"
    manifest_put receipt.version 4 "${receipt}"
    manifest_put product k50sv1_64_bsp "${receipt}"
    manifest_put tier "${tier}" "${receipt}"
    manifest_put variant "${variant}" "${receipt}"
    manifest_put pipeline "${pipeline}" "${receipt}"
    manifest_put build.targets "${targets}" "${receipt}"
    manifest_put build.clean_output true "${receipt}"
    manifest_put build.started_at_utc 2026-09-01T00:00:00Z "${receipt}"
    manifest_put build.completed_at_utc 2026-09-01T00:00:01Z "${receipt}"
    manifest_put build.real_fingerprint "${real_fingerprint}" "${receipt}"
    manifest_put build.incremental "${incremental}" "${receipt}"
    manifest_put source_state.file K50SV1-BUILD-SOURCE-STATE "${receipt}"
    manifest_put source_state.sha256 "${source_state_sha}" "${receipt}"
    manifest_put android_repo_manifest.file K50SV1-ANDROID-REPO-MANIFEST.xml "${receipt}"
    manifest_put android_repo_manifest.sha256 "${repo_sha}" "${receipt}"
    manifest_put release_keyset.file none "${receipt}"
    manifest_put release_keyset.sha256 none "${receipt}"
    manifest_put tool.capture_build_inputs_sha256 "${verify_sha}" "${receipt}"
    manifest_put tool.run_lineage_build_sha256 "${verify_sha}" "${receipt}"
    manifest_put tool.stage_tier_images_sha256 "${verify_sha}" "${receipt}"
    manifest_put tool.check_wfc_framework_resource_sha256 "${verify_sha}" "${receipt}"
    manifest_put tool.prepare_tier3_keyset_sha256 \
        "$(file_sha "${KEYSET_PREPARE}")" "${receipt}"
    manifest_put tool.verify_tier3_properties_sha256 \
        "$(file_sha "${PROPERTIES_VERIFY}")" "${receipt}"
    manifest_put tool.verify_tier3_keyset_manifest_sha256 \
        "$(file_sha "${KEYSET_VERIFY}")" "${receipt}"
    manifest_put kernel.image_gz.path arch/arm64/boot/Image.gz "${receipt}"
    manifest_put kernel.image_gz.sha256 "$(file_sha "${payload_dir}/kernel")" "${receipt}"
    manifest_put kernel.image_gz.bytes "$(stat -c %s "${payload_dir}/kernel")" "${receipt}"
    for kernel_artifact in config module_symvers vmlinux; do
        printf '%s-%s\n' "${seed}" "${kernel_artifact}" \
            >"${payload_dir}/${kernel_artifact}"
        case "${kernel_artifact}" in
            config) kernel_artifact_path=.config ;;
            module_symvers) kernel_artifact_path=Module.symvers ;;
            vmlinux) kernel_artifact_path=vmlinux ;;
        esac
        manifest_put "kernel.${kernel_artifact}.path" \
            "${kernel_artifact_path}" "${receipt}"
        manifest_put "kernel.${kernel_artifact}.sha256" \
            "$(file_sha "${payload_dir}/${kernel_artifact}")" "${receipt}"
        manifest_put "kernel.${kernel_artifact}.bytes" \
            "$(stat -c %s "${payload_dir}/${kernel_artifact}")" "${receipt}"
    done
    manifest_put kernel.mode source "${receipt}"
    manifest_put kernel.image_name Image.gz "${receipt}"
    manifest_put kernel.abi.status PASS "${receipt}"
    manifest_put kernel.abi.metadata_errors 0 "${receipt}"
    manifest_put kernel.abi.module_signature_compatible yes "${receipt}"
    manifest_put kernel.uts_release 3.18.119 "${receipt}"
    manifest_put kernel.vermagic \
        '3.18.119 SMP preempt mod_unload modversions aarch64' "${receipt}"
    manifest_put kernel.module_layout a415c974@vmlinux "${receipt}"
    manifest_put kernel.module_layout_vmlinux \
        a415c974@__crc_module_layout "${receipt}"
    manifest_put kernel.modules 5 "${receipt}"
    manifest_put kernel.expected_pairs 369 "${receipt}"
    manifest_put kernel.builtin_expected 340 "${receipt}"
    manifest_put kernel.inter_module_expected 29 "${receipt}"
    manifest_put kernel.module_inter_ok 29 "${receipt}"
    manifest_put kernel.candidate_builtin_ok 340 "${receipt}"
    manifest_put kernel.candidate_inter_ok 29 "${receipt}"
    manifest_put kernel.module_mode source "${receipt}"
    manifest_put kernel.module_install strip-debug "${receipt}"
    manifest_put kernel.module_strip_tool_sha256 "$(file_sha "${CROSS_STRIP}")" "${receipt}"
    manifest_put kernel.module_signature unsigned "${receipt}"
    manifest_put kernel.module_invariant_errors 0 "${receipt}"
    manifest_put kernel.undefined_symbols 563 "${receipt}"
    manifest_put kernel.versioned_imports 568 "${receipt}"
    manifest_put kernel.module_exports 109 "${receipt}"
    manifest_put kernel.candidate_exports_ok 109 "${receipt}"
    # This relational fixture models a prior ABI pass. The ABI test suite
    # independently validates real ELF inputs and strip-debug projection.
    local module_tree="${payload_dir}/vendor-tree" module raw_module installed_module
    mkdir -p "${module_tree}/lib/modules"
    for module in "${CONNECTIVITY_MODULES[@]}"; do
        raw_module="${payload_dir}/${module}.raw"
        installed_module="${module_tree}/lib/modules/${module}.ko"
        printf '%s-%s-built\n' "${seed}" "${module}" >"${raw_module}"
        printf '%s-%s-installed\n' "${seed}" "${module}" >"${installed_module}"
        manifest_put "kernel.module.${module}.path" \
            "drivers/misc/mediatek/connectivity/source/${SOURCE_MODULE_PATH[${module}]}" "${receipt}"
        manifest_put "kernel.module.${module}.sha256" "$(file_sha "${raw_module}")" "${receipt}"
        manifest_put "kernel.module.${module}.bytes" "$(stat -c %s "${raw_module}")" "${receipt}"
        manifest_put "kernel.module.${module}.installed_sha256" "$(file_sha "${installed_module}")" "${receipt}"
        manifest_put "kernel.module.${module}.installed_bytes" "$(stat -c %s "${installed_module}")" "${receipt}"
    done
    truncate -s 16M "${payload_dir}/vendor.raw"
    mke2fs -q -t ext4 -F -d "${module_tree}" "${payload_dir}/vendor.raw"
    "${IMG2SIMG}" "${payload_dir}/vendor.raw" "${directory}/vendor.img"
    manifest_put tool.check_module_abi_sha256 "${kernel_abi_sha}" "${receipt}"
    for image in boot recovery system vendor; do
        manifest_put "image.${image}.sha256" \
            "$(file_sha "${directory}/${image}.img")" "${receipt}"
        manifest_put "image.${image}.bytes" \
            "$(stat -c %s "${directory}/${image}.img")" "${receipt}"
    done

    (
        cd "${directory}"
        sha256sum boot.img recovery.img system.img vendor.img >SHA256SUMS
    )
    source_manifest="${directory}/SOURCE-MANIFEST"
    : >"${source_manifest}"
    manifest_put manifest.version 7 "${source_manifest}"
    manifest_put product k50sv1_64_bsp "${source_manifest}"
    manifest_put tier "${tier}" "${source_manifest}"
    manifest_put variant "${variant}" "${source_manifest}"
    manifest_put staged_at_utc 2026-09-01T00:00:02Z "${source_manifest}"
    manifest_put bundle.sha256sums_file SHA256SUMS "${source_manifest}"
    manifest_put bundle.sha256sums_sha256 \
        "$(file_sha "${directory}/SHA256SUMS")" "${source_manifest}"
    manifest_put bundle.build_receipt_file K50SV1-BUILD-RECEIPT "${source_manifest}"
    manifest_put bundle.build_receipt_sha256 "$(file_sha "${receipt}")" "${source_manifest}"
    manifest_put bundle.build_source_state_file K50SV1-BUILD-SOURCE-STATE "${source_manifest}"
    manifest_put bundle.build_source_state_sha256 "${source_state_sha}" "${source_manifest}"
    manifest_put bundle.android_repo_manifest_file K50SV1-ANDROID-REPO-MANIFEST.xml "${source_manifest}"
    manifest_put bundle.android_repo_manifest_sha256 "${repo_sha}" "${source_manifest}"
    manifest_put bundle.release_keyset_file none "${source_manifest}"
    manifest_put bundle.release_keyset_sha256 none "${source_manifest}"
    manifest_put image.build_fingerprint \
        google/coral/coral:10/QQ3A.200805.001/6578210:user/release-keys \
        "${source_manifest}"
    manifest_put image.system_build_fingerprint "${real_fingerprint}" "${source_manifest}"
    manifest_put image.vendor_build_fingerprint "${real_fingerprint}" "${source_manifest}"
    manifest_put image.bootimage_build_fingerprint "${real_fingerprint}" "${source_manifest}"
    manifest_put image.build_incremental "${incremental}" "${source_manifest}"
    manifest_put image.build_id QQ3A.200805.001 "${source_manifest}"
    manifest_put image.build_description \
        'coral-user 10 QQ3A.200805.001 6578210 release-keys' "${source_manifest}"
    manifest_put image.android_release 10 "${source_manifest}"
    manifest_put image.android_sdk 29 "${source_manifest}"
    manifest_put image.lineage_version 17.1 "${source_manifest}"
    manifest_put image.lineage_device k50sv1_64_bsp "${source_manifest}"
    manifest_put image.product_apns_sha256 "${apn_merged_sha}" "${source_manifest}"
    manifest_put image.platform_security_patch 2023-02-05 "${source_manifest}"
    manifest_put image.vendor_security_patch 2020-08-05 "${source_manifest}"
    manifest_put image.first_api_level 26 "${source_manifest}"
    manifest_put apns.default_path \
        lineage-17.1/vendor/lineage/prebuilt/common/etc/apns-conf.xml "${source_manifest}"
    manifest_put apns.default_sha256 "${repo_sha}" "${source_manifest}"
    manifest_put apns.override_path \
        lineage-17.1/device/xsh/k50sv1_64_bsp/configs/apns-conf.xml "${source_manifest}"
    manifest_put apns.override_sha256 "${repo_sha}" "${source_manifest}"
    manifest_put apns.merge_tool_path \
        lineage-17.1/vendor/lineage/tools/custom_apns.py "${source_manifest}"
    manifest_put apns.merge_tool_sha256 "${repo_sha}" "${source_manifest}"
    manifest_put apns.merged_sha256 "${apn_merged_sha}" "${source_manifest}"
    manifest_put android_repo.project_count 1 "${source_manifest}"
    manifest_put android_repo.revision_manifest_sha256 "${repo_sha}" "${source_manifest}"
    for repo_label in "${OWNED_REPO_LABELS[@]}"; do
        manifest_put "repo.${repo_label}.path" \
            "${OWNED_REPO_PATH[${repo_label}]}" "${source_manifest}"
        manifest_put "repo.${repo_label}.head" "${repo_sha}" "${source_manifest}"
        manifest_put "repo.${repo_label}.tree" "${repo_sha}" "${source_manifest}"
        manifest_put "repo.${repo_label}.dirty" false "${source_manifest}"
    done
    manifest_put vendor_lineage.path lineage-17.1/vendor/lineage "${source_manifest}"
    manifest_put vendor_lineage.base_head "${repo_sha}" "${source_manifest}"
    manifest_put vendor_lineage.status_sha256 "${repo_sha}" "${source_manifest}"
    manifest_put vendor_lineage.font_diff_sha256 "${repo_sha}" "${source_manifest}"
    manifest_put vendor_lineage.font_result_sha256 "${repo_sha}" "${source_manifest}"
    for revision_label in work device vendor kernel; do
        manifest_put "revision.${revision_label}" "${repo_sha}" "${source_manifest}"
    done
    manifest_put tool.apply_upstream_patches_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.capture_build_inputs_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.run_lineage_build_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.stage_tier_images_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.check_carrier_config_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.check_pixel_identity_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.check_launcher_policy_sha256 \
        "$(file_sha "${TOOL_DIR}/check-launcher-policy.py")" "${source_manifest}"
    manifest_put tool.check_wfc_framework_resource_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.verify_stage_contract_sha256 "${verify_sha}" "${source_manifest}"
    manifest_put tool.prepare_tier3_keyset_sha256 \
        "$(file_sha "${KEYSET_PREPARE}")" "${source_manifest}"
    manifest_put tool.verify_tier3_properties_sha256 \
        "$(file_sha "${PROPERTIES_VERIFY}")" "${source_manifest}"
    manifest_put tool.verify_tier3_keyset_manifest_sha256 \
        "$(file_sha "${KEYSET_VERIFY}")" "${source_manifest}"
    manifest_put tool.check_module_abi_sha256 "${kernel_abi_sha}" "${source_manifest}"
    manifest_put tool.flash_tier_images_sha256 "${verify_sha}" "${source_manifest}"
    for image in boot recovery system vendor; do
        manifest_put "image.${image}.sha256" \
            "$(file_sha "${directory}/${image}.img")" "${source_manifest}"
        manifest_put "image.${image}.bytes" \
            "$(stat -c %s "${directory}/${image}.img")" "${source_manifest}"
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
        manifest_put "${kernel_key}" \
            "$(awk -F= -v key="${kernel_key}" '$1 == key { print substr($0, length(key) + 2) }' \
                "${receipt}")" "${source_manifest}"
    done
    manifest_put payload.boot.kernel.sha256 \
        "$(file_sha "${payload_dir}/kernel")" "${source_manifest}"
    manifest_put payload.boot.kernel.bytes \
        "$(stat -c %s "${payload_dir}/kernel")" "${source_manifest}"
    manifest_put payload.boot.ramdisk.sha256 \
        "$(file_sha "${payload_dir}/boot-ramdisk")" "${source_manifest}"
    manifest_put payload.boot.ramdisk.bytes \
        "$(stat -c %s "${payload_dir}/boot-ramdisk")" "${source_manifest}"
    manifest_put payload.boot.dtb.sha256 \
        "$(file_sha "${payload_dir}/stock.dtb")" "${source_manifest}"
    manifest_put payload.boot.dtb.bytes \
        "$(stat -c %s "${payload_dir}/stock.dtb")" "${source_manifest}"
    manifest_put payload.recovery.kernel.sha256 \
        "$(file_sha "${payload_dir}/kernel")" "${source_manifest}"
    manifest_put payload.recovery.kernel.bytes \
        "$(stat -c %s "${payload_dir}/kernel")" "${source_manifest}"
    manifest_put payload.recovery.ramdisk.sha256 \
        "$(file_sha "${payload_dir}/recovery-ramdisk")" "${source_manifest}"
    manifest_put payload.recovery.ramdisk.bytes \
        "$(stat -c %s "${payload_dir}/recovery-ramdisk")" "${source_manifest}"
    manifest_put payload.recovery.dtb.sha256 \
        "$(file_sha "${payload_dir}/stock.dtb")" "${source_manifest}"
    manifest_put payload.recovery.dtb.bytes \
        "$(stat -c %s "${payload_dir}/stock.dtb")" "${source_manifest}"
    manifest_put payload.recovery.recovery_dtbo.sha256 \
        "$(file_sha "${payload_dir}/recovery_dtbo")" "${source_manifest}"
    manifest_put payload.recovery.recovery_dtbo.bytes \
        "$(stat -c %s "${payload_dir}/recovery_dtbo")" "${source_manifest}"
    refresh_source_and_contract "${directory}"
}

clone_bundle() {
    local name="$1"
    cp -a "${TEST_ROOT}/valid" "${TEST_ROOT}/${name}"
    printf '%s' "${TEST_ROOT}/${name}"
}

expect_fail() {
    local directory="$1"
    set +e
    "${VERIFY}" "${directory}" >"${directory}.out" 2>"${directory}.err"
    local rc=$?
    set -e
    [[ "${rc}" -eq 1 ]]
}

write_public_keyset() {
    local manifest="$1"
    : >"${manifest}"
    manifest_put keyset.version 1 "${manifest}"
    key_index=1
    for key_name in releasekey platform shared media networkstack bootsignature; do
        manifest_put "certificate.${key_name}.sha256" \
            "$(printf '%064d' "${key_index}")" "${manifest}"
        key_index=$((key_index + 1))
    done
    manifest_put apk.resigned_count 12 "${manifest}"
    manifest_put apk.presigned_count 7 "${manifest}"
    manifest_put apex.archive_count 0 "${manifest}"
    manifest_put apex.flattened_present true "${manifest}"
    manifest_put boot_signature.verified_count 2 "${manifest}"
    manifest_put ota_trust_certificate.sha256 "$(printf '%064d' 1)" "${manifest}"
    manifest_put posture.build_variant user "${manifest}"
    manifest_put posture.selinux enforcing "${manifest}"
    manifest_put posture.adb_default off "${manifest}"
    manifest_put posture.adb_when_enabled authenticated-nonroot "${manifest}"
    manifest_put posture.flash_locked 0 "${manifest}"
    manifest_put posture.verified_boot_state orange "${manifest}"
    manifest_put posture.verified_boot absent "${manifest}"
    manifest_put posture.rollback_protection absent "${manifest}"
    manifest_put posture.encryption absent "${manifest}"
    manifest_put posture.ota_artifact not-produced "${manifest}"
}

write_bundle "${TEST_ROOT}/valid" fixture08262345
"${VERIFY}" "${TEST_ROOT}/valid" | grep -Fxq status=PASS

write_bundle "${TEST_ROOT}/valid-tier3" fixturetier3 3
tier3_dir="${TEST_ROOT}/valid-tier3"
tier3_fingerprint='XSH/lineage_k50sv1_64_bsp/k50sv1_64_bsp:10/QQ3A.200805.001/fixturetier3:user/release-keys'
replace_field "${tier3_dir}/K50SV1-BUILD-RECEIPT" tier 3
replace_field "${tier3_dir}/K50SV1-BUILD-RECEIPT" variant user
replace_field "${tier3_dir}/K50SV1-BUILD-RECEIPT" \
    build.real_fingerprint "${tier3_fingerprint}"
replace_field "${tier3_dir}/SOURCE-MANIFEST" tier 3
replace_field "${tier3_dir}/SOURCE-MANIFEST" variant user
for fingerprint_field in \
    image.system_build_fingerprint image.vendor_build_fingerprint \
    image.bootimage_build_fingerprint; do
    replace_field "${tier3_dir}/SOURCE-MANIFEST" \
        "${fingerprint_field}" "${tier3_fingerprint}"
done
write_public_keyset "${tier3_dir}/K50SV1-RELEASE-KEYSET"
tier3_keyset_sha="$(file_sha "${tier3_dir}/K50SV1-RELEASE-KEYSET")"
replace_field "${tier3_dir}/K50SV1-BUILD-RECEIPT" \
    release_keyset.file K50SV1-RELEASE-KEYSET
replace_field "${tier3_dir}/K50SV1-BUILD-RECEIPT" \
    release_keyset.sha256 "${tier3_keyset_sha}"
replace_field "${tier3_dir}/SOURCE-MANIFEST" \
    bundle.release_keyset_file K50SV1-RELEASE-KEYSET
replace_field "${tier3_dir}/SOURCE-MANIFEST" \
    bundle.release_keyset_sha256 "${tier3_keyset_sha}"
replace_field "${tier3_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${tier3_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${tier3_dir}"
"${VERIFY}" "${tier3_dir}" | grep -Fxq status=PASS

case_dir="$(clone_bundle tier3-keyset-posture)"
# clone_bundle is Tier 1; clone the complete valid Tier-3 fixture explicitly.
find "${case_dir}" -mindepth 1 -depth -delete
rmdir "${case_dir}"
cp -a "${tier3_dir}" "${case_dir}"
replace_field "${case_dir}/K50SV1-RELEASE-KEYSET" \
    posture.verified_boot present
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" release_keyset.sha256 \
    "$(file_sha "${case_dir}/K50SV1-RELEASE-KEYSET")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.release_keyset_sha256 \
    "$(file_sha "${case_dir}/K50SV1-RELEASE-KEYSET")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle image-tamper)"
printf 'tamper\n' >>"${case_dir}/system.img"
expect_fail "${case_dir}"

# Repack a structurally valid boot image with a different kernel, then update
# every whole-image and payload digest an untrusted bundle writer controls. It
# must still fail because the receipt-bound ABI-gated Image.gz did not change.
case_dir="$(clone_bundle embedded-kernel-mutation)"
repack_fixture_payload "${case_dir}" boot kernel
refresh_image_payload_contract "${case_dir}"
expect_fail "${case_dir}"

# Do the same for the header DT table. Even a self-consistent transitive bundle
# cannot replace the pinned stock DT authority.
case_dir="$(clone_bundle embedded-dt-mutation)"
repack_fixture_payload "${case_dir}" boot dtb
refresh_image_payload_contract "${case_dir}"
expect_fail "${case_dir}"

# Mutating one module_layout value on both manifests while rebuilding every
# outer digest must still fail its independent vmlinux CRC relationship.
case_dir="$(clone_bundle abi-module-layout-mutation)"
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" \
    kernel.module_layout deadbeef@vmlinux
replace_field "${case_dir}/SOURCE-MANIFEST" \
    kernel.module_layout deadbeef@vmlinux
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle installed-module-mutation)"
"${SIMG2IMG}" "${case_dir}/vendor.img" "${TEST_ROOT}/tamper-vendor.raw"
printf 'substituted source module\n' >"${TEST_ROOT}/tamper-module.ko"
debugfs -w -R 'rm /lib/modules/bt_drv.ko' "${TEST_ROOT}/tamper-vendor.raw" >/dev/null 2>&1
debugfs -w -R "write ${TEST_ROOT}/tamper-module.ko /lib/modules/bt_drv.ko" \
    "${TEST_ROOT}/tamper-vendor.raw" >/dev/null 2>&1
"${IMG2SIMG}" "${TEST_ROOT}/tamper-vendor.raw" "${case_dir}/vendor.img"
refresh_image_payload_contract "${case_dir}"
expect_fail "${case_dir}"
grep -Fq 'installed bt_drv.ko differs' "${case_dir}.err"

case_dir="$(clone_bundle module-count-mutation)"
for manifest in K50SV1-BUILD-RECEIPT SOURCE-MANIFEST; do
    replace_field "${case_dir}/${manifest}" kernel.expected_pairs 368
done
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle abi-status-mutation)"
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" \
    kernel.abi.status FAIL
replace_field "${case_dir}/SOURCE-MANIFEST" kernel.abi.status FAIL
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

# A self-consistent receipt/source rewrite cannot substitute a different ABI
# checker for the exact implementation that established the build result.
case_dir="$(clone_bundle abi-checker-mutation)"
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" \
    tool.check_module_abi_sha256 \
    6666666666666666666666666666666666666666666666666666666666666666
replace_field "${case_dir}/SOURCE-MANIFEST" \
    tool.check_module_abi_sha256 \
    6666666666666666666666666666666666666666666666666666666666666666
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle checksum-swap)"
replace_field "${case_dir}/SHA256SUMS" deadbeef ignored 2>/dev/null || true
printf '%064d  system.img\n' 0 >"${case_dir}/SHA256SUMS"
refresh_contract_only "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle launcher-checker-mutation)"
replace_field "${case_dir}/SOURCE-MANIFEST" tool.check_launcher_policy_sha256 \
    6666666666666666666666666666666666666666666666666666666666666666
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"
grep -Fq 'launcher policy checker differs' "${case_dir}.err"

case_dir="$(clone_bundle source-checksum-link)"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.sha256sums_sha256 \
    0000000000000000000000000000000000000000000000000000000000000000
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle receipt-image)"
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" image.vendor.sha256 \
    1111111111111111111111111111111111111111111111111111111111111111
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle source-repo-link)"
replace_field "${case_dir}/K50SV1-BUILD-SOURCE-STATE" \
    android_repo.revision_manifest_sha256 \
    2222222222222222222222222222222222222222222222222222222222222222
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" source_state.sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-SOURCE-STATE")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_source_state_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-SOURCE-STATE")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle source-kernel-provenance)"
replace_field "${case_dir}/K50SV1-BUILD-SOURCE-STATE" \
    repo.kernel.dirty true
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" source_state.sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-SOURCE-STATE")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_source_state_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-SOURCE-STATE")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle source-manifest-kernel-link)"
replace_field "${case_dir}/SOURCE-MANIFEST" repo.kernel.tree \
    3333333333333333333333333333333333333333333333333333333333333333
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle source-manifest-kernel-revision)"
replace_field "${case_dir}/SOURCE-MANIFEST" revision.kernel \
    3333333333333333333333333333333333333333333333333333333333333333
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle apn-source-link)"
replace_field "${case_dir}/K50SV1-BUILD-SOURCE-STATE" \
    apns.override_sha256 \
    4444444444444444444444444444444444444444444444444444444444444444
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" source_state.sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-SOURCE-STATE")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_source_state_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-SOURCE-STATE")"
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle apn-merged-link)"
replace_field "${case_dir}/SOURCE-MANIFEST" image.product_apns_sha256 \
    5555555555555555555555555555555555555555555555555555555555555555
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle tier-mismatch)"
replace_field "${case_dir}/SOURCE-MANIFEST" tier 2
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle android-release)"
replace_field "${case_dir}/SOURCE-MANIFEST" image.android_release 11
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle platform-spl)"
replace_field "${case_dir}/SOURCE-MANIFEST" \
    image.platform_security_patch 2099-12-31
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle first-api)"
replace_field "${case_dir}/SOURCE-MANIFEST" image.first_api_level 29
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle identity-collapse)"
replace_field "${case_dir}/SOURCE-MANIFEST" image.system_build_fingerprint \
    google/coral/coral:10/QQ3A.200805.001/6578210:user/release-keys
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

case_dir="$(clone_bundle tool-relation)"
replace_field "${case_dir}/K50SV1-BUILD-RECEIPT" \
    tool.capture_build_inputs_sha256 \
    3333333333333333333333333333333333333333333333333333333333333333
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"

# Delete one tool digest from BOTH manifests. manifest_get_exact `die`s in each
# command-substitution subshell and returns "", the receipt/source comparison
# then reads `[[ "" == "" ]]`, and the tool used to print status=PASS with the
# two diagnostics already on stderr. Absent from both sides is the case a
# one-sided mutation cannot reach.
case_dir="$(clone_bundle tool-absent-both)"
delete_field "${case_dir}/K50SV1-BUILD-RECEIPT" tool.stage_tier_images_sha256
delete_field "${case_dir}/SOURCE-MANIFEST" tool.stage_tier_images_sha256
replace_field "${case_dir}/SOURCE-MANIFEST" bundle.build_receipt_sha256 \
    "$(file_sha "${case_dir}/K50SV1-BUILD-RECEIPT")"
refresh_source_and_contract "${case_dir}"
expect_fail "${case_dir}"
grep -Fq 'status=PASS' "${case_dir}.out" \
    && { printf 'a stage missing a tool digest on both sides still printed PASS\n' >&2
         exit 1; }

write_bundle "${TEST_ROOT}/other" other08262346
case_dir="$(clone_bundle swapped-source)"
cp "${TEST_ROOT}/other/SOURCE-MANIFEST" "${case_dir}/SOURCE-MANIFEST"
cp "${TEST_ROOT}/other/SOURCE-MANIFEST.sha256" "${case_dir}/SOURCE-MANIFEST.sha256"
refresh_contract_only "${case_dir}"
expect_fail "${case_dir}"

printf 'K50 STAGE CONTRACT RELATIONAL FIXTURE MATRIX: PASS\n'
