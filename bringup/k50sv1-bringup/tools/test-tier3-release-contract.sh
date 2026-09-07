#!/usr/bin/env bash
# Synthetic signed-target-files and public-manifest hostile fixtures.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VERIFY_PROPERTIES="${TOOL_DIR}/verify-tier3-signed-properties.sh"
VERIFY_KEYSET="${TOOL_DIR}/verify-tier3-keyset-manifest.sh"
TEST_ROOT="$(mktemp -d /tmp/k50-tier3-release-test.XXXXXX)"

cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-tier3-release-test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT

write_property_file() {
    local path="$1"
    mkdir -p "$(dirname "${path}")"
    printf '%s\n' \
        'ro.secure=1' \
        'ro.debuggable=0' \
        'ro.adb.secure=1' \
        'persist.sys.usb.config=mtp' \
        'ro.allow.mock.location=0' \
        'ro.control_privapp_permissions=enforce' \
        'persist.dbg.wfc_avail_ovr=0' \
        'persist.dbg.wfc_avail_ovr0=0' \
        'persist.dbg.wfc_avail_ovr1=0' \
        >"${path}"
}

write_target_tree() {
    local directory="$1"
    write_property_file "${directory}/SYSTEM/etc/prop.default"
    write_property_file "${directory}/RECOVERY/RAMDISK/prop.default"
    mkdir -p "${directory}/BOOT/RAMDISK" "${directory}/ROOT"
    ln -s system/etc/prop.default "${directory}/ROOT/default.prop"
    ln -s prop.default "${directory}/RECOVERY/RAMDISK/default.prop"
    printf '%s\n' \
        'ro.system.build.type=user' \
        'ro.build.type=user' \
        'ro.build.tags=release-keys' \
        >"${directory}/SYSTEM/build.prop"
    # This real device comment is copied into system and recovery properties.
    printf '# ro.build.type=userdebug and ro.build.tags=test-keys, and\n' \
        >>"${directory}/SYSTEM/build.prop"
    printf '  # ro.build.type=userdebug and ro.build.tags=test-keys, and\n' \
        >>"${directory}/RECOVERY/RAMDISK/prop.default"
    mkdir -p \
        "${directory}/VENDOR/odm/etc" \
        "${directory}/SYSTEM/product"
    printf '%s\n' 'ro.vndk.version=29' \
        >"${directory}/VENDOR/default.prop"
    printf '%s\n' \
        'ro.vendor.build.type=user' \
        'ro.vendor.build.tags=release-keys' \
        >"${directory}/VENDOR/build.prop"
    printf '%s\n' 'ro.odm.build.type=user' \
        >"${directory}/VENDOR/odm/etc/build.prop"
    printf '%s\n' 'ro.product.build.type=user' \
        >"${directory}/SYSTEM/product/build.prop"
    printf 'console=tty0 buildvariant=user\n' >"${directory}/BOOT/cmdline"
    printf 'console=tty0 buildvariant=user\n' >"${directory}/RECOVERY/cmdline"
}

pack_tree() {
    local directory="$1"
    local archive="$2"
    (
        cd "${directory}"
        zip -qry "${archive}" SYSTEM VENDOR BOOT RECOVERY ROOT
    )
}

clone_tree() {
    local name="$1"
    local directory="${TEST_ROOT}/${name}"
    cp -a "${TEST_ROOT}/valid-tree" "${directory}"
    printf '%s' "${directory}"
}

expect_property_fail() {
    local directory="$1"
    local name="$2"
    local archive="${TEST_ROOT}/${name}.zip"
    pack_tree "${directory}" "${archive}"
    if "${VERIFY_PROPERTIES}" "${archive}" \
        >"${TEST_ROOT}/${name}.out" 2>"${TEST_ROOT}/${name}.err"; then
        printf 'Expected signed-property fixture to fail: %s\n' "${name}" >&2
        exit 1
    fi
}

write_target_tree "${TEST_ROOT}/valid-tree"
pack_tree "${TEST_ROOT}/valid-tree" "${TEST_ROOT}/valid.zip"
"${VERIFY_PROPERTIES}" "${TEST_ROOT}/valid.zip" >/dev/null

adb_default="$(clone_tree adb-default)"
sed -i 's/persist.sys.usb.config=mtp/persist.sys.usb.config=mtp,adb/' \
    "${adb_default}/SYSTEM/etc/prop.default"
expect_property_fail "${adb_default}" adb-default

root_adb="$(clone_tree root-adb)"
printf 'service.adb.root=1\n' >>"${root_adb}/SYSTEM/etc/prop.default"
expect_property_fail "${root_adb}" root-adb

