#!/usr/bin/env bash
# Verify the release-signing intermediate, not mutable product-output props.

set -euo pipefail

die() {
    printf 'Tier-3 signed-property verification failed: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s <signed-target-files.zip>\n' "$0" >&2
    exit 2
}
TARGET_FILES="$1"
[[ -f "${TARGET_FILES}" && ! -L "${TARGET_FILES}" && -s "${TARGET_FILES}" ]] \
    || die 'signed target-files must be an ordinary non-empty file'
unzip -tq "${TARGET_FILES}" >/dev/null \
    || die 'signed target-files ZIP integrity check failed'

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
PROPERTY_SERVICE_SOURCE="${PROJECT_ROOT}/lineage-17.1/system/core/init/property_service.cpp"
VENDOR_INIT_SOURCE="${PROJECT_ROOT}/lineage-17.1/system/core/init/vendor_init.cpp"

# This verifier implements Android Q's exact later-wins load order. Bind both
# the authority for that order and the weak vendor hook that runs afterward;
# either source changing requires an explicit re-audit and digest update.
[[ "$(sha256sum "${PROPERTY_SERVICE_SOURCE}" | awk '{print $1}')" == \
   c8ca2f0b1a6e4f464cddeea3578d87f5c523f2f00e8e20055eae6bd5c4d64015 ]] \
    || die 'Android init property load implementation changed; re-audit the effective-property resolver'
[[ "$(sha256sum "${VENDOR_INIT_SOURCE}" | awk '{print $1}')" == \
   51ff38af93ad93366cfc19b28e6844757db7ce6d1d7bd64ad1de2eec887a653a ]] \
    || die 'vendor_load_properties implementation changed or is no longer the audited empty hook'

VERIFY_TMP="$(mktemp -d /tmp/k50-tier3-props.XXXXXX)"
cleanup() {
    if [[ -d "${VERIFY_TMP:-}" && ! -L "${VERIFY_TMP}" && \
          "${VERIFY_TMP}" == /tmp/k50-tier3-props.* ]]; then
        find "${VERIFY_TMP}" -mindepth 1 -depth -delete
        rmdir "${VERIFY_TMP}"
    fi
}
trap cleanup EXIT

TARGET_ENTRIES="${VERIFY_TMP}/entries"
unzip -Z1 "${TARGET_FILES}" >"${TARGET_ENTRIES}"

# first_stage_init loads adb_debug.prop and a userdebug policy on an unlocked
# device whenever force_debuggable is present. Reject every such component in
# the root tree or either ramdisk. This also closes Q releasetools' missing-comma bug
# between its two recovery force_debuggable path literals.
while IFS= read -r entry; do
    case "${entry}" in
        ROOT/* | BOOT/RAMDISK/* | RECOVERY/RAMDISK/*)
            case "${entry##*/}" in
                force_debuggable | adb_debug.prop | userdebug_plat_sepolicy.cil)
                    die "release ramdisk contains forbidden debug component: ${entry}"
                    ;;
            esac
            ;;
    esac
done <"${TARGET_ENTRIES}"

# The production tier cannot expose the legacy ePDG tunnel. The carried
# charon reports strongSwan 5.1.2; its transitive binary/library/config closure
# is diagnostics-only until a modern source-compatible implementation exists.
FORBIDDEN_TIER3_VOWIFI_ENTRIES=(
    VENDOR/bin/charon
    VENDOR/bin/epdg_wod
    VENDOR/bin/starter
    VENDOR/bin/stroke
    VENDOR/bin/wfca
    VENDOR/etc/init/init.epdg_wod.rc
    VENDOR/etc/init/init.wfca.rc
    VENDOR/lib/libmal_epdga.so
    VENDOR/lib/libwo.so
    VENDOR/lib64/libcharon-ss.so
    VENDOR/lib64/libcrypto-ss.so
    VENDOR/lib64/libcurl-ss.so
    VENDOR/lib64/libhydra.so
    VENDOR/lib64/libsimaka.so
    VENDOR/lib64/libssl-ss.so
    VENDOR/lib64/libstrongswan.so
    VENDOR/lib64/libwo.so
)
for entry in "${FORBIDDEN_TIER3_VOWIFI_ENTRIES[@]}"; do
    [[ "$(grep -Fxc "${entry}" "${TARGET_ENTRIES}" || true)" -eq 0 ]] \
        || die "Tier 3 contains forbidden legacy VoWiFi entry: ${entry}"
