#!/usr/bin/env bash
# Fail closed on the device-side framework half of the WFC availability gate.

set -euo pipefail

die() {
    printf 'WFC framework-resource check failed: %s\n' "$*" >&2
    exit 1
}

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
OVERLAY="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp/overlay/frameworks/base/core/res/res/values/config.xml"
TIER3_OVERLAY="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp/overlay-tier3/frameworks/base/core/res/res/values/config.xml"
FRAMEWORK_RES=""
EXPECTED_VALUE=true

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --expect)
            [[ "$#" -ge 2 ]] || die '--expect requires true or false'
            EXPECTED_VALUE="$2"
            shift 2
            ;;
        --framework-res)
            [[ "$#" -ge 2 && -z "${FRAMEWORK_RES}" ]] \
                || die '--framework-res requires exactly one APK path'
            FRAMEWORK_RES="$2"
            shift 2
            ;;
        *)
            printf 'Usage: %s [--expect true|false] [--framework-res framework-res.apk]\n' \
                "$0" >&2
            exit 2
            ;;
    esac
done
case "${EXPECTED_VALUE}" in true | false) ;; *)
    die "--expect must be true or false, got ${EXPECTED_VALUE}" ;;
esac

[[ -f "${OVERLAY}" && ! -L "${OVERLAY}" && -r "${OVERLAY}" ]] \
    || die "missing source overlay: ${OVERLAY}"
[[ -f "${TIER3_OVERLAY}" && ! -L "${TIER3_OVERLAY}" && \
   -r "${TIER3_OVERLAY}" ]] \
    || die "missing Tier-3 source overlay: ${TIER3_OVERLAY}"
command -v xmllint >/dev/null 2>&1 || die "xmllint is unavailable"
source_count="$(xmllint --xpath \
    'count(/resources/bool[@name="config_device_wfc_ims_available"])' \
    "${OVERLAY}" 2>/dev/null)" \
    || die "cannot parse source overlay"
source_value="$(xmllint --xpath \
    'normalize-space(string(/resources/bool[@name="config_device_wfc_ims_available"]))' \
    "${OVERLAY}" 2>/dev/null)" \
    || die "cannot read source WFC boolean"
[[ "${source_count}" == 1 ]] \
    || die "source overlay must define config_device_wfc_ims_available exactly once"
tier3_source_count="$(xmllint --xpath \
    'count(/resources/bool[@name="config_device_wfc_ims_available"])' \
    "${TIER3_OVERLAY}" 2>/dev/null)" \
    || die "cannot parse Tier-3 source overlay"
tier3_source_value="$(xmllint --xpath \
    'normalize-space(string(/resources/bool[@name="config_device_wfc_ims_available"]))' \
    "${TIER3_OVERLAY}" 2>/dev/null)" \
    || die "cannot read Tier-3 WFC boolean"
[[ "${tier3_source_count}" == 1 ]] \
    || die "Tier-3 overlay must define config_device_wfc_ims_available exactly once"

# --expect names the value the tier being built must resolve to. The diagnostic
# overlay supplies it for tiers 1 and 2, overlay-tier3 for Tier 3
# (run-lineage-build.sh and stage-tier-images.sh both compute it that way).
#
# WAS BROKEN: --expect was parsed, range-checked, and then only interpolated
# into the source-only PASS line. The two source values were compared against
# hardcoded constants instead, so the argument reached no comparison at all and
# an expectation the sources cannot deliver still exited 0 with a PASS whose own
# text stated the contradiction. Select the authoritative overlay from the
# expectation, require it to carry that value, and require the other to carry
# the complement -- which is the invariant the tier split rests on.
if [[ "${EXPECTED_VALUE}" == true ]]; then
    TIER_OVERLAY_LABEL='diagnostic overlay'
    TIER_OVERLAY_VALUE="${source_value}"
    OTHER_OVERLAY_LABEL='Tier-3 overlay'
    OTHER_OVERLAY_VALUE="${tier3_source_value}"
    OTHER_EXPECTED_VALUE=false
else
    TIER_OVERLAY_LABEL='Tier-3 overlay'
    TIER_OVERLAY_VALUE="${tier3_source_value}"
    OTHER_OVERLAY_LABEL='diagnostic overlay'
    OTHER_OVERLAY_VALUE="${source_value}"
    OTHER_EXPECTED_VALUE=true
fi
[[ "${TIER_OVERLAY_VALUE}" == "${EXPECTED_VALUE}" ]] \
    || die "--expect ${EXPECTED_VALUE} makes the ${TIER_OVERLAY_LABEL} authoritative, and it defines config_device_wfc_ims_available=${TIER_OVERLAY_VALUE:-<unset>}"
[[ "${OTHER_OVERLAY_VALUE}" == "${OTHER_EXPECTED_VALUE}" ]] \
    || die "the ${OTHER_OVERLAY_LABEL} must define config_device_wfc_ims_available=${OTHER_EXPECTED_VALUE} for the tier split to resolve, not ${OTHER_OVERLAY_VALUE:-<unset>}"

if [[ -z "${FRAMEWORK_RES}" ]]; then
    printf 'WFC framework resource sources: PASS (%s supplies %s; %s is %s)\n' \
        "${TIER_OVERLAY_LABEL}" "${EXPECTED_VALUE}" \
        "${OTHER_OVERLAY_LABEL}" "${OTHER_EXPECTED_VALUE}"
    exit 0
fi

[[ -f "${FRAMEWORK_RES}" && ! -L "${FRAMEWORK_RES}" && -s "${FRAMEWORK_RES}" ]] \
    || die "missing, empty, or symlinked framework-res APK: ${FRAMEWORK_RES}"
AAPT2="${LINEAGE_ROOT}/out/host/linux-x86/bin/aapt2"
[[ -x "${AAPT2}" ]] || die "built aapt2 is unavailable: ${AAPT2}"

dump_file="$(mktemp)"
cleanup() {
    [[ -f "${dump_file:-}" && ! -L "${dump_file}" ]] && rm -f -- "${dump_file}"
}
trap cleanup EXIT
"${AAPT2}" dump resources "${FRAMEWORK_RES}" >"${dump_file}" \
    || die "aapt2 could not inspect framework-res"

if ! awk -v expected="${EXPECTED_VALUE}" '
    /^    resource / {
        if (inside) exit
        inside = ($0 ~ / bool\/config_device_wfc_ims_available$/)
        if (inside) resources++
        next
    }
    inside && /^      / {
        values++
        if ($0 == "      () " expected) expected_values++
    }
    END {
        if (resources != 1 || values != 1 || expected_values != 1) exit 1
    }
' "${dump_file}"; then
    die "merged framework-res does not resolve config_device_wfc_ims_available to one default ${EXPECTED_VALUE} value"
fi

printf 'WFC framework resource output: PASS (merged framework-res=%s)\n' \
    "${EXPECTED_VALUE}"