development_tag="$(clone_tree development-tag)"
printf 'ro.fixture.identity=test-keys\n' \
    >>"${development_tag}/RECOVERY/RAMDISK/prop.default"
expect_property_fail "${development_tag}" development-tag

inline_development_tag="$(clone_tree inline-development-tag)"
printf 'ro.fixture.identity=# test-keys\n' \
    >>"${inline_development_tag}/SYSTEM/build.prop"
expect_property_fail "${inline_development_tag}" inline-development-tag
grep -Fq 'SYSTEM/build.prop contains a test/dev key identity' \
    "${TEST_ROOT}/inline-development-tag.err"

userdebug="$(clone_tree userdebug)"
sed -i 's/ro.system.build.type=user/ro.system.build.type=userdebug/' \
    "${userdebug}/SYSTEM/build.prop"
expect_property_fail "${userdebug}" userdebug

permissive="$(clone_tree permissive)"
printf 'androidboot.selinux=permissive\n' >"${permissive}/RECOVERY/cmdline"
expect_property_fail "${permissive}" permissive

missing_property="$(clone_tree missing-property)"
sed -i '/^ro.adb.secure=/d' "${missing_property}/SYSTEM/etc/prop.default"
expect_property_fail "${missing_property}" missing-property

stray_boot_property="$(clone_tree stray-boot-property)"
printf 'ro.adb.secure=0\n' >"${stray_boot_property}/BOOT/RAMDISK/prop.default"
expect_property_fail "${stray_boot_property}" stray-boot-property
grep -Fq 'BOOT/RAMDISK/prop.default carries forbidden ro.adb.secure=0' \
    "${TEST_ROOT}/stray-boot-property.err"

stray_root_property="$(clone_tree stray-root-property)"
printf 'ro.debuggable=1\n' >"${stray_root_property}/ROOT/prop.default"
expect_property_fail "${stray_root_property}" stray-root-property
grep -Fq 'ROOT/prop.default carries forbidden ro.debuggable=1' \
    "${TEST_ROOT}/stray-root-property.err"

debug_root="$(clone_tree debug-root)"
: >"${debug_root}/ROOT/force_debuggable"
expect_property_fail "${debug_root}" debug-root
grep -Fq 'release ramdisk contains forbidden debug component: ROOT/force_debuggable' \
    "${TEST_ROOT}/debug-root.err"

missing_entry="$(clone_tree missing-entry)"
find "${missing_entry}/RECOVERY/RAMDISK/prop.default" -delete
expect_property_fail "${missing_entry}" missing-entry

vendor_default_override="$(clone_tree vendor-default-override)"
printf 'ro.adb.secure=0\n' \
    >>"${vendor_default_override}/VENDOR/default.prop"
expect_property_fail "${vendor_default_override}" vendor-default-override

vendor_build_override="$(clone_tree vendor-build-override)"
printf 'ro.secure=0\n' \
    >>"${vendor_build_override}/VENDOR/build.prop"
expect_property_fail "${vendor_build_override}" vendor-build-override

product_build_override="$(clone_tree product-build-override)"
printf 'ro.debuggable=1\n' \
    >>"${product_build_override}/SYSTEM/product/build.prop"
expect_property_fail "${product_build_override}" product-build-override

odm_root_adb="$(clone_tree odm-root-adb)"
printf 'service.adb.root=1\n' \
    >>"${odm_root_adb}/VENDOR/odm/etc/build.prop"
expect_property_fail "${odm_root_adb}" odm-root-adb

product_services_override="$(clone_tree product-services-override)"
mkdir -p "${product_services_override}/SYSTEM/product_services"
printf 'ro.control_privapp_permissions=disable\n' \
    >"${product_services_override}/SYSTEM/product_services/build.prop"
expect_property_fail "${product_services_override}" product-services-override

property_import="$(clone_tree property-import)"
printf 'import /vendor/hidden.prop\n' \
    >>"${property_import}/VENDOR/default.prop"
expect_property_fail "${property_import}" property-import

debug_recovery="$(clone_tree debug-recovery)"
: >"${debug_recovery}/RECOVERY/RAMDISK/force_debuggable"
printf 'ro.secure=0\n' \
    >"${debug_recovery}/RECOVERY/RAMDISK/adb_debug.prop"
expect_property_fail "${debug_recovery}" debug-recovery

legacy_charon="$(clone_tree legacy-charon)"
mkdir -p "${legacy_charon}/VENDOR/bin"
: >"${legacy_charon}/VENDOR/bin/charon"
expect_property_fail "${legacy_charon}" legacy-charon

legacy_ipsec="$(clone_tree legacy-ipsec)"
mkdir -p "${legacy_ipsec}/VENDOR/etc/ipsec"
: >"${legacy_ipsec}/VENDOR/etc/ipsec/strongswan.conf"
expect_property_fail "${legacy_ipsec}" legacy-ipsec

