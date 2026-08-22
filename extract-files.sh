#!/bin/bash

set -e

DEVICE=k50sv1_64_bsp
VENDOR=xsh

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then
    MY_DIR="${PWD}"
fi

LINEAGE_ROOT="${MY_DIR}/../../.."
HELPER="${LINEAGE_ROOT}/vendor/lineage/build/tools/extract_utils.sh"

if [[ ! -f "${HELPER}" ]]; then
    echo "Unable to find extract_utils.sh at ${HELPER}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${HELPER}"

# Keep MTK's Wi-Fi HAL ABI without colliding with the AOSP library that uses
# the same filename. The replacement SONAME is exactly the same length, so the
# ELF dynamic string table layout is unchanged.
function blob_fixup() {
    case "$1" in
        vendor/bin/hw/android.hardware.wifi@1.0-service-lazy-mediatek)
            local match_count
            match_count=$(LC_ALL=C grep -ao 'libwifi-hal\.so' "$2" | wc -l)
            if [[ "${match_count}" -ne 1 ]]; then
                echo "Unexpected libwifi-hal dependency count: ${match_count}" >&2
                return 1
            fi
            LC_ALL=C perl -0pi -e \
                's/libwifi-hal\.so/libmtk-wifi.so/g' "$2"
            LC_ALL=C grep -aq 'libmtk-wifi\.so' "$2"
            ;;
    esac
}

CLEAN_VENDOR=true
SECTION=
KANG=
SRC=

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n | --no-cleanup)
            CLEAN_VENDOR=false
            ;;
        -k | --kang)
            KANG="--kang"
            ;;
        -s | --section)
            shift
            SECTION="$1"
            CLEAN_VENDOR=false
            ;;
        *)
            SRC="$1"
            ;;
    esac
    shift
done

# Prefer the immutable offline extraction over the Magisk-modified handset.
if [[ -z "${SRC}" ]]; then
    SRC="${LINEAGE_ROOT}/../factory_image_unpacked"
fi

if [[ "${SRC}" != "adb" && ! -d "${SRC}" ]]; then
    echo "Extraction source does not exist: ${SRC}" >&2
    exit 1
fi

setup_vendor "${DEVICE}" "${VENDOR}" "${LINEAGE_ROOT}" false "${CLEAN_VENDOR}"

extract "${MY_DIR}/proprietary-files.txt" "${SRC}" ${KANG} --section "${SECTION}"

PROPRIETARY_ROOT="${LINEAGE_ROOT}/vendor/${VENDOR}/${DEVICE}/proprietary"
(
    cd "${PROPRIETARY_ROOT}"
    find . \( -type f -o -type l \) ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum >SHA256SUMS
)

"${MY_DIR}/setup-makefiles.sh"