done
while IFS= read -r entry; do
    [[ "${entry}" != VENDOR/etc/ipsec/* ]] \
        || die "Tier 3 contains forbidden legacy VoWiFi config: ${entry}"
done <"${TARGET_ENTRIES}"

# Main Android follows property_service.cpp:901-919. This device has product
# and ODM merged under system/vendor respectively, and no product_services
# build.prop today. An optional merged product_services file is still consumed
# if present because init would load it through the root symlink.
MAIN_PROPERTY_ENTRIES=(
    SYSTEM/etc/prop.default
    SYSTEM/build.prop
    VENDOR/default.prop
    VENDOR/build.prop
    VENDOR/odm/etc/build.prop
    SYSTEM/product/build.prop
)
BASE_DEFAULT_ENTRIES=(
    SYSTEM/etc/prop.default
    RECOVERY/RAMDISK/prop.default
)
# Q's first-stage boot ramdisk contains init/fstab, not property defaults.
# Main Android loads SYSTEM/etc/prop.default; recovery uses /prop.default.

declare -A EXTRACTED_FILE=()
extract_required_entry() {
    local entry="$1"
    local output="${VERIFY_TMP}/${entry//\//-}"

    [[ "$(grep -Fxc "${entry}" "${TARGET_ENTRIES}" || true)" -eq 1 ]] \
        || die "target-files must contain exactly one ${entry}"
    unzip -p "${TARGET_FILES}" "${entry}" >"${output}"
    if [[ "${entry}" != BOOT/cmdline && "${entry}" != RECOVERY/cmdline ]]; then
        [[ -s "${output}" ]] || die "target-files entry is empty: ${entry}"
    fi
    EXTRACTED_FILE["${entry}"]="${output}"
}

for entry in \
    "${MAIN_PROPERTY_ENTRIES[@]}" \
    RECOVERY/RAMDISK/prop.default \
    BOOT/cmdline RECOVERY/cmdline; do
    extract_required_entry "${entry}"
done

OPTIONAL_PRODUCT_SERVICES=SYSTEM/product_services/build.prop
optional_count="$(grep -Fxc "${OPTIONAL_PRODUCT_SERVICES}" "${TARGET_ENTRIES}" || true)"
[[ "${optional_count}" -le 1 ]] \
    || die "target-files contains duplicate ${OPTIONAL_PRODUCT_SERVICES}"
if [[ "${optional_count}" -eq 1 ]]; then
    extract_required_entry "${OPTIONAL_PRODUCT_SERVICES}"
    MAIN_PROPERTY_ENTRIES+=("${OPTIONAL_PRODUCT_SERVICES}")
fi

# These alternatives would mean the partition/symlink model changed. Silently
# accepting both representations could resolve the wrong effective property.
for unexpected_layout_entry in \
    ODM/etc/build.prop PRODUCT/build.prop PRODUCT_SERVICES/build.prop; do
    [[ "$(grep -Fxc "${unexpected_layout_entry}" "${TARGET_ENTRIES}" || true)" -eq 0 ]] \
        || die "unexpected property partition layout: ${unexpected_layout_entry}"
done

property_value_exact() {
    local property="$1"
    local expected="$2"
    local property_file="$3"
    local label="$4"
    local value

    value="$(awk -v property="${property}" '
        index($0, property "=") == 1 {
            count++
            value = substr($0, length(property) + 2)
        }
        END { if (count != 1) exit 1; print value }
    ' "${property_file}")" \
        || die "${label} does not contain exactly one ${property}"
    [[ "${value}" == "${expected}" ]] \
        || die "${label} has ${property}=${value:-<empty>}; expected ${expected}"
}

reject_development_identity() {
    local property_file="$1"
    local label="$2"
    if awk '
        /^[[:space:]]*#/ { next }
        tolower($0) ~ /(^|[^[:alnum:]_])(test-keys|dev-keys)($|[^[:alnum:]_])/ {
            found = 1
        }
        END { exit !found }
    ' "${property_file}"; then
        die "${label} contains a test/dev key identity"
    fi
}

for entry in "${BASE_DEFAULT_ENTRIES[@]}"; do
    property_file="${EXTRACTED_FILE[${entry}]}"
    property_value_exact ro.secure 1 "${property_file}" "${entry}"
    property_value_exact ro.debuggable 0 "${property_file}" "${entry}"
    property_value_exact ro.adb.secure 1 "${property_file}" "${entry}"
    property_value_exact persist.sys.usb.config mtp "${property_file}" "${entry}"
    property_value_exact ro.allow.mock.location 0 "${property_file}" "${entry}"
    property_value_exact ro.control_privapp_permissions enforce \
        "${property_file}" "${entry}"
    property_value_exact persist.dbg.wfc_avail_ovr 0 \
        "${property_file}" "${entry}"
    property_value_exact persist.dbg.wfc_avail_ovr0 0 \
        "${property_file}" "${entry}"
    property_value_exact persist.dbg.wfc_avail_ovr1 0 \
        "${property_file}" "${entry}"

    service_adb_root_count="$(awk '
        index($0, "service.adb.root=") == 1 { count++ }
        END { print count + 0 }
    ' "${property_file}")"
    [[ "${service_adb_root_count}" -le 1 ]] \
        || die "${entry} contains duplicate service.adb.root properties"
    if [[ "${service_adb_root_count}" -eq 1 ]]; then
        property_value_exact service.adb.root 0 "${property_file}" "${entry}"
    fi

    if awk -F= '
        /^[[:space:]]*#/ { next }
        $1 ~ /(^|\.)usb\.config$/ {
            count = split($2, tokens, ",")
            for (i = 1; i <= count; i++) if (tokens[i] == "adb") found = 1
        }
        END { exit !found }
    ' "${property_file}"; then
        die "${entry} exposes adb in a default USB property"
    fi
    reject_development_identity "${property_file}" "${entry}"
done

# Resolve the main Android property map exactly as Q init does: the files above
# are processed in array order and every later assignment wins even for ro.*.
# Imports are forbidden in these generated files so a hidden recursive source
# cannot escape the explicit signed-entry set. Conflicting duplicate security
# values fail even when the final value happens to look safe.
declare -A CRITICAL_EXPECTED=(
    [ro.secure]=1
    [ro.debuggable]=0
    [ro.adb.secure]=1
    [persist.sys.usb.config]=mtp
    [ro.allow.mock.location]=0
    [ro.control_privapp_permissions]=enforce
    [ro.build.type]=user
    [ro.system.build.type]=user
    [ro.build.tags]=release-keys
    [persist.dbg.wfc_avail_ovr]=0
    [persist.dbg.wfc_avail_ovr0]=0
    [persist.dbg.wfc_avail_ovr1]=0
)
declare -A CRITICAL_FIRST_VALUE=()
declare -A CRITICAL_FIRST_SOURCE=()
declare -A EFFECTIVE_VALUE=()
declare -A EFFECTIVE_SOURCE=()

is_critical_property() {
    local property="$1"
    [[ -n "${CRITICAL_EXPECTED[${property}]+present}" || \
       "${property}" == service.adb.root ]]
}

parse_property_file() {
    local entry="$1"
    local property_file="$2"
    local parsed_file="$3"

    if awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^import[[:space:]]+/) found = 1
        }
        END { exit !found }
    ' "${property_file}"; then
        die "${entry} contains an unsupported property import"
    fi

    awk '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            separator = index(line, "=")
            if (separator == 0) next
            key = substr(line, 1, separator - 1)
            value = substr(line, separator + 1)
            sub(/^[[:space:]]+/, "", key)
            sub(/[[:space:]]+$/, "", key)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            printf "%s%c%s\n", key, 28, value
        }
    ' "${property_file}" >"${parsed_file}" \
        || die "cannot parse signed property entry: ${entry}"
}

load_index=0
for entry in "${MAIN_PROPERTY_ENTRIES[@]}"; do
    property_file="${EXTRACTED_FILE[${entry}]}"
    parsed_file="${VERIFY_TMP}/loaded-${load_index}.properties"
    load_index=$((load_index + 1))
    parse_property_file "${entry}" "${property_file}" "${parsed_file}"
    while IFS=$'\034' read -r property value; do
        [[ -n "${property}" ]] || continue
        if is_critical_property "${property}"; then
            if [[ -n "${CRITICAL_FIRST_VALUE[${property}]+present}" && \
                  "${CRITICAL_FIRST_VALUE[${property}]}" != "${value}" ]]; then
                die "conflicting ${property}: ${CRITICAL_FIRST_SOURCE[${property}]}=${CRITICAL_FIRST_VALUE[${property}]} but ${entry}=${value:-<empty>}"
            fi
            if [[ -z "${CRITICAL_FIRST_VALUE[${property}]+present}" ]]; then
                CRITICAL_FIRST_VALUE["${property}"]="${value}"
                CRITICAL_FIRST_SOURCE["${property}"]="${entry}"
            fi
        fi
        EFFECTIVE_VALUE["${property}"]="${value}"
        EFFECTIVE_SOURCE["${property}"]="${entry}"
    done <"${parsed_file}"
done

for property in "${!CRITICAL_EXPECTED[@]}"; do
    [[ -n "${EFFECTIVE_VALUE[${property}]+present}" ]] \
        || die "effective Android property map has no ${property}"
    [[ "${EFFECTIVE_VALUE[${property}]}" == "${CRITICAL_EXPECTED[${property}]}" ]] \
        || die "effective ${property}=${EFFECTIVE_VALUE[${property}]:-<empty>} from ${EFFECTIVE_SOURCE[${property}]}; expected ${CRITICAL_EXPECTED[${property}]}"
done
if [[ -n "${EFFECTIVE_VALUE[service.adb.root]+present}" && \
      "${EFFECTIVE_VALUE[service.adb.root]}" != 0 ]]; then
    die "effective service.adb.root=${EFFECTIVE_VALUE[service.adb.root]:-<empty>} from ${EFFECTIVE_SOURCE[service.adb.root]}; expected 0 or absence"
fi

# Sweep every other property file in every signed partition represented by
# this target-files package. Loaded files are already resolved above; this
# broader pass rejects insecure critical values, dev tags and default ADB
# tokens in any unexpected duplicate/config file too.
property_scan_index=0
declare -A PROPERTY_SCAN_SEEN=()
while IFS= read -r entry; do
    case "${entry}" in
        ROOT/* | SYSTEM/* | VENDOR/* | ODM/* | PRODUCT/* | PRODUCT_SERVICES/* | \
        BOOT/RAMDISK/* | RECOVERY/RAMDISK/*) ;;
        *) continue ;;
    esac
    case "${entry}" in
        *.prop | */prop.default | */default.prop) ;;
        *) continue ;;
    esac
    [[ -z "${PROPERTY_SCAN_SEEN[${entry}]:-}" ]] \
        || die "duplicate signed property entry: ${entry}"
    PROPERTY_SCAN_SEEN["${entry}"]=1
    property_scan_file="${VERIFY_TMP}/property-scan-${property_scan_index}"
    property_scan_index=$((property_scan_index + 1))
    unzip -p "${TARGET_FILES}" "${entry}" >"${property_scan_file}" \
        || die "cannot inspect signed property entry: ${entry}"
    reject_development_identity "${property_scan_file}" "${entry}"
    if awk -F= '
        /^[[:space:]]*#/ { next }
        $1 ~ /(^|\.)usb\.config$/ {
            count = split($2, tokens, ",")
            for (i = 1; i <= count; i++) if (tokens[i] == "adb") found = 1
        }
        END { exit !found }
    ' "${property_scan_file}"; then
        die "${entry} exposes adb in a default USB property"
    fi
    parsed_scan="${VERIFY_TMP}/property-scan-${property_scan_index}.parsed"
    parse_property_file "${entry}" "${property_scan_file}" "${parsed_scan}"
    while IFS=$'\034' read -r property value; do
        [[ -n "${property}" ]] || continue
        if [[ -n "${CRITICAL_EXPECTED[${property}]+present}" && \
              "${value}" != "${CRITICAL_EXPECTED[${property}]}" ]]; then
            die "${entry} carries forbidden ${property}=${value:-<empty>}"
        fi
        if [[ "${property}" == service.adb.root && "${value}" != 0 ]]; then
            die "${entry} carries forbidden service.adb.root=${value:-<empty>}"
        fi
    done <"${parsed_scan}"
