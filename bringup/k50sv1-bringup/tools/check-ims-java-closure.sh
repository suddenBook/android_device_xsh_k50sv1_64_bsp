#!/usr/bin/env bash
# Reproduce the nine-artifact IMS Java-closure counts recorded by E-069.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
BAKSMALI="${ROOT}/lineage-17.1/prebuilts/tools-lineage/common/smali/baksmali.jar"
VENDOR="${ROOT}/lineage-17.1/vendor/xsh/k50sv1_64_bsp/proprietary"
SCRATCH="$(mktemp -d)"
trap 'rm -rf -- "${SCRATCH}"' EXIT

files=(
    "${VENDOR}/system/framework/mediatek-common.jar"
    "${VENDOR}/system/framework/mediatek-ims-base.jar"
    "${VENDOR}/system/framework/mediatek-ims-common.jar"
    "${VENDOR}/system/framework/mediatek-telecom-common.jar"
    "${VENDOR}/system/framework/mediatek-telephony-base.jar"
    "${VENDOR}/system/framework/mediatek-telephony-common.jar"
    "${VENDOR}/system/framework/mediatek-ims-extension-plugin.jar"
    "${VENDOR}/system/framework/mediatek-ims-legacy.jar"
    "${VENDOR}/system/priv-app/ImsService/ImsService.apk"
)

[[ -f "${BAKSMALI}" ]] || { echo "missing baksmali: ${BAKSMALI}" >&2; exit 1; }
for file in "${files[@]}"; do
    [[ -f "${file}" ]] || { echo "missing IMS artifact: ${file}" >&2; exit 1; }
    java -jar "${BAKSMALI}" list classes "${file}" >>"${SCRATCH}/classes"
    java -jar "${BAKSMALI}" list types "${file}" >>"${SCRATCH}/types"
done

LC_ALL=C sort -u "${SCRATCH}/classes" >"${SCRATCH}/classes.unique"
LC_ALL=C sort -u "${SCRATCH}/types" >"${SCRATCH}/types.unique"
# `|| true`, deliberately. Under `set -euo pipefail` a grep that matches
# nothing returns 1 and the pipeline kills the script HERE -- before the printf
# that reports all five counts, and before the explicit
# `[[ "${mtk_refs}" == 1675 ]]` check below that exists to catch exactly this
# state. Its only caller (the retired verify-e072-build.sh) discarded stdout,
# so the operator got "IMS Java type closure" and no numbers whatsoever. This
# tool now has no caller and is run by hand. Zero matches
# is a result to report, not a reason to vanish; sort still writes the empty
# file, and the count assertion below now says what it saw.
grep -E '^(Lcom/mediatek/|Lmediatek/|Lvendor/mediatek/)' \
    "${SCRATCH}/types.unique" | LC_ALL=C sort -u >"${SCRATCH}/mtk.refs" || true
# LC_ALL=C on comm too, and not by taste: both inputs were produced by
# `LC_ALL=C sort`, while comm collated in the caller's locale. Every collating
# step in this file has to agree or comm rejects its own inputs. Measured on
# this host (LANG=en_US.UTF-8), against the version in git before this change:
#     comm: file 2 is not in sorted order
#     comm: file 1 is not in sorted order
#     comm: input is not in sorted order
#     rc=1
# which under `set -e` killed the script here, so the tool produced no counts
# at all and its only caller reported "IMS Java type closure" -- i.e. the tool
# was 100% dead and the failure looked like an IMS regression.
LC_ALL=C comm -23 "${SCRATCH}/mtk.refs" "${SCRATCH}/classes.unique" \
    >"${SCRATCH}/mtk.unresolved"
LC_ALL=C sort "${SCRATCH}/classes" | uniq -d >"${SCRATCH}/classes.duplicate"

classes="$(wc -l <"${SCRATCH}/classes.unique")"
mtk_refs="$(wc -l <"${SCRATCH}/mtk.refs")"
unresolved="$(wc -l <"${SCRATCH}/mtk.unresolved")"
duplicates="$(wc -l <"${SCRATCH}/classes.duplicate")"

printf 'artifacts=9\ndistinct_classes=%s\nmtk_type_refs=%s\nunresolved_mtk_types=%s\nduplicate_classes=%s\n' \
    "${classes}" "${mtk_refs}" "${unresolved}" "${duplicates}"

# Every failure names the number it saw, on stderr. The caller discards stdout,
# so a message that omits the observed value tells the operator nothing at all.
[[ "${classes}" == 3787 ]] \
    || { echo "unexpected distinct class count: ${classes} (expected 3787)" >&2; exit 1; }
[[ "${mtk_refs}" == 1675 ]] \
    || { echo "unexpected MTK type count: ${mtk_refs} (expected 1675)" >&2; exit 1; }
[[ "${unresolved}" == 0 ]] || {
    echo "unresolved MTK types: ${unresolved}" >&2
    cat "${SCRATCH}/mtk.unresolved" >&2
    exit 1
}
[[ "${duplicates}" == 150 ]] \
    || { echo "unexpected duplicate class count: ${duplicates} (expected 150)" >&2; exit 1; }
