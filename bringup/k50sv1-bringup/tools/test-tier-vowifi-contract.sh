#!/usr/bin/env bash
# Prove the generated blob filter and source capability split without an image.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
DEVICE_ROOT="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp"
VENDOR_MK="${LINEAGE_ROOT}/vendor/xsh/k50sv1_64_bsp/k50sv1_64_bsp-vendor.mk"
WFC_RESOURCE_TOOL="${TOOL_DIR}/check-wfc-framework-resource.sh"

die() {
    printf 'Tier VoWiFi contract fixture failed: %s\n' "$*" >&2
    exit 1
}

[[ -f "${VENDOR_MK}" && ! -L "${VENDOR_MK}" ]] \
    || die 'generated vendor product is missing'
[[ "$(grep -Fxc 'include device/xsh/k50sv1_64_bsp/legacy-vowifi-vendor-filter.mk' \
        "${VENDOR_MK}" || true)" -eq 1 ]] \
    || die 'generated vendor product does not include the exact filter once'
# `grep -Fq '>>"${PRODUCTMK}"'` asserted LineageOS boilerplate: extract_utils.sh
# writes to $PRODUCTMK in every device tree that has ever run write_makefiles,
# so deleting the filter append outright left this check green. Assert the
# statement that actually matters -- the single one naming the filter -- and
# that it is the one redirected into $PRODUCTMK. Continuations are joined first,
# because the append is written across two lines.
setup_makefiles_statements="$(awk '
    { statement = statement $0 }
    /\\$/ { sub(/\\$/, " ", statement); next }
    { print statement; statement = "" }
' "${DEVICE_ROOT}/setup-makefiles.sh")"
filter_append="$(grep -F 'legacy-vowifi-vendor-filter.mk' \
    <<<"${setup_makefiles_statements}" || true)"
[[ "$(grep -c . <<<"${filter_append}")" -eq 1 ]] \
    || die 'setup-makefiles.sh does not append the vendor filter exactly once'
for fragment in \
    'include device/%s/%s/legacy-vowifi-vendor-filter.mk' \
    '"${VENDOR}" "${DEVICE}"' \
    '>>"${PRODUCTMK}"'; do
    grep -Fq -- "${fragment}" <<<"${filter_append}" \
        || die "setup-makefiles.sh's vendor filter append is missing ${fragment}"
done

is_legacy_vowifi_destination() {
    case "$1" in
        vendor/bin/charon | vendor/bin/epdg_wod | vendor/bin/starter | \
        vendor/bin/stroke | vendor/bin/wfca | vendor/lib/libmal_epdga.so | \
        vendor/lib/libwo.so | vendor/lib64/libcharon-ss.so | \
        vendor/lib64/libcrypto-ss.so | vendor/lib64/libcurl-ss.so | \
        vendor/lib64/libhydra.so | vendor/lib64/libsimaka.so | \
        vendor/lib64/libssl-ss.so | vendor/lib64/libstrongswan.so | \
        vendor/lib64/libwo.so | vendor/etc/ipsec/*)
            return 0
            ;;
    esac
    return 1
}

read_vendor_copies() {
    local tier="$1"
    make --no-print-directory \
        -C "${LINEAGE_ROOT}" \
        -f "${VENDOR_MK#${LINEAGE_ROOT}/}" \
        -f - \
        K50SV1_BUILD_TIER="${tier}" TARGET_COPY_OUT_VENDOR=vendor <<'MAKE'
print:
	@printf '%s\n' $(PRODUCT_COPY_FILES)
MAKE
}

for tier in 1 3; do
    mapfile -t copies < <(read_vendor_copies "${tier}")
    legacy_count=0
    declare -A retained_count=(
        [vendor/bin/hw/vendor.mediatek.hardware.wfo@1.0-service]=0
        [vendor/bin/hw/vendor.mediatek.hardware.imsa@1.0-service]=0
        [vendor/bin/volte_stack]=0
        [vendor/bin/volte_ua]=0
        [vendor/lib/libipsec_ims_shr.so]=0
        [vendor/lib/libmal.so]=0
        [vendor/lib/libmal_rds.so]=0
    )
    for copy in "${copies[@]}"; do
        destination="${copy#*:}"
        is_legacy_vowifi_destination "${destination}" && \
            legacy_count=$((legacy_count + 1))
        if [[ -n "${retained_count[${destination}]+present}" ]]; then
            retained_count["${destination}"]=$((retained_count[${destination}] + 1))
        fi
    done
    expected_legacy=29
    [[ "${tier}" == 3 ]] && expected_legacy=0
    [[ "${legacy_count}" -eq "${expected_legacy}" ]] \
        || die "Tier ${tier} has ${legacy_count} legacy blob copies; expected ${expected_legacy}"
    for retained in "${!retained_count[@]}"; do
        [[ "${retained_count[${retained}]}" -eq 1 ]] \
            || die "Tier ${tier} lost/duplicated VoLTE dependency ${retained}"
    done
    unset retained_count
done

[[ "$(grep -Fc 'rootdir/etc/init/init.wfca.rc:' "${DEVICE_ROOT}/device.mk")" -eq 1 && \
   "$(grep -Fc 'rootdir/etc/init/init.epdg_wod.rc:' "${DEVICE_ROOT}/device.mk")" -eq 1 ]] \
    || die 'device service copy rules are not unique'
for override in \
    persist.dbg.wfc_avail_ovr \
    persist.dbg.wfc_avail_ovr0 \
    persist.dbg.wfc_avail_ovr1; do
    [[ "$(grep -Fxc "    setprop ${override} 0" \
            "${DEVICE_ROOT}/rootdir/etc/init/hw/init.mt6755.rc" || true)" -eq 1 ]] \
        || die "persistent WFC debug override is not reset exactly once: ${override}"
    [[ "$(grep -Fxc "    ${override}=0 \\" \
            "${DEVICE_ROOT}/lineage_k50sv1_64_bsp.mk" || true)" -eq 1 || \
       "$(grep -Fxc "    ${override}=0" \
            "${DEVICE_ROOT}/lineage_k50sv1_64_bsp.mk" || true)" -eq 1 ]] \
        || die "WFC debug override default is missing: ${override}"
done
"${WFC_RESOURCE_TOOL}" --expect true >/dev/null
"${WFC_RESOURCE_TOOL}" --expect false >/dev/null

CHARON="${LINEAGE_ROOT}/vendor/xsh/k50sv1_64_bsp/proprietary/vendor/bin/charon"
[[ "$(sha256sum "${CHARON}" | awk '{print $1}')" == \
   b7886570ef6b1a9be523fbb0e3c44c5ad5be79244aeafb1ccba7df0a27e4a057 ]] \
    || die 'legacy charon bytes changed; re-audit the production exclusion'
# Capture, then match a here-string. Under `set -o pipefail` a `grep -Fxq` that
# exits at its first match SIGPIPEs any producer still writing, and 141 then
# wins the pipeline -- so a SUCCESSFUL match can report as a failure, depending
# only on whether the producer happened to finish first. HANDOFF trap 6, and
# check-volte-chain.sh's header records it measured at rc 72 on a larger
# producer. A here-string is not a pipeline and cannot race.
charon_strings="$(strings -a "${CHARON}")"
grep -Fxq '5.1.2' <<<"${charon_strings}" \
    || die 'legacy charon no longer identifies as strongSwan 5.1.2'

printf 'TIERED LEGACY-VOWIFI SOURCE/COPY CONTRACT: PASS\n'