done <"${TARGET_ENTRIES}"

SYSTEM_BUILD_PROP="${EXTRACTED_FILE[SYSTEM/build.prop]}"
property_value_exact ro.system.build.type user \
    "${SYSTEM_BUILD_PROP}" SYSTEM/build.prop
property_value_exact ro.build.type user \
    "${SYSTEM_BUILD_PROP}" SYSTEM/build.prop
property_value_exact ro.build.tags release-keys \
    "${SYSTEM_BUILD_PROP}" SYSTEM/build.prop
reject_development_identity "${SYSTEM_BUILD_PROP}" SYSTEM/build.prop

# This kernel is enforcing by default.  The production contract therefore
# rejects every androidboot.selinux override, including an explicit
# "enforcing" token that could hide an accidental default change elsewhere.
for entry in BOOT/cmdline RECOVERY/cmdline; do
    cmdline_file="${EXTRACTED_FILE[${entry}]}"
    ! grep -Eq '(^|[[:space:]])androidboot\.selinux=[^[:space:]]+' \
        "${cmdline_file}" \
        || die "${entry} contains a forbidden SELinux cmdline override"
done

printf 'Tier-3 effective Android-Q SYSTEM/VENDOR/ODM/PRODUCT plus BOOT/RECOVERY property contract: PASS\n'