legacy_epdg_init="$(clone_tree legacy-epdg-init)"
mkdir -p "${legacy_epdg_init}/VENDOR/etc/init"
: >"${legacy_epdg_init}/VENDOR/etc/init/init.epdg_wod.rc"
expect_property_fail "${legacy_epdg_init}" legacy-epdg-init

general_wfc_override="$(clone_tree general-wfc-override)"
printf 'persist.dbg.wfc_avail_ovr=1\n' \
    >>"${general_wfc_override}/VENDOR/build.prop"
expect_property_fail "${general_wfc_override}" general-wfc-override

slot_wfc_override="$(clone_tree slot-wfc-override)"
printf 'persist.dbg.wfc_avail_ovr1=1\n' \
    >>"${slot_wfc_override}/SYSTEM/product/build.prop"
expect_property_fail "${slot_wfc_override}" slot-wfc-override

identical_duplicate="$(clone_tree identical-duplicate)"
printf 'ro.secure=1\n' \
    >>"${identical_duplicate}/VENDOR/build.prop"
pack_tree "${identical_duplicate}" "${TEST_ROOT}/identical-duplicate.zip"
"${VERIFY_PROPERTIES}" "${TEST_ROOT}/identical-duplicate.zip" >/dev/null

manifest_put() {
    printf '%s=%s\n' "$1" "$2" >>"$3"
}

write_keyset_manifest() {
    local manifest="$1"
    : >"${manifest}"
    manifest_put keyset.version 1 "${manifest}"
    index=1
    for name in releasekey platform shared media networkstack bootsignature; do
        manifest_put "certificate.${name}.sha256" \
            "$(printf '%064d' "${index}")" "${manifest}"
        index=$((index + 1))
    done
    manifest_put apk.resigned_count 42 "${manifest}"
    manifest_put apk.presigned_count 17 "${manifest}"
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

expect_keyset_fail() {
    local manifest="$1"
    local name="$2"
    if "${VERIFY_KEYSET}" "${manifest}" \
        >"${TEST_ROOT}/${name}.manifest.out" \
        2>"${TEST_ROOT}/${name}.manifest.err"; then
        printf 'Expected keyset-manifest fixture to fail: %s\n' "${name}" >&2
        exit 1
    fi
}

write_keyset_manifest "${TEST_ROOT}/valid-keyset"
"${VERIFY_KEYSET}" "${TEST_ROOT}/valid-keyset" >/dev/null

cp "${TEST_ROOT}/valid-keyset" "${TEST_ROOT}/verified-boot-present"
replace_field "${TEST_ROOT}/verified-boot-present" \
    posture.verified_boot present
expect_keyset_fail "${TEST_ROOT}/verified-boot-present" verified-boot-present

cp "${TEST_ROOT}/valid-keyset" "${TEST_ROOT}/adb-root-wording"
replace_field "${TEST_ROOT}/adb-root-wording" \
    posture.adb_when_enabled authenticated-root
expect_keyset_fail "${TEST_ROOT}/adb-root-wording" adb-root-wording

cp "${TEST_ROOT}/valid-keyset" "${TEST_ROOT}/duplicate-certificate"
replace_field "${TEST_ROOT}/duplicate-certificate" \
    certificate.platform.sha256 "$(printf '%064d' 1)"
expect_keyset_fail "${TEST_ROOT}/duplicate-certificate" duplicate-certificate

cp "${TEST_ROOT}/valid-keyset" "${TEST_ROOT}/archive-without-map-record"
replace_field "${TEST_ROOT}/archive-without-map-record" apex.archive_count 1
expect_keyset_fail "${TEST_ROOT}/archive-without-map-record" archive-without-map-record

cp "${TEST_ROOT}/valid-keyset" "${TEST_ROOT}/archive-valid"
replace_field "${TEST_ROOT}/archive-valid" apex.archive_count 1
manifest_put apex.payload.1.name com.android.fixture.apex \
    "${TEST_ROOT}/archive-valid"
manifest_put apex.payload.1.public_key_sha256 "$(printf '%064d' 9)" \
    "${TEST_ROOT}/archive-valid"
"${VERIFY_KEYSET}" "${TEST_ROOT}/archive-valid" >/dev/null

cp "${TEST_ROOT}/valid-keyset" "${TEST_ROOT}/extra-record"
manifest_put secret.private_path /tmp/keys "${TEST_ROOT}/extra-record"
expect_keyset_fail "${TEST_ROOT}/extra-record" extra-record

printf 'TIER-3 SIGNED PROPERTY/KEYSET CONTRACT FIXTURES: PASS\n'
