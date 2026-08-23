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

function patch_ims_apk() {
    local apk="$1"
    local expected_apk_sha="06e62235bc7b30655f5dfcd2efaa7ab6a9b4c6f1efd6a6f8ce49ce1e62da3ff5"
    local expected_dex_sha="6aa7926e7974420e7fc5ea6e96c5287617a6a826dc60a46a7996f793bd986deb"
    local baksmali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/baksmali.jar"
    local smali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/smali.jar"
    local apk_sha
    local dex_sha
    local patch_dir

    apk_sha="$(sha256sum "${apk}" | awk '{ print $1 }')"
    if [[ "${apk_sha}" != "${expected_apk_sha}" ]]; then
        echo "Refusing to patch an unknown ImsService.apk: ${apk_sha}" >&2
        return 1
    fi
    for tool in java unzip zip; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            echo "Missing IMS patch dependency: ${tool}" >&2
            return 1
        fi
    done
    if [[ ! -r "${baksmali_jar}" || ! -r "${smali_jar}" ]]; then
        echo "Missing bundled smali tools for ImsService.apk" >&2
        return 1
    fi

    # Keep the temporary and final APK on the same filesystem so publication
    # is atomic. The output is unsigned because Android signs this phone-UID
    # app with the selected tier's platform certificate during the build.
    patch_dir="$(mktemp -d "${apk}.patch.XXXXXX")"
    (
        trap 'find "${patch_dir}" -depth -delete 2>/dev/null || true' EXIT

        unzip -p "${apk}" classes.dex >"${patch_dir}/classes.dex"
        dex_sha="$(sha256sum "${patch_dir}/classes.dex" | awk '{ print $1 }')"
        if [[ "${dex_sha}" != "${expected_dex_sha}" ]]; then
            echo "Unexpected Stock IMS classes.dex: ${dex_sha}" >&2
            exit 1
        fi

        java -jar "${baksmali_jar}" disassemble -j 1 \
            "${patch_dir}/classes.dex" -o "${patch_dir}/smali"

        local ims_app="${patch_dir}/smali/com/mediatek/ims/ImsApp.smali"
        local ims_config="${patch_dir}/smali/com/mediatek/ims/ImsConfigManager.smali"
        local ims_service="${patch_dir}/smali/com/mediatek/ims/ImsService.smali"
        local old_resource
        for old_resource in 0x111004b 0x111004c 0x111004d 0x1110064; do
            if [[ "$(grep -R -F -h -c "${old_resource}" \
                    "${patch_dir}/smali/com/mediatek" | awk '{ n += $1 } END { print n + 0 }')" -ne 1 ]]; then
                echo "Unexpected IMS framework resource reference: ${old_resource}" >&2
                exit 1
            fi
        done
        sed -i \
            -e 's/0x1110064/0x1110068/' \
            "${ims_app}"
        sed -i \
            -e 's/0x111004b/0x1110050/' \
            -e 's/0x111004c/0x1110051/' \
            -e 's/0x111004d/0x1110052/' \
            "${ims_config}"

        # The Stock APK starts its full Wi-Fi offload service even when WFC is
        # disabled. This voice-only port retains the state array expected by
        # the remaining code but does not instantiate WFO/MWI or its EPDG path.
        if [[ "$(grep -F -c \
                'Lcom/mediatek/wfo/impl/WfoService;->makeWfoService()V' \
                "${ims_service}")" -ne 1 ]]; then
            echo "Unexpected Stock WFO call count in ImsService.apk" >&2
            exit 1
        fi
        sed -i \
            '/^[[:space:]]*\.line 691$/,/WfoService;->makeWfoService()V$/d' \
            "${ims_service}"
        if grep -F -q 'WfoService;->makeWfoService()V' "${ims_service}"; then
            echo "Failed to remove the voice-only WFO startup call" >&2
            exit 1
        fi

        java -jar "${smali_jar}" assemble -j 1 \
            "${patch_dir}/smali" -o "${patch_dir}/classes.dex"

        for old_resource in 0x111004b 0x111004c 0x111004d 0x1110064; do
            if grep -R -F -q "${old_resource}" "${patch_dir}/smali/com/mediatek"; then
                echo "Stale IMS framework resource reference: ${old_resource}" >&2
                exit 1
            fi
        done

        cp -- "${apk}" "${patch_dir}/ImsService.apk"
        # Do not rely on ZIP's timestamp-based update decision: the Stock and
        # deterministic rebuilt dex intentionally share the 2009 timestamp.
        zip -q -d "${patch_dir}/ImsService.apk" classes.dex 'META-INF/*'
        touch -d '2009-01-01 00:00:00 UTC' "${patch_dir}/classes.dex"
        (
            cd "${patch_dir}"
            zip -q -X ImsService.apk classes.dex
        )
        unzip -tq "${patch_dir}/ImsService.apk" >/dev/null
        dex_sha="$(unzip -p "${patch_dir}/ImsService.apk" classes.dex \
            | sha256sum | awk '{ print $1 }')"
        if [[ "${dex_sha}" != \
              "3d604f601fe96110598fdda69f675f16751e6b78c47275b9225686b4fcb58a1c" ]]; then
            echo "Non-reproducible patched IMS classes.dex: ${dex_sha}" >&2
            exit 1
        fi
        apk_sha="$(sha256sum "${patch_dir}/ImsService.apk" | awk '{ print $1 }')"
        if [[ "${apk_sha}" != \
              "022d324338cdfac31c78c4babb4871eca311d72b35c9fe2349ab7986a5d91e6e" ]]; then
            echo "Non-reproducible patched ImsService.apk: ${apk_sha}" >&2
            exit 1
        fi
        chmod 0644 "${patch_dir}/ImsService.apk"
        mv -f -- "${patch_dir}/ImsService.apk" "${apk}"
    )
}

