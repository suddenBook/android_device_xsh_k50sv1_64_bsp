#!/usr/bin/env bash
#
# Assert that ims/framework-resource-ids.txt still describes the framework this
# build produced.
#
# extract-files.sh rewrote raw com.android.internal.R integers inside
# ImsService.apk's dex. Nothing in the APK records which resource an integer was
# meant to name, so if frameworks/base gains or loses a bool/ resource the
# rewritten IDs quietly start naming different flags and the IMS stack reads
# garbage -- VoLTE silently never registers, and the only symptom is a missing
# feature.
#
# $1: aapt2 binary
# $2: framework-res package-export.apk (or any APK carrying its resource table)
# $3: framework-resource-ids.txt
#
# Uses package-export.apk rather than the installed framework-res.apk purely
# because it is available earlier; either gives the same table. The dump is
# piped through a single awk pass, so this costs well under a second.

set -u

aapt2="$1"
resources_apk="$2"
id_table="$3"

for f in "${aapt2}" "${resources_apk}" "${id_table}"; do
    if [[ ! -r "${f}" ]]; then
        echo "verify-framework-resource-ids: cannot read ${f}" >&2
        exit 1
    fi
done

# name -> expected id, from the table
declare -A expected=()
while read -r name _stock lineage _class; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    # Normalise to the 8-digit form aapt2 prints.
    expected["${name}"]="$(printf '0x%08x' "$((lineage))")"
done <"${id_table}"

if [[ "${#expected[@]}" -eq 0 ]]; then
    echo "verify-framework-resource-ids: ${id_table} lists no resources" >&2
    exit 1
fi

# name -> actual id, from the built resource table. Restrict to bool/ so a
# same-named resource of another type cannot satisfy the check.
declare -A actual=()
while read -r id name; do
    actual["${name}"]="${id}"
done < <("${aapt2}" dump resources "${resources_apk}" 2>/dev/null \
    | awk '$1 == "resource" && $3 ~ /^bool\// { sub(/^bool\//, "", $3); print $2, $3 }')

status=0
for name in "${!expected[@]}"; do
    got="${actual[${name}]:-}"
    if [[ -z "${got}" ]]; then
        echo "verify-framework-resource-ids: bool/${name} is not in the built framework-res" >&2
        status=1
    elif [[ "${got}" != "${expected[${name}]}" ]]; then
        echo "verify-framework-resource-ids: bool/${name} is ${got}, but ImsService.apk was patched to ${expected[${name}]}" >&2
        status=1
    fi
done

if [[ "${status}" -ne 0 ]]; then
    echo "" >&2
    echo "The framework resource IDs baked into ImsService.apk no longer match" >&2
    echo "frameworks/base. Update the lineage-id column of" >&2
    echo "  device/xsh/k50sv1_64_bsp/ims/framework-resource-ids.txt" >&2
    echo "and re-run extract-files.sh to re-patch the APK." >&2
    exit 1
fi

exit 0