# Blob fixups.
#
# extract_utils runs the extraction loop with errexit disabled so it can retry
# alternate source paths, and it ignores blob_fixup's exit status. A fixup that
# merely returned non-zero would therefore publish the original or a partially
# rewritten blob and still report success, so every failure path below aborts
# the whole script instead. Keeping the abort here means vendor/lineage does
# not have to be patched.
#
# The Wi-Fi fixups keep MTK's Wi-Fi HAL ABI without colliding with the AOSP
# library that uses the same filename. The replacement SONAME is exactly the
# same length, so the ELF dynamic string table layout is unchanged.
function blob_fixup() {
    case "$1" in
        system/priv-app/ImsService/ImsService.apk)
            patch_ims_apk "$2" || exit 1
            ;;
        vendor/lib64/hw/gatekeeper.default.so)
            # Stock stores this as a symlink to a byte-identical
            # libSoftGatekeeper.so, and extract_utils probes the destination
            # name before the source name, so the symlink is what lands in the
            # vendor tree. A symlink there makes the generated
            # PRODUCT_COPY_FILES entry silently depend on a second entry
            # existing in the same directory, and the gatekeeper HAL aborts the
            # service if the module cannot be opened. Materialise it.
            if [[ -L "$2" ]]; then
                local gatekeeper_target
                gatekeeper_target="$(readlink -f "$2")"
                if [[ ! -f "${gatekeeper_target}" ]]; then
                    echo "Dangling gatekeeper.default.so symlink: $2" >&2
                    exit 1
                fi
                cp --remove-destination -- "${gatekeeper_target}" "$2" || exit 1
            fi
            if [[ -L "$2" || ! -s "$2" ]]; then
                echo "gatekeeper.default.so is still not a real file" >&2
                exit 1
            fi
            ;;
        vendor/bin/volte_stack)
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "db8d700b84adf95206c497c15acaa70524756183a5de876391effd5dab734edc" ]]; then
                echo "Refusing to patch an unknown volte_stack" >&2
                exit 1
            fi
            # Full-Treble vendor namespaces reject dlopen paths containing an
            # inaccessible /system/lib prefix. Preserve binary layout while
            # switching to the public LLNDK SONAME resolved through the linked
            # system namespace; retain libandroid.so as the legacy fallback.
            perl -0pi -e '
                s{\Q/system/lib/libandroid_net.so\E}{"libandroid_net.so" . ("\x00" x 12)}e;
                s{\Q/system/lib/libandroid.so\E}{"libandroid.so" . ("\x00" x 12)}e;
            ' "$2"
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "d6d74be9db1adf75f548d5585ac1e244656f2b2136135320564567a0886e2eb0" ]]; then
                echo "VoLTE stack linker-namespace fixup is not reproducible" >&2
                exit 1
            fi
            ;;
        vendor/bin/hw/android.hardware.wifi@1.0-service-lazy-mediatek)
            local match_count
            match_count=$(LC_ALL=C grep -ao 'libwifi-hal\.so' "$2" | wc -l)
            if [[ "${match_count}" -ne 1 ]]; then
                echo "Unexpected libwifi-hal dependency count: ${match_count}" >&2
                exit 1
            fi
            LC_ALL=C perl -0pi -e \
                's/libwifi-hal\.so/libmtk-wifi.so/g' "$2"
            if ! LC_ALL=C grep -aq 'libmtk-wifi\.so' "$2" || \
               LC_ALL=C grep -aq 'libwifi-hal\.so' "$2"; then
                echo "Wi-Fi HAL service SONAME rewrite did not take" >&2
                exit 1
            fi
            ;;
        vendor/lib64/libmtk-wifi.so)
            local match_count
            match_count=$(LC_ALL=C grep -ao 'libwifi-hal\.so' "$2" | wc -l)
            if [[ "${match_count}" -ne 1 ]]; then
                echo "Unexpected libwifi-hal SONAME count: ${match_count}" >&2
                exit 1
            fi
            LC_ALL=C perl -0pi -e \
                's/libwifi-hal\.so/libmtk-wifi.so/g' "$2"
            if ! LC_ALL=C grep -aq 'libmtk-wifi\.so' "$2" || \
               LC_ALL=C grep -aq 'libwifi-hal\.so' "$2"; then
                echo "Wi-Fi HAL SONAME rewrite did not take" >&2
                exit 1
            fi
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
