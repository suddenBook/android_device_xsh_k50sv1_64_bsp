#!/usr/bin/env bash

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
COMPAT_SOURCE="${LINEAGE_ROOT}/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot/usr/lib"
COMPAT_DIR="${LINEAGE_ROOT}/out/host-compat-libs"
BUNDLED_MKE2FS_CONFIG="${LINEAGE_ROOT}/system/extras/ext4_utils/mke2fs.conf"
BUILD_JOBS="${K50_BUILD_JOBS:-32}"
BUILD_TIER="${K50SV1_BUILD_TIER:-}"
RELEASE_KEYS_DIR=""
RELEASE_OUTPUT_ROOT="${K50SV1_RELEASE_OUTPUT_ROOT:-${LINEAGE_ROOT}/out/release}"
RELEASE_PYTHON="${LINEAGE_ROOT}/prebuilts/build-tools/path/linux-x86/python"
APKSIGNER_JAR="${LINEAGE_ROOT}/prebuilts/sdk/tools/linux/lib/apksigner.jar"
UPSTREAM_INPUT_TOOL="${TOOL_DIR}/apply-upstream-patches.sh"
CARRIER_CONFIG_TOOL="${TOOL_DIR}/check-carrier-config-overlay.py"
PIXEL_IDENTITY_TOOL="${TOOL_DIR}/check-pixel-identity.py"
LAUNCHER_POLICY_TOOL="${TOOL_DIR}/check-launcher-policy.py"
WFC_RESOURCE_TOOL="${TOOL_DIR}/check-wfc-framework-resource.sh"
RIL_SHIM_TESTS="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp/ril-shim/run-host-tests.sh"
STAGE_IMAGES_TOOL="${TOOL_DIR}/stage-tier-images.sh"
BUILD_INPUT_TOOL="${TOOL_DIR}/capture-build-input-state.sh"
KERNEL_ABI_CHECK_TOOL="${TOOL_DIR}/kernel/check-module-abi.sh"
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
KEYSET_PREPARE_TOOL="${TOOL_DIR}/prepare-tier3-keyset.sh"
TIER3_PROPERTY_VERIFY_TOOL="${TOOL_DIR}/verify-tier3-signed-properties.sh"
KEYSET_MANIFEST_VERIFY_TOOL="${TOOL_DIR}/verify-tier3-keyset-manifest.sh"
PRESIGNED_APK_VERIFY_TOOL="${TOOL_DIR}/verify-presigned-apk-signers.sh"
PRODUCT_OUT="${LINEAGE_ROOT}/out/target/product/k50sv1_64_bsp"
KERNEL_OBJ="${PRODUCT_OUT}/obj/KERNEL_OBJ"
UNPACK_BOOTIMG="$(command -v unpack_bootimg || true)"
BUILD_RECEIPT_NAME="K50SV1-BUILD-RECEIPT"
BUILD_SOURCE_STATE_NAME="K50SV1-BUILD-SOURCE-STATE"
BUILD_REPO_MANIFEST_NAME="K50SV1-ANDROID-REPO-MANIFEST.xml"
RELEASE_KEYSET_NAME="K50SV1-RELEASE-KEYSET"
CLEAN_BUILD="${K50SV1_CLEAN_BUILD:-1}"
ORIGINAL_ARG_COUNT="$#"
RELEASE_PIPELINE_ACTIVE=false
RECEIPT_ELIGIBLE=false
BUILD_INPUT_TMP=""
KEY_SNAPSHOT_DIR=""
declare -A RELEASE_CERTIFICATE_SHA=()

cleanup_key_snapshot() {
    if [[ -n "${KEY_SNAPSHOT_DIR:-}" && -d "${KEY_SNAPSHOT_DIR}" && \
          ! -L "${KEY_SNAPSHOT_DIR}" && \
          "${KEY_SNAPSHOT_DIR}" == /tmp/k50-tier3-keyset.* ]]; then
        if ! find "${KEY_SNAPSHOT_DIR}" -mindepth 1 -depth -delete; then
            echo "WARNING: could not completely erase the private Tier-3 key snapshot." >&2
        fi
        if ! rmdir "${KEY_SNAPSHOT_DIR}"; then
            echo "WARNING: private Tier-3 key snapshot directory remains: ${KEY_SNAPSHOT_DIR}" >&2
        fi
    fi
}
trap cleanup_key_snapshot EXIT

# The wrapper, release verifier and handoff all intentionally use one concrete
# output tree. An inherited Android output override would make Soong write in a
# different place while the signing/staging code read stale files from out/.
if [[ -n "${OUT_DIR:-}" || -n "${OUT_DIR_COMMON_BASE:-}" ]]; then
    echo "run-lineage-build.sh owns OUT_DIR; unset OUT_DIR and OUT_DIR_COMMON_BASE." >&2
    exit 2
fi
export OUT_DIR="${LINEAGE_ROOT}/out"

for forbidden_build_environment in \
    BUILD_FINGERPRINT BUILD_NUMBER BUILD_ID BUILD_VERSION_TAGS \
    PLATFORM_VERSION PLATFORM_SDK_VERSION PLATFORM_SECURITY_PATCH; do
    if [[ -n "${!forbidden_build_environment:-}" ]]; then
        echo "Refusing inherited Android identity override: ${forbidden_build_environment}" >&2
        exit 2
    fi
done

case "${CLEAN_BUILD}" in
    0 | 1) ;;
    *)
        echo "K50SV1_CLEAN_BUILD must be 0 or 1 (got ${CLEAN_BUILD})." >&2
        exit 2
        ;;
esac

invalidate_build_receipt() {
    local receipt_path
    for receipt_path in \
        "${PRODUCT_OUT}/${BUILD_RECEIPT_NAME}" \
        "${PRODUCT_OUT}/${BUILD_SOURCE_STATE_NAME}" \
        "${PRODUCT_OUT}/${BUILD_REPO_MANIFEST_NAME}" \
        "${PRODUCT_OUT}/${RELEASE_KEYSET_NAME}"; do
        [[ ! -L "${receipt_path}" ]] || {
            echo "Refusing to remove symlinked build receipt input: ${receipt_path}" >&2
            exit 1
        }
        rm -f -- "${receipt_path}"
    done
}

case "${BUILD_TIER}" in
    1 | 2)
        BUILD_VARIANT=userdebug
        ;;
    3)
        BUILD_VARIANT=user
        RELEASE_PIPELINE_ACTIVE=true
        if [[ "${CLEAN_BUILD}" != 1 ]]; then
            echo "Tier 3 requires K50SV1_CLEAN_BUILD=1." >&2
            exit 2
        fi
        if [[ $# -ne 0 ]]; then
            echo "Tier 3 owns the target-files signing pipeline; do not pass build targets." >&2
            exit 2
        fi
        if [[ ! -x "${RELEASE_PYTHON}" ]]; then
            echo "Missing Android release-tools Python: ${RELEASE_PYTHON}" >&2
            exit 2
        fi
        if [[ ! -r "${APKSIGNER_JAR}" ]]; then
            echo "Missing Android APK/APEX verifier: ${APKSIGNER_JAR}" >&2
            exit 2
        fi
        if [[ "$(sha256sum "${APKSIGNER_JAR}" | awk '{print $1}')" != \
              b9b61b17a11523da8e10e454f35ef1093397014e22b67323576816456e64537c ]]; then
            echo "Android APK/APEX verifier jar changed; re-audit before release signing." >&2
            exit 2
        fi
        if [[ ! -x "${STAGE_IMAGES_TOOL}" ]]; then
            echo "Missing executable Tier-3 staging tool: ${STAGE_IMAGES_TOOL}" >&2
            exit 2
        fi
        for tier3_tool in \
            "${KEYSET_PREPARE_TOOL}" \
            "${TIER3_PROPERTY_VERIFY_TOOL}" \
            "${KEYSET_MANIFEST_VERIFY_TOOL}" \
            "${PRESIGNED_APK_VERIFY_TOOL}"; do
            [[ -x "${tier3_tool}" ]] || {
                echo "Missing executable Tier-3 verification tool: ${tier3_tool}" >&2
                exit 2
            }
        done
        if [[ "$(sha256sum "${PRESIGNED_APK_VERIFY_TOOL}" | awk '{print $1}')" != \
              02a542c57e863f888a00924cceaba0e724eb390e46fb943f3071eecac0d25403 ]]; then
            echo "PRESIGNED APK verifier changed; re-audit and update its pinned digest." >&2
            exit 2
        fi
        for command in cmp cp java javac mktemp mv openssl realpath sha256sum sort unzip zip; do
            if ! command -v "${command}" >/dev/null 2>&1; then
                echo "Missing tier-3 host command: ${command}" >&2
                exit 2
            fi
        done
        if ! java -jar "${APKSIGNER_JAR}" version >/dev/null 2>&1; then
            echo "Android APK/APEX verifier cannot start: ${APKSIGNER_JAR}" >&2
            exit 2
        fi
        # Validate external ownership/layout before deleting any generated
        # output, then permanently switch this process to its private snapshot.
        KEY_SNAPSHOT_DIR="$(mktemp -d /tmp/k50-tier3-keyset.XXXXXX)"
        chmod 0700 "${KEY_SNAPSHOT_DIR}"
        "${KEYSET_PREPARE_TOOL}" "${KEY_SNAPSHOT_DIR}"
        unset K50SV1_RELEASE_KEYS_DIR
        RELEASE_KEYS_DIR="${KEY_SNAPSHOT_DIR}"

        for key in releasekey platform shared media networkstack bootsignature; do
            if ! private_public_sha="$(
                openssl pkcs8 -inform DER -nocrypt \
                    -in "${RELEASE_KEYS_DIR}/${key}.pk8" -outform PEM 2>/dev/null \
                    | openssl pkey -pubout -outform DER 2>/dev/null \
                    | sha256sum | awk '{ print $1 }'
            )"; then
                echo "Cannot derive the Tier-3 private-key public hash: ${key}" >&2
                exit 2
            fi
            if ! certificate_public_sha="$(
                openssl x509 -in "${RELEASE_KEYS_DIR}/${key}.x509.pem" \
                    -pubkey -noout 2>/dev/null \
                    | openssl pkey -pubin -outform DER 2>/dev/null \
                    | sha256sum | awk '{ print $1 }'
            )"; then
                echo "Cannot derive the Tier-3 certificate public hash: ${key}" >&2
                exit 2
            fi
            if [[ -z "${private_public_sha}" || \
                  "${private_public_sha}" != "${certificate_public_sha}" ]]; then
                echo "Tier-3 private key/certificate mismatch: ${key}" >&2
                exit 2
            fi
            if ! openssl x509 -checkend 0 -noout \
                -in "${RELEASE_KEYS_DIR}/${key}.x509.pem" >/dev/null 2>&1; then
                echo "Tier-3 certificate is expired or invalid: ${key}" >&2
                exit 2
            fi
            if ! RELEASE_CERTIFICATE_SHA["${key}"]="$(
                openssl x509 -in "${RELEASE_KEYS_DIR}/${key}.x509.pem" \
                    -outform DER 2>/dev/null \
                    | sha256sum | awk '{ print $1 }'
            )" || [[ -z "${RELEASE_CERTIFICATE_SHA[${key}]}" ]]; then
                echo "Cannot derive the Tier-3 certificate digest: ${key}" >&2
                exit 2
            fi
        done
        declare -A seen_release_certificate_sha=()
        for key in releasekey platform shared media networkstack bootsignature; do
            certificate_sha="${RELEASE_CERTIFICATE_SHA[${key}]}"
            if [[ -n "${seen_release_certificate_sha[${certificate_sha}]:-}" ]]; then
                echo "Tier-3 certificate is reused by ${seen_release_certificate_sha[${certificate_sha}]} and ${key}." >&2
                exit 2
            fi
            seen_release_certificate_sha["${certificate_sha}"]="${key}"
        done
        for development_certificate in \
            "${LINEAGE_ROOT}"/build/make/target/product/security/*.x509.pem; do
            [[ -f "${development_certificate}" ]] || continue
            if ! development_certificate_sha="$(
                openssl x509 -in "${development_certificate}" -outform DER 2>/dev/null \
                    | sha256sum | awk '{ print $1 }'
            )" || [[ -z "${development_certificate_sha}" ]]; then
                echo "Cannot derive development-certificate digest: ${development_certificate}" >&2
                exit 2
            fi
            if [[ -n "${seen_release_certificate_sha[${development_certificate_sha}]:-}" ]]; then
                echo "Tier-3 ${seen_release_certificate_sha[${development_certificate_sha}]} is an AOSP development certificate: ${development_certificate}" >&2
                exit 2
            fi
        done
        ;;
    *)
        echo "K50SV1_BUILD_TIER must be 1, 2, or 3 (got ${BUILD_TIER})." >&2
        exit 2
        ;;
esac

# A release receipt may describe only a build that started from an absent or
# completely empty output tree.  Tier-3 key validation intentionally precedes
# this operation: a missing/unsafe external keyset must never destroy a useful
# generated tree merely to report a preflight error.
if [[ -L "${OUT_DIR}" || ( -e "${OUT_DIR}" && ! -d "${OUT_DIR}" ) ]]; then
    echo "Android output path is not an ordinary directory: ${OUT_DIR}" >&2
    exit 1
fi
if [[ "${CLEAN_BUILD}" == 1 && -d "${OUT_DIR}" ]]; then
    expected_out="$(realpath -m "${LINEAGE_ROOT}/out")"
    actual_out="$(realpath -e "${OUT_DIR}")"
    [[ "${actual_out}" == "${expected_out}" && \
       "${actual_out}" == "${LINEAGE_ROOT}/out" ]] || {
        echo "Refusing to clean an unexpected output path: ${actual_out}" >&2
        exit 1
    }
    find "${actual_out}" -mindepth 1 -depth -delete
    rmdir "${actual_out}"
    echo "Removed the generated Android output tree for a clean build: ${actual_out}"
fi
invalidate_build_receipt

export K50SV1_BUILD_TIER="${BUILD_TIER}"
export K50SV1_RELEASE_PIPELINE_ACTIVE="${RELEASE_PIPELINE_ACTIVE}"

[[ -x "${KERNEL_ABI_CHECK_TOOL}" ]] || {
    echo "Missing executable source-kernel ABI gate: ${KERNEL_ABI_CHECK_TOOL}" >&2
    exit 1
}
[[ -x "${UNPACK_BOOTIMG}" ]] || {
    echo "Missing host unpack_bootimg for source-kernel receipt validation." >&2
    exit 1
}

if [[ "${CLEAN_BUILD}" == 1 && \
      ( "${BUILD_TIER}" == 3 || "${ORIGINAL_ARG_COUNT}" -eq 0 ) ]]; then
    RECEIPT_ELIGIBLE=true
fi

# A repo sync silently restores the font delta. Refuse to lunch (and therefore
# to build any target) unless that exact patch remains the sole vendor/lineage
# dirt and the clean Lineage APN base plus four-row device merge validates.
# --check is deliberately read-only; restoring the font remains an explicit
# apply-upstream-patches.sh action.
[[ -x "${UPSTREAM_INPUT_TOOL}" ]] || {
    echo "Missing executable vendor/lineage preflight: ${UPSTREAM_INPUT_TOOL}" >&2
    exit 1
}
"${UPSTREAM_INPUT_TOOL}" --check
[[ -x "${CARRIER_CONFIG_TOOL}" ]] || {
    echo "Missing executable CarrierConfig preflight: ${CARRIER_CONFIG_TOOL}" >&2
    exit 1
}
"${CARRIER_CONFIG_TOOL}"
[[ -x "${PIXEL_IDENTITY_TOOL}" ]] || {
    echo "Missing executable Pixel identity preflight: ${PIXEL_IDENTITY_TOOL}" >&2
    exit 1
}
"${PIXEL_IDENTITY_TOOL}"
[[ -x "${WFC_RESOURCE_TOOL}" ]] || {
    echo "Missing executable WFC framework-resource preflight: ${WFC_RESOURCE_TOOL}" >&2
    exit 1
}
WFC_EXPECTED_VALUE=true
[[ "${BUILD_TIER}" == 3 ]] && WFC_EXPECTED_VALUE=false
"${WFC_RESOURCE_TOOL}" --expect "${WFC_EXPECTED_VALUE}"

# The ril-shim GOT hooks intercept MediaTek's destructive SIM-switch
# transaction, which makes them the most safety-critical hand-written code in
# the device tree, and their two host tests used to run only when somebody
# remembered. They belong here rather than in the device Android.mk because a
# ninja recipe runs with the build's sanitised PATH and has no C compiler; that
# was measured, and it cost a 35-minute build that failed at 86% with
# "cc: command not found". See the comment in device/.../Android.mk.
[[ -x "${RIL_SHIM_TESTS}" ]] || {
    echo "Missing executable RIL shim host tests: ${RIL_SHIM_TESTS}" >&2
    exit 1
}
"${RIL_SHIM_TESTS}" >/dev/null || {
    echo "RIL shim host tests FAILED; re-run ${RIL_SHIM_TESTS} to see why." >&2
    exit 1
}
echo "RIL shim host tests: PASS"

if [[ "${RECEIPT_ELIGIBLE}" == true ]]; then
    [[ -x "${BUILD_INPUT_TOOL}" ]] || {
        echo "Missing executable build-input capture tool: ${BUILD_INPUT_TOOL}" >&2
        exit 1
    }
    BUILD_INPUT_TMP="$(mktemp -d /tmp/k50-build-inputs.XXXXXX)"
    cleanup_build_input_tmp() {
        if [[ -n "${BUILD_INPUT_TMP:-}" && -d "${BUILD_INPUT_TMP}" && \
              ! -L "${BUILD_INPUT_TMP}" && \
              "${BUILD_INPUT_TMP}" == /tmp/k50-build-inputs.* ]]; then
            if ! find "${BUILD_INPUT_TMP}" -mindepth 1 -depth -delete; then
                echo "WARNING: could not completely erase the temporary build-input snapshot." >&2
            fi
            if ! rmdir "${BUILD_INPUT_TMP}"; then
                echo "WARNING: build-input snapshot directory remains: ${BUILD_INPUT_TMP}" >&2
            fi
        fi
    }
    trap 'cleanup_build_input_tmp || true; cleanup_key_snapshot || true' EXIT
    BUILD_SOURCE_BEFORE="${BUILD_INPUT_TMP}/source-state.before"
    BUILD_REPO_BEFORE="${BUILD_INPUT_TMP}/repo-manifest.before.xml"
    "${BUILD_INPUT_TOOL}" --repo-manifest "${BUILD_REPO_BEFORE}" \
        >"${BUILD_SOURCE_BEFORE}"
    [[ -s "${BUILD_SOURCE_BEFORE}" && -s "${BUILD_REPO_BEFORE}" ]] || {
        echo "Build-input capture produced an empty record." >&2
        exit 1
    }
    BUILD_STARTED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [[ "${BUILD_STARTED_AT_UTC}" =~ \
       ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        echo "Cannot derive a strict UTC build-start timestamp." >&2
        exit 1
    }
fi

for library in libncurses.so.5.9 libtinfo.so.5.9; do
    if [[ ! -f "${COMPAT_SOURCE}/${library}" ]]; then
        echo "Missing bundled host compatibility library: ${library}" >&2
        exit 1
    fi
done

if [[ ! -f "${BUNDLED_MKE2FS_CONFIG}" ]]; then
    echo "Missing bundled mke2fs configuration: ${BUNDLED_MKE2FS_CONFIG}" >&2
    exit 1
fi

mkdir -p "${COMPAT_DIR}"
ln -sfn "${COMPAT_SOURCE}/libncurses.so.5.9" "${COMPAT_DIR}/libncurses.so.5"
ln -sfn "${COMPAT_SOURCE}/libtinfo.so.5.9" "${COMPAT_DIR}/libtinfo.so.5"

export LD_LIBRARY_PATH="${COMPAT_DIR}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
# Android 10's bundled mke2fs cannot parse newer host-default ext4 features
# such as metadata_csum_seed and orphan_file. Keep APEX/image generation tied
# to the matching source-tree configuration instead of /etc/mke2fs.conf.
export MKE2FS_CONFIG="${BUNDLED_MKE2FS_CONFIG}"

# Never write __pycache__. The build invokes vendor/lineage/tools/custom_apns.py
# for the APN merge, and CPython drops bytecode beside any script it imports --
# inside an upstream project that must be byte-clean apart from one approved
# font file. The input gate uses --untracked-files=all, correctly, so that
# residue made the build fail on its own side effect. Suppressing the write is
# the fix; teaching the gate to ignore untracked paths would blunt the one check
# that catches a smuggled upstream edit.
export PYTHONDONTWRITEBYTECODE=1

# RenderScript's bitcode step runs prebuilts/clang/host/linux-x86/clang-3289846,
# which links libncurses.so.5 and libtinfo.so.5. Most current distributions ship
# only ncurses 6, and every libclcore*.bc edge then fails with
#   clang.real: error while loading shared libraries: libncurses.so.5
# That is a host packaging gap, not a tree defect, and it appears without warning
# the first time the host updates: this build succeeded on 2026-08-30 and failed
# on 2026-08-31 with no source change.
#
# BOTH SONAMES ARE ALREADY PROVIDED, unconditionally, by the COMPAT_DIR links
# above -- from the workspace's own AOSP sysroot, so the build does not depend on
# a distribution package at all. A second mechanism used to sit here: a probe
# that looked for the two sonames on the host and, when it did not find them,
# built a shim under OUT_DIR. It could never fire, because COMPAT_DIR had already
# put both on LD_LIBRARY_PATH; out/.host-ncurses5-compat has never existed. Its
# one reachable effect was an `exit 1` on a host that was perfectly able to
# build. Two commits were spent on it in a single day and neither asked why the
# failure had happened DESPITE COMPAT_DIR having been in place for nine days.
# Deleted; the answer was always the links above.

if [[ "${BUILD_TIER}" != 3 && $# -eq 0 ]]; then
    set -- bootimage recoveryimage systemimage vendorimage
fi

cd "${LINEAGE_ROOT}"
# Pin TOP before envsetup is sourced. gettop() trusts an inherited TOP without
# proving that it names the current tree, which can select one checkout while
# the wrapper's tools and outputs point at another.
export TOP="${LINEAGE_ROOT}"
# shellcheck source=/dev/null
# Android 10's envsetup functions dereference optional variables such as TOP
# and ZSH_VERSION directly, so nounset must remain disabled in this process.
set +u
source build/envsetup.sh
lunch "lineage_k50sv1_64_bsp-${BUILD_VARIANT}"

selected_top="$(gettop)"
if [[ -z "${selected_top}" ]] || \
   [[ "$(cd "${selected_top}" 2>/dev/null && pwd -P)" != "$(pwd -P)" ]]; then
    echo "envsetup selected TOP=${selected_top:-<unset>}, not ${LINEAGE_ROOT}." >&2
    exit 1
fi

# lunch itself is honest: on an unparseable product makefile
# build_build_var_cache fails, it prints "Don't have a product spec for" and
# returns 1 without exporting anything (build/make/envsetup.sh:669-684). The
# trap is what happens NEXT -- build/make/core/envsetup.mk:87-94 defaults an
# unset TARGET_PRODUCT/TARGET_BUILD_VARIANT to aosp_arm/eng, so a later build
# invocation would silently build the wrong device and then "fail" for reasons
# that have nothing to do with the change under test. This happened once in
# this project, when the GMS payload repository was momentarily absent during a
# swap and the $(error) guard in lineage_k50sv1_64_bsp.mk fired during product
# parsing. Nounset is off here only because envsetup dereferences optional shell
# variables; it does not change lunch's exit status or `set -e` behaviour.
#
# Assert the product as well as the variant, and do it before anything is built.
selected_product="$(get_build_var TARGET_PRODUCT)"
if [[ "${selected_product}" != "lineage_k50sv1_64_bsp" ]]; then
    echo "lunch selected TARGET_PRODUCT=${selected_product}, not lineage_k50sv1_64_bsp." >&2
    echo "The product makefile failed to parse; scroll up for the real error." >&2
    exit 1
fi

selected_variant="$(get_build_var TARGET_BUILD_VARIANT)"
if [[ "${selected_variant}" != "${BUILD_VARIANT}" ]]; then
    echo "Tier ${BUILD_TIER} requires ${BUILD_VARIANT}, but lunch selected ${selected_variant}." >&2
    exit 1
fi

selected_device="$(get_build_var TARGET_DEVICE)"
if [[ "${selected_device}" != "k50sv1_64_bsp" ]]; then
    echo "lunch selected TARGET_DEVICE=${selected_device}, not k50sv1_64_bsp." >&2
    exit 1
fi

# property_service calls the weak vendor_load_properties hook after every
# signed property file. The audited product uses the empty AOSP stub; a target
# init vendor library could override it and invalidate the effective-map proof.
selected_init_vendor_lib="$(get_build_var TARGET_INIT_VENDOR_LIB)"
if [[ -n "${selected_init_vendor_lib}" ]]; then
    echo "TARGET_INIT_VENDOR_LIB overrides the audited empty property hook: ${selected_init_vendor_lib}" >&2
    exit 1
fi

# envsetup/get_build_var are finished. Restore the full strict-mode contract
# before either the image build or the Tier-3 release-signing pipeline runs.
set -euo pipefail

# Do not call envsetup's `m` after restoring nounset. Android 10's function
# chain dereferences optional $TOP in gettop() and aborts before Soong when -u
# is active. Invoke the exact underlying build-mode command directly; the lunch
# environment is already selected and validated above.
run_android_build() {
    "${LINEAGE_ROOT}/build/soong/soong_ui.bash" \
        --build-mode --all-modules --dir="${LINEAGE_ROOT}" "$@"
}

file_sha256() {
    local file="$1"
    local digest

    [[ -f "${file}" && ! -L "${file}" && -r "${file}" ]] || {
        echo "Cannot hash missing, unreadable, or symlinked build artifact: ${file}" >&2
        return 1
    }
    digest="$(sha256sum -- "${file}" | awk '{ print $1 }')" || return 1
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s' "${digest}"
}

manifest_get_exact() {
    local key="$1"
    local manifest="$2"

    awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++
            value = substr($0, length(key) + 2)
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    ' "${manifest}"
}

collect_source_kernel_contract() (
    local image_dir="$1"
    local abi_output kernel_tmp image unpack_dir
    local artifact label expected_path expected_sha expected_bytes

    [[ -x "${KERNEL_ABI_CHECK_TOOL}" ]] || {
        echo "Missing executable source-kernel ABI gate: ${KERNEL_ABI_CHECK_TOOL}" >&2
        return 1
    }
    [[ -x "${UNPACK_BOOTIMG}" ]] || {
        echo "Missing host unpack_bootimg for source-kernel receipt validation." >&2
        return 1
    }
    [[ -d "${KERNEL_OBJ}" && ! -L "${KERNEL_OBJ}" ]] || {
        echo "Final source-kernel output is unavailable: ${KERNEL_OBJ}" >&2
        return 1
    }
    if ! abi_output="$("${KERNEL_ABI_CHECK_TOOL}" --module-mode source "${KERNEL_OBJ}")"; then
        echo "Final source kernel or source connectivity modules failed the ABI gate." >&2
        return 1
    fi
    abi_get_exact() {
        local key="$1"
        awk -F= -v key="${key}" '
            $1 == key {
                count++
                value = substr($0, length(key) + 2)
            }
            END {
                if (count != 1 || value == "") exit 1
                print value
            }
        ' <<<"${abi_output}"
    }

    [[ "$(abi_get_exact status)" == PASS && \
       "$(abi_get_exact candidate_metadata_errors)" == 0 && \
       "$(abi_get_exact module_signature_compatible)" == yes && \
       "$(abi_get_exact candidate_uts_release)" == 3.18.119 && \
       "$(abi_get_exact candidate_vermagic)" == \
           '3.18.119 SMP preempt mod_unload modversions aarch64' && \
       "$(abi_get_exact module_mode)" == source && \
       "$(abi_get_exact modules)" == 5 ]] || {
        echo "Source-kernel ABI report has invalid target metadata." >&2
        return 1
    }

    for label in image_gz config module_symvers vmlinux; do
        case "${label}" in
            image_gz)
                expected_path=arch/arm64/boot/Image.gz
                artifact="${KERNEL_OBJ}/${expected_path}"
                expected_sha="$(abi_get_exact candidate_image_gz_sha256)"
                expected_bytes="$(abi_get_exact candidate_image_gz_bytes)"
                ;;
            config)
                expected_path=.config
                artifact="${KERNEL_OBJ}/${expected_path}"
                expected_sha="$(abi_get_exact candidate_dot_config_sha256)"
                expected_bytes="$(abi_get_exact candidate_dot_config_bytes)"
                ;;
            module_symvers)
                expected_path=Module.symvers
                artifact="${KERNEL_OBJ}/${expected_path}"
                expected_sha="$(abi_get_exact candidate_symvers_sha256)"
                expected_bytes="$(abi_get_exact candidate_symvers_bytes)"
                ;;
            vmlinux)
                expected_path=vmlinux
                artifact="${KERNEL_OBJ}/${expected_path}"
                expected_sha="$(abi_get_exact candidate_vmlinux_sha256)"
                expected_bytes="$(abi_get_exact candidate_vmlinux_bytes)"
                ;;
        esac
        [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ && \
           "${expected_bytes}" =~ ^[0-9]+$ && "${expected_bytes}" -gt 0 && \
           "$(file_sha256 "${artifact}")" == "${expected_sha}" && \
           "$(stat -c %s "${artifact}")" == "${expected_bytes}" ]] || {
            echo "Source-kernel ABI report does not bind final ${expected_path}." >&2
            return 1
        }
        printf 'kernel.%s.path=%s\n' "${label}" "${expected_path}"
        printf 'kernel.%s.sha256=%s\n' "${label}" "${expected_sha}"
        printf 'kernel.%s.bytes=%s\n' "${label}" "${expected_bytes}"
    done

    [[ -f "${PRODUCT_OUT}/kernel" && ! -L "${PRODUCT_OUT}/kernel" && \
       -s "${PRODUCT_OUT}/kernel" ]] && \
       cmp -s "${PRODUCT_OUT}/kernel" \
           "${KERNEL_OBJ}/arch/arm64/boot/Image.gz" || {
        echo "PRODUCT_OUT/kernel is not the ABI-gated source Image.gz." >&2
        return 1
    }

    kernel_tmp="$(mktemp -d /tmp/k50-build-kernel-contract.XXXXXX)"
    cleanup_kernel_contract() {
        if [[ -d "${kernel_tmp:-}" && ! -L "${kernel_tmp}" && \
              "${kernel_tmp}" == /tmp/k50-build-kernel-contract.* ]]; then
            find "${kernel_tmp}" -mindepth 1 -depth -delete
            rmdir "${kernel_tmp}"
        fi
    }
    trap cleanup_kernel_contract EXIT
    for image in boot recovery; do
        [[ -f "${image_dir}/${image}.img" && \
           ! -L "${image_dir}/${image}.img" && \
           -s "${image_dir}/${image}.img" ]] || {
            echo "Cannot validate ${image}.img against source Image.gz." >&2
            return 1
        }
        unpack_dir="${kernel_tmp}/${image}"
        mkdir "${unpack_dir}"
        "${UNPACK_BOOTIMG}" --boot_img "${image_dir}/${image}.img" \
            --out "${unpack_dir}" --format info \
            >"${kernel_tmp}/${image}.info" || {
            echo "unpack_bootimg rejected receipt ${image}.img." >&2
            return 1
        }
        [[ -f "${unpack_dir}/kernel" && ! -L "${unpack_dir}/kernel" && \
           -s "${unpack_dir}/kernel" ]] && \
           cmp -s "${unpack_dir}/kernel" \
               "${KERNEL_OBJ}/arch/arm64/boot/Image.gz" || {
            echo "${image}.img does not embed the ABI-gated source Image.gz." >&2
            return 1
        }
    done
    cmp -s "${kernel_tmp}/boot/kernel" "${kernel_tmp}/recovery/kernel" || {
        echo "boot.img and recovery.img embed different source kernels." >&2
        return 1
    }

    local module_contract="${kernel_tmp}/module-contract" module field
    {
        printf 'kernel.uts_release=%s\n' "$(abi_get_exact candidate_uts_release)"
        printf 'kernel.mode=source\n'
        printf 'kernel.image_name=Image.gz\n'
        printf 'kernel.abi.status=%s\n' "$(abi_get_exact status)"
        printf 'kernel.abi.metadata_errors=%s\n' \
            "$(abi_get_exact candidate_metadata_errors)"
        printf 'kernel.abi.module_signature_compatible=%s\n' \
            "$(abi_get_exact module_signature_compatible)"
        printf 'kernel.vermagic=%s\n' "$(abi_get_exact candidate_vermagic)"
        printf 'kernel.module_layout=%s\n' "$(abi_get_exact module_layout_actual)"
        printf 'kernel.module_layout_vmlinux=%s\n' \
            "$(abi_get_exact module_layout_vmlinux_actual)"
        printf 'kernel.modules=%s\n' "$(abi_get_exact modules)"
        printf 'kernel.expected_pairs=%s\n' "$(abi_get_exact expected_pairs)"
        printf 'kernel.builtin_expected=%s\n' "$(abi_get_exact built_in_expected)"
        printf 'kernel.inter_module_expected=%s\n' \
            "$(abi_get_exact inter_module_expected)"
        printf 'kernel.module_inter_ok=%s\n' "$(abi_get_exact module_inter_ok)"
        printf 'kernel.candidate_builtin_ok=%s\n' \
            "$(abi_get_exact candidate_builtin_ok)"
        printf 'kernel.candidate_inter_ok=%s\n' \
            "$(abi_get_exact candidate_inter_ok)"
        for field in module_mode module_install module_strip_tool_sha256 module_signature \
            module_invariant_errors undefined_symbols versioned_imports; do
            printf 'kernel.%s=%s\n' "${field}" "$(abi_get_exact "${field}")"
        done
        printf 'kernel.module_exports=%s\n' "$(abi_get_exact module_exports_expected)"
        printf 'kernel.candidate_exports_ok=%s\n' "$(abi_get_exact candidate_module_exports_ok)"
        for module in "${CONNECTIVITY_MODULES[@]}"; do
            for field in path sha256 bytes installed_sha256 installed_bytes; do
                printf 'kernel.module.%s.%s=%s\n' "${module}" "${field}" \
                    "$(abi_get_exact "module_${field}.${module}.ko")"
            done
            artifact="${KERNEL_OBJ}/$(abi_get_exact "module_path.${module}.ko")"
            [[ "$(file_sha256 "${artifact}")" == "$(abi_get_exact "module_sha256.${module}.ko")" && \
               "$(stat -c %s "${artifact}")" == "$(abi_get_exact "module_bytes.${module}.ko")" ]] || {
                echo "Kbuild module changed while binding its receipt: ${module}.ko" >&2
                return 1
            }
        done
        printf 'tool.check_module_abi_sha256=%s\n' \
            "$(file_sha256 "${KERNEL_ABI_CHECK_TOOL}")"
    } >"${module_contract}"
    "${KERNEL_ABI_CHECK_TOOL}" --verify-contract "${module_contract}" \
        --verify-installed "${PRODUCT_OUT}/vendor/lib/modules" >/dev/null || return 1
    cat "${module_contract}"
)

emit_build_receipt() {
    local image_dir="$1"
    local pipeline="$2"
    local targets="$3"
    local source_after repo_after source_sha repo_sha declared_repo_sha
    local receipt_incomplete source_incomplete repo_incomplete
    local completed_at image image_path image_sha image_bytes
    local real_fingerprint build_incremental
    local release_keyset_file release_keyset_sha kernel_contract
    local final_kernel_contract

    [[ "${RECEIPT_ELIGIBLE}" == true ]] || {
        echo "Internal error: attempted to emit a receipt for an ineligible build." >&2
        return 1
    }
    [[ -d "${image_dir}" && ! -L "${image_dir}" ]] || {
        echo "Receipt image directory is not an ordinary directory: ${image_dir}" >&2
        return 1
    }

    kernel_contract="$(collect_source_kernel_contract "${image_dir}")" || return 1

    source_after="${BUILD_INPUT_TMP}/source-state.after"
    repo_after="${BUILD_INPUT_TMP}/repo-manifest.after.xml"
    "${BUILD_INPUT_TOOL}" --repo-manifest "${repo_after}" >"${source_after}"
    cmp -s "${BUILD_SOURCE_BEFORE}" "${source_after}" || {
        echo "Source state changed while the Android build/signing pipeline ran." >&2
        diff -u "${BUILD_SOURCE_BEFORE}" "${source_after}" >&2 || true
        return 1
    }
    cmp -s "${BUILD_REPO_BEFORE}" "${repo_after}" || {
        echo "Revision-pinned Android repo manifest changed during the build." >&2
        return 1
    }

    source_sha="$(file_sha256 "${BUILD_SOURCE_BEFORE}")" || return 1
    repo_sha="$(file_sha256 "${BUILD_REPO_BEFORE}")" || return 1
    declared_repo_sha="$(manifest_get_exact \
        android_repo.revision_manifest_sha256 "${BUILD_SOURCE_BEFORE}")" || {
        echo "Build source state has no unique Android repo-manifest digest." >&2
        return 1
    }
    [[ "${repo_sha}" == "${declared_repo_sha}" ]] || {
        echo "Build source state does not bind its Android repo manifest." >&2
        return 1
    }

    if [[ "${BUILD_TIER}" == 3 ]]; then
        real_fingerprint="$(manifest_get_exact ro.system.build.fingerprint \
            "${signed_system_build_prop}")" || return 1
        build_incremental="$(manifest_get_exact ro.system.build.version.incremental \
            "${signed_system_build_prop}")" || return 1
    else
        real_fingerprint="$(tr -d '\r\n' <"${PRODUCT_OUT}/build_fingerprint.txt")" || {
            echo "Cannot read the clean build's generated fingerprint file." >&2
            return 1
        }
        build_incremental="$(tr -d '\r\n' <"${LINEAGE_ROOT}/out/build_number.txt")" || {
            echo "Cannot read the clean build's generated build-number file." >&2
            return 1
        }
    fi
    [[ "${real_fingerprint}" =~ \
       ^XSH/lineage_k50sv1_64_bsp/k50sv1_64_bsp:10/QQ3A\.200805\.001/[0-9A-Za-z._-]+:${BUILD_VARIANT}/(test-keys|release-keys)$ && \
       "${build_incremental}" =~ ^[0-9A-Za-z._-]+$ ]] || {
        echo "Generated clean build fingerprint/incremental is structurally invalid." >&2
        return 1
    }

    if [[ "${BUILD_TIER}" == 3 ]]; then
        release_keyset_file="${RELEASE_KEYSET_NAME}"
        [[ -f "${image_dir}/${release_keyset_file}" && \
           ! -L "${image_dir}/${release_keyset_file}" && \
           -s "${image_dir}/${release_keyset_file}" ]] || {
            echo "Tier-3 public release-keyset manifest is missing." >&2
            return 1
        }
        # The manifest's own shape is not re-verified here: this process wrote
        # it, so running the verifier on it only proves keyset_put echoed its
        # arguments back. verify-stage-contract.sh runs that verifier against
        # the published bundle, which is input no writer of it produced.
        release_keyset_sha="$(file_sha256 \
            "${image_dir}/${release_keyset_file}")" || return 1
    else
        release_keyset_file=none
        release_keyset_sha=none
    fi

    completed_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    [[ "${completed_at}" =~ \
       ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
        echo "Cannot derive a strict UTC build-completion timestamp." >&2
        return 1
    }

    receipt_incomplete="${image_dir}/.${BUILD_RECEIPT_NAME}.incomplete"
    source_incomplete="${image_dir}/.${BUILD_SOURCE_STATE_NAME}.incomplete"
    repo_incomplete="${image_dir}/.${BUILD_REPO_MANIFEST_NAME}.incomplete"
    for final_path in \
        "${image_dir}/${BUILD_RECEIPT_NAME}" \
        "${image_dir}/${BUILD_SOURCE_STATE_NAME}" \
        "${image_dir}/${BUILD_REPO_MANIFEST_NAME}" \
        "${receipt_incomplete}" "${source_incomplete}" "${repo_incomplete}"; do
        [[ ! -e "${final_path}" && ! -L "${final_path}" ]] || {
            echo "Refusing to overwrite an existing receipt artifact: ${final_path}" >&2
            return 1
        }
    done

    cp -- "${BUILD_SOURCE_BEFORE}" "${source_incomplete}"
    cp -- "${BUILD_REPO_BEFORE}" "${repo_incomplete}"
    chmod 0644 "${source_incomplete}" "${repo_incomplete}"
    cmp -s "${BUILD_SOURCE_BEFORE}" "${source_incomplete}" \
        || { echo "Copied build source state changed." >&2; return 1; }
    cmp -s "${BUILD_REPO_BEFORE}" "${repo_incomplete}" \
        || { echo "Copied Android repo manifest changed." >&2; return 1; }

    : >"${receipt_incomplete}"
    receipt_put() {
        local key="$1"
        local value="$2"
        [[ "${key}" =~ ^[a-z0-9_.]+$ && -n "${value}" && \
           "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] || {
            echo "Unsafe build-receipt field: ${key}" >&2
            return 1
        }
        printf '%s=%s\n' "${key}" "${value}" >>"${receipt_incomplete}"
    }
    receipt_put receipt.version 4
    receipt_put product k50sv1_64_bsp
    receipt_put tier "${BUILD_TIER}"
    receipt_put variant "${BUILD_VARIANT}"
    receipt_put pipeline "${pipeline}"
    receipt_put build.targets "${targets}"
    receipt_put build.clean_output true
    receipt_put build.started_at_utc "${BUILD_STARTED_AT_UTC}"
    receipt_put build.completed_at_utc "${completed_at}"
    receipt_put build.real_fingerprint "${real_fingerprint}"
    receipt_put build.incremental "${build_incremental}"
    receipt_put source_state.file "${BUILD_SOURCE_STATE_NAME}"
    receipt_put source_state.sha256 "${source_sha}"
    receipt_put android_repo_manifest.file "${BUILD_REPO_MANIFEST_NAME}"
    receipt_put android_repo_manifest.sha256 "${repo_sha}"
    receipt_put release_keyset.file "${release_keyset_file}"
    receipt_put release_keyset.sha256 "${release_keyset_sha}"
    receipt_put tool.capture_build_inputs_sha256 "$(file_sha256 "${BUILD_INPUT_TOOL}")"
    receipt_put tool.run_lineage_build_sha256 "$(file_sha256 "${TOOL_DIR}/run-lineage-build.sh")"
    receipt_put tool.stage_tier_images_sha256 "$(file_sha256 "${STAGE_IMAGES_TOOL}")"
    receipt_put tool.check_wfc_framework_resource_sha256 "$(file_sha256 "${WFC_RESOURCE_TOOL}")"
    receipt_put tool.prepare_tier3_keyset_sha256 "$(file_sha256 "${KEYSET_PREPARE_TOOL}")"
    receipt_put tool.verify_tier3_properties_sha256 "$(file_sha256 "${TIER3_PROPERTY_VERIFY_TOOL}")"
    receipt_put tool.verify_tier3_keyset_manifest_sha256 "$(file_sha256 "${KEYSET_MANIFEST_VERIFY_TOOL}")"
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
        kernel.candidate_builtin_ok kernel.candidate_inter_ok \
        tool.check_module_abi_sha256; do
        receipt_put "${kernel_key}" "$(manifest_get_exact \
            "${kernel_key}" <(printf '%s\n' "${kernel_contract}"))"
    done
    for image in boot recovery system vendor; do
        image_path="${image_dir}/${image}.img"
        [[ -f "${image_path}" && ! -L "${image_path}" && -s "${image_path}" ]] || {
            echo "Successful pipeline did not produce ${image}.img." >&2
            return 1
        }
        image_sha="$(file_sha256 "${image_path}")" || return 1
        image_bytes="$(stat -c %s "${image_path}")" || return 1
        [[ "${image_bytes}" =~ ^[0-9]+$ && "${image_bytes}" -gt 0 ]] || {
            echo "Invalid ${image}.img size: ${image_bytes}" >&2
            return 1
        }
        receipt_put "image.${image}.sha256" "${image_sha}"
        receipt_put "image.${image}.bytes" "${image_bytes}"
    done
    chmod 0644 "${receipt_incomplete}"

    # Re-read every image before publishing the receipt commit marker so no
    # failure path can leave a final-looking receipt behind.
    for image in boot recovery system vendor; do
        image_sha="$(manifest_get_exact "image.${image}.sha256" \
            "${receipt_incomplete}")" || return 1
        [[ "$(file_sha256 "${image_dir}/${image}.img")" == "${image_sha}" ]] || {
            echo "${image}.img changed while its build receipt was prepared." >&2
            return 1
        }
    done

    final_kernel_contract="$(collect_source_kernel_contract "${image_dir}")" \
        || return 1
    [[ "${final_kernel_contract}" == "${kernel_contract}" ]] || {
        echo "Source-kernel artifacts changed while the build receipt was prepared." >&2
        return 1
    }

    # Publish the receipt last: it is the commit marker for the two files it
    # names. A crash can leave harmless .incomplete files but never a valid
    # receipt pointing at an absent source record.
    mv -T "${source_incomplete}" "${image_dir}/${BUILD_SOURCE_STATE_NAME}"
    mv -T "${repo_incomplete}" "${image_dir}/${BUILD_REPO_MANIFEST_NAME}"
    mv -T "${receipt_incomplete}" "${image_dir}/${BUILD_RECEIPT_NAME}"
    printf 'Atomic clean-build receipt: %s/%s\n' \
        "${image_dir}" "${BUILD_RECEIPT_NAME}"
}

check_built_launcher_policy() {
    local report="${PRODUCT_OUT}/K50SV1-LAUNCHER-POLICY.json"
    if ! python3 "${LAUNCHER_POLICY_TOOL}" product --lineage-root "${LINEAGE_ROOT}" \
            --product-out "${PRODUCT_OUT}" >"${report}"; then
        cat "${report}" >&2
        echo "Built partitions failed Niagara removal/Trebuchet validation." >&2
        return 1
    fi
    printf 'Built launcher policy: PASS (%s)\n' "${report}"
}

if [[ "${BUILD_TIER}" != 3 ]]; then
    run_android_build -j"${BUILD_JOBS}" "$@"
    if [[ "${RECEIPT_ELIGIBLE}" == true ]]; then
        check_built_launcher_policy
        emit_build_receipt "${PRODUCT_OUT}" android-four-image \
            bootimage,recoveryimage,systemimage,vendorimage
    else
        printf 'Build completed without a stageable receipt (requires clean output and the default four targets).\n'
    fi
    exit 0
fi

# Tier 3 uses Android's release signing flow to replace dev/test tags with
# release-keys, re-sign APKs and any installed archive APEX containers/payloads,
# and then exposes only the four physical partition images requested for this
# A-only device. The target-files package is a signing intermediate, not a
# published OTA.
release_stamp="$(date -u +%Y%m%d_%H%M%S)"
mkdir -p "${RELEASE_OUTPUT_ROOT}"
staging_dir="$(mktemp -d "${RELEASE_OUTPUT_ROOT}/.tier3-${release_stamp}.XXXXXX")"
release_nonce="${staging_dir##*.}"
release_dir="${RELEASE_OUTPUT_ROOT}/k50sv1_64_bsp-tier3-${release_stamp}-${release_nonce}"
cleanup_tier3_staging() {
    find "${staging_dir}" -depth -delete 2>/dev/null || true
}
trap 'cleanup_tier3_staging || true; cleanup_build_input_tmp || true; cleanup_key_snapshot || true' EXIT

dist_dir="${staging_dir}/dist"
mkdir -p "${dist_dir}"
DIST_DIR="${dist_dir}" run_android_build \
    -j"${BUILD_JOBS}" target-files-package dist
check_built_launcher_policy

target_files_candidates=()
while IFS= read -r -d '' candidate; do
    target_files_candidates+=("${candidate}")
done < <(
    find "${dist_dir}" -maxdepth 1 -type f \
        -name 'lineage_k50sv1_64_bsp-target_files-*.zip' -print0
)
if [[ ${#target_files_candidates[@]} -ne 1 ]]; then
    echo "Expected exactly one Tier-3 target-files package in ${dist_dir}; found ${#target_files_candidates[@]}." >&2
    exit 1
fi
target_files="${target_files_candidates[0]}"

if ! unzip -tq "${target_files}" >/dev/null; then
    echo "Built target-files package failed ZIP integrity validation: ${target_files}" >&2
    exit 1
fi

prepared_target_files="${staging_dir}/k50sv1_64_bsp-prepared-target_files.zip"
signed_target_files="${staging_dir}/k50sv1_64_bsp-signed-target_files.zip"
staged_release_dir="${staging_dir}/release"
misc_edit_dir="${staging_dir}/misc-edit"
mkdir -p "${staged_release_dir}" "${misc_edit_dir}/META"

# This legacy A-only target uses Android BootSignature without enabling
# dm-verity. AOSP therefore records boot_signer=true but omits the legacy-named
# `verity_key` releasetools input. Inject that compatibility field into a
# disposable archive, but point it at the rotated external `bootsignature`
# snapshot. Internally this pipeline never calls the key "verity": it is not a
# verified-boot root and the unlocked/orange bootloader does not enforce it.
cp --reflink=auto "${target_files}" "${prepared_target_files}"
unzip -p "${target_files}" META/misc_info.txt \
    | awk -v key="${RELEASE_KEYS_DIR}/bootsignature" \
        '$0 !~ /^verity_key=/{ print } END { print "verity_key=" key }' \
        >"${misc_edit_dir}/META/misc_info.txt"
(
    cd "${misc_edit_dir}"
    zip -q "${prepared_target_files}" META/misc_info.txt
)
# Read this back OUT of the archive, not out of the staging file.
#
# The gate used to grep "${misc_edit_dir}/META/misc_info.txt" -- the file the
# awk step had just written -- while its error message claimed the injection
# into ${prepared_target_files} had been verified. It therefore proved that awk
# can print a line it was told to print, and would have passed unchanged if the
# `zip` above had failed, been a no-op, or written to a different member.
#
# No pipe into grep -q: `unzip -p | grep -q` under `set -o pipefail` is the
# SIGPIPE trap this project has already paid for twice (HANDOFF trap 6, and the
# same lesson restated in flash-tier-images.sh:145-157).
injected_misc_info="$(unzip -p "${prepared_target_files}" META/misc_info.txt)"
injected_bootsignature_mappings="$(
    awk '/^verity_key=/ {count++} END {print count + 0}' <<<"${injected_misc_info}"
)"
if [[ "${injected_bootsignature_mappings}" -ne 1 ]] || \
   ! grep -Fxq "verity_key=${RELEASE_KEYS_DIR}/bootsignature" \
        <<<"${injected_misc_info}"; then
    echo "Failed to inject the Tier-3 BootSignature key into target-files: META/misc_info.txt in the archive carries ${injected_bootsignature_mappings} verity_key line(s)." >&2
    exit 1
fi

# Read out of the ARCHIVE, exactly once, and refuse to guess.
#
# Three defects in four lines, all of them the ones the verity_key gate directly
# above was already fixed for. It read ${misc_edit_dir}/META/misc_info.txt --
# the scratch file the awk step had just written -- rather than the archive that
# releasetools will actually consume. It took the FIRST match, so a duplicate
# record silently picked a winner. And an ABSENT record was replaced with a
# hardcoded testkey path, which is the base of the key directory every
# non-PRESIGNED APK's expected certificate is resolved against below: a
# target-files that declares no default certificate silently acquired one.
default_system_dev_certificate_records="$(
    awk '/^default_system_dev_certificate=/ { count++ }
         END { print count + 0 }' <<<"${injected_misc_info}"
)"
if [[ "${default_system_dev_certificate_records}" -ne 1 ]]; then
    echo "META/misc_info.txt in the target-files archive carries ${default_system_dev_certificate_records} default_system_dev_certificate line(s); exactly one is required to resolve APK certificates." >&2
    exit 1
fi
default_system_dev_certificate="$(
    sed -n 's/^default_system_dev_certificate=//p' <<<"${injected_misc_info}"
)"
if [[ -z "${default_system_dev_certificate}" || \
      "${default_system_dev_certificate}" != */?* ]]; then
    echo "META/misc_info.txt declares default_system_dev_certificate=${default_system_dev_certificate:-<empty>}, which is not a key path." >&2
    exit 1
fi
default_dev_key_dir="${default_system_dev_certificate%/*}"

apex_keys_file="${staging_dir}/apexkeys.txt"
unzip -p "${prepared_target_files}" META/apexkeys.txt >"${apex_keys_file}"
if [[ ! -s "${apex_keys_file}" ]]; then
    echo "Target-files has no readable META/apexkeys.txt." >&2
    exit 1
fi

target_files_entries="${staging_dir}/target-files-entries.txt"
unzip -Z1 "${prepared_target_files}" >"${target_files_entries}"

# Build a basename-to-certificate map exactly as releasetools will. Split APK
# basenames must be globally unique on Android Q; duplicate records would make
# release signing ambiguous.
#
# WAS BROKEN: this loop stored the certificate string verbatim, and the `case`
# below compared it against extension-less key paths ("${default_dev_key_dir}/
# platform", "${RELEASE_KEYS_DIR}/releasekey", ...). apkcerts.txt does not hold
# extension-less paths. It holds the certificate WITH its `.x509.pem` suffix,
# and that is not a build-config accident: `build/make/core/package_internal.mk:558`
# computes `certificate := $(LOCAL_CERTIFICATE).x509.pem` and
# `build/make/core/Makefile:713` writes exactly that value into
# `PACKAGES.<m>.CERTIFICATE`, which `_apkcerts_write_line` (Makefile:690) emits.
# So no `case` arm could ever match, every non-PRESIGNED APK fell through to the
# `*)` error arm, and Tier 3 exited 1 before it signed anything -- the whole
# tier was unreachable, not merely wrong. AOSP's own consumer strips the suffix
# before comparing: `build/make/tools/releasetools/common.py:1264-1271` stores
# `cert[:-len(".x509.pem")]` in its certmap. Do the same here, exempting only
# the two magic strings releasetools exempts (`SPECIAL_CERT_STRINGS`,
# common.py:96).
apkcerts_file="${staging_dir}/apkcerts.txt"
unzip -p "${prepared_target_files}" META/apkcerts.txt >"${apkcerts_file}"
if [[ ! -s "${apkcerts_file}" ]]; then
    echo "Target-files has no readable META/apkcerts.txt." >&2
    exit 1
fi
declare -A apk_certificate_map=()
while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" != name=\"* || "${line}" != *' certificate="'* ]]; then
        echo "Malformed APK certificate record: ${line}" >&2
        exit 1
    fi
    apk_name="${line#name=\"}"
    apk_name="${apk_name%%\"*}"
    apk_certificate="${line#* certificate=\"}"
    apk_certificate="${apk_certificate%%\"*}"
    if [[ -z "${apk_name}" || "${apk_name}" == */* || \
          "${apk_name}" != *.apk || -z "${apk_certificate}" ]]; then
        echo "Invalid APK certificate record: ${line}" >&2
        exit 1
    fi
    # PRESIGNED and EXTERNAL are magic words, not paths, and carry no suffix:
    # `build/make/core/app_prebuilt_internal.mk:125` assigns the bare token
    # PRESIGNED, and `build/make/core/Makefile:711` writes EXTERNAL literally.
    # Everything else MUST be a `.x509.pem` path. A non-PRESIGNED value that is
    # not is either a build-system change or a corrupted record, and quietly
    # accepting it would put an unverifiable certificate into the signing map,
    # so hard-fail instead of guessing -- the same choice common.py:1272 makes
    # with its `raise ValueError`.
    case "${apk_certificate}" in
        PRESIGNED | EXTERNAL) ;;
        *.x509.pem) apk_certificate="${apk_certificate%.x509.pem}" ;;
        *)
            echo "APK certificate is neither PRESIGNED/EXTERNAL nor a .x509.pem path: ${line}" >&2
            exit 1
            ;;
    esac
    if [[ -n "${apk_certificate_map[${apk_name}]:-}" ]]; then
        echo "Duplicate APK certificate record: ${apk_name}" >&2
        exit 1
    fi
    apk_certificate_map["${apk_name}"]="${apk_certificate}"
done <"${apkcerts_file}"

presigned_apk_entries=()
signed_apk_entries=()
signed_apk_expected_keys=()
declare -A installed_apk_name_set=()
while IFS= read -r entry; do
    [[ "${entry}" == *.apk ]] || continue
    apk_name="${entry##*/}"
    if [[ -n "${installed_apk_name_set[${apk_name}]:-}" ]]; then
        echo "Installed APK basename is not globally unique: ${apk_name}" >&2
        exit 1
    fi
    installed_apk_name_set["${apk_name}"]=1
    installed_apk_certificate="${apk_certificate_map[${apk_name}]:-}"
    if [[ -z "${installed_apk_certificate}" ]]; then
        echo "Installed APK has no certificate record: ${entry}" >&2
        exit 1
    fi
    if [[ "${installed_apk_certificate}" == PRESIGNED ]]; then
        presigned_apk_entries+=("${entry}")
        continue
    fi
    # EXTERNAL is deliberately NOT given an arm below. It means the APK is
    # signed by a tool outside this build, so Tier 3 can make no statement at
    # all about its signer; it must fall through to the `*)` refusal rather
    # than be waved past. The `.x509.pem` suffix has already been stripped by
    # the map loop above, so these arms compare like against like.
    case "${installed_apk_certificate}" in
        "${default_dev_key_dir}/testkey" | "${default_dev_key_dir}/devkey")
            expected_release_key=releasekey
            ;;
        "${default_dev_key_dir}/platform") expected_release_key=platform ;;
        "${default_dev_key_dir}/shared") expected_release_key=shared ;;
        "${default_dev_key_dir}/media") expected_release_key=media ;;
        "${default_dev_key_dir}/networkstack") expected_release_key=networkstack ;;
        "${RELEASE_KEYS_DIR}/releasekey") expected_release_key=releasekey ;;
        "${RELEASE_KEYS_DIR}/platform") expected_release_key=platform ;;
        "${RELEASE_KEYS_DIR}/shared") expected_release_key=shared ;;
        "${RELEASE_KEYS_DIR}/media") expected_release_key=media ;;
        "${RELEASE_KEYS_DIR}/networkstack") expected_release_key=networkstack ;;
        *)
            echo "Installed APK uses an unmapped/non-release certificate: ${entry}: ${installed_apk_certificate}" >&2
            exit 1
            ;;
    esac
    signed_apk_entries+=("${entry}")
    signed_apk_expected_keys+=("${expected_release_key}")
done <"${target_files_entries}"

declare -A installed_apex_set=()
flattened_apex_found=false
while IFS= read -r entry; do
    [[ "${entry}" == SYSTEM/apex/* ]] || continue
    apex_relative_path="${entry#SYSTEM/apex/}"
    if [[ "${apex_relative_path}" != */* && \
          "${apex_relative_path}" == *.apex ]]; then
        installed_apex_name="${apex_relative_path}"
        if [[ -n "${installed_apex_set[${installed_apex_name}]:-}" ]]; then
            echo "Duplicate installed APEX entry: ${entry}" >&2
            exit 1
        fi
        installed_apex_set["${installed_apex_name}"]=1
    elif [[ "${apex_relative_path}" == */* ]]; then
        # Android Q defaults this legacy target to flattened APEX directories.
        # Flattened contents have no outer APK certificate or payload AVB
        # object to re-sign; sign only actual *.apex archive entries above.
        flattened_apex_found=true
    fi
done <"${target_files_entries}"
if [[ ${#installed_apex_set[@]} -eq 0 && \
      "${flattened_apex_found}" != true ]]; then
    echo "Target-files contains neither flattened nor archive APEX content." >&2
    exit 1
fi

declare -A apex_payload_key_map=()
if [[ "${#installed_apex_set[@]}" -eq 0 ]]; then
    if [[ -e "${RELEASE_KEYS_DIR}/apex-map.tsv" || \
          -L "${RELEASE_KEYS_DIR}/apex-map.tsv" || \
          -e "${RELEASE_KEYS_DIR}/apex" || \
          -L "${RELEASE_KEYS_DIR}/apex" ]]; then
        echo "Archive APEX count is zero, but the external snapshot contains archive-APEX key material." >&2
        exit 1
    fi
else
    [[ -f "${RELEASE_KEYS_DIR}/apex-map.tsv" && \
       ! -L "${RELEASE_KEYS_DIR}/apex-map.tsv" && \
       -s "${RELEASE_KEYS_DIR}/apex-map.tsv" ]] || {
        echo "Archive APEX modules require an exact per-module apex-map.tsv." >&2
        exit 1
    }
    while IFS=$'\t' read -r mapped_apex mapped_key extra || \
          [[ -n "${mapped_apex}${mapped_key}${extra}" ]]; do
        [[ -n "${mapped_apex}" && -n "${mapped_key}" && -z "${extra}" && \
           "${mapped_apex}" =~ ^[A-Za-z0-9._-]+\.apex$ && \
           "${mapped_key}" == "apex/${mapped_apex}.pem" && \
           -f "${RELEASE_KEYS_DIR}/${mapped_key}" && \
           ! -L "${RELEASE_KEYS_DIR}/${mapped_key}" && \
           -z "${apex_payload_key_map[${mapped_apex}]:-}" ]] || {
            echo "Invalid or duplicate per-module APEX mapping: ${mapped_apex:-<empty>}" >&2
            exit 1
        }
        apex_payload_key_map["${mapped_apex}"]="${mapped_key}"
    done <"${RELEASE_KEYS_DIR}/apex-map.tsv"
    [[ "${#apex_payload_key_map[@]}" -eq "${#installed_apex_set[@]}" ]] || {
        echo "Archive APEX key-map count does not match installed archive count." >&2
        exit 1
    }
    for apex_name in "${!installed_apex_set[@]}"; do
        [[ -n "${apex_payload_key_map[${apex_name}]:-}" ]] || {
            echo "Installed archive APEX has no private payload-key mapping: ${apex_name}" >&2
            exit 1
        }
    done
    for apex_name in "${!apex_payload_key_map[@]}"; do
        [[ -n "${installed_apex_set[${apex_name}]:-}" ]] || {
            echo "APEX key map names a module absent from target-files: ${apex_name}" >&2
            exit 1
        }
    done
fi

# Releasetools consumes avbtool from the just-built host output. Put that exact
# tool first before inspecting any original archive payload or signing it.
export PATH="${LINEAGE_ROOT}/out/host/linux-x86/bin:${PATH}"
command -v avbtool >/dev/null 2>&1 || {
    echo "Built host avbtool is unavailable for archive-APEX verification." >&2
    exit 1
}

apex_key_args=()
signed_apex_names=()
declare -A apex_key_record_set=()

resolve_apex_source_key() {
    local recorded_path="$1"
    local candidate resolved

    [[ -n "${recorded_path}" && "${recorded_path}" != PRESIGNED ]] || return 1
    if [[ "${recorded_path}" == /* ]]; then
        candidate="${recorded_path}"
    else
        candidate="${LINEAGE_ROOT}/${recorded_path}"
    fi
    resolved="$(realpath -e -- "${candidate}")" || return 1
    [[ "${resolved}" == "${LINEAGE_ROOT}/"* && \
       -f "${resolved}" && ! -L "${resolved}" ]] || return 1
    printf '%s' "${resolved}"
}

while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    if [[ "${line}" != name=\"* || \
          "${line}" != *' public_key="'* || \
          "${line}" != *' private_key="'* || \
          "${line}" != *' container_certificate="'* || \
          "${line}" != *' container_private_key="'* ]]; then
        echo "Malformed APEX key record: ${line}" >&2
        exit 1
    fi
    if [[ "${line}" == *'private_key="PRESIGNED"'* ]]; then
        if [[ "${line}" != *'public_key="PRESIGNED"'* || \
              "${line}" != *'container_certificate="PRESIGNED"'* || \
              "${line}" != *'container_private_key="PRESIGNED"'* ]]; then
            echo "Partially presigned APEX key record is unsupported: ${line}" >&2
            exit 1
        fi
    fi
    apex_name="${line#*name=\"}"
    apex_name="${apex_name%%\"*}"
    source_apex_public_record="${line#* public_key=\"}"
    source_apex_public_record="${source_apex_public_record%%\"*}"
    source_apex_private_record="${line#* private_key=\"}"
    source_apex_private_record="${source_apex_private_record%%\"*}"
    if [[ -z "${apex_name}" || "${apex_name}" == */* || \
          "${apex_name}" != *.apex ]]; then
        echo "Invalid APEX filename in key record: ${apex_name}" >&2
        exit 1
    fi
    if [[ -n "${apex_key_record_set[${apex_name}]:-}" ]]; then
        echo "Duplicate APEX key record: ${apex_name}" >&2
        exit 1
    fi
    apex_key_record_set["${apex_name}"]=1

    # META/apexkeys.txt may list installable modules that are not selected by
    # this product (for example both runtime.release and runtime.debug). Only
    # the APEX files actually present in SYSTEM/apex belong to this release.
    [[ -n "${installed_apex_set[${apex_name}]:-}" ]] || continue

    # Before releasetools sees a mapped key, prove that the source payload,
    # apex_pubkey entry and META/apexkeys.txt identity agree; then require the
    # mapped private key to match the source AVB algorithm/key size without
    # simply reusing that source identity. Use only Android-Q avbtool options.
    source_apex_public_key="$(resolve_apex_source_key "${source_apex_public_record}")" || {
        echo "Installed archive APEX has no auditable source public key: ${apex_name}" >&2
        exit 1
    }
    source_apex_private_key="$(resolve_apex_source_key "${source_apex_private_record}")" || {
        echo "Installed archive APEX has no auditable source private key: ${apex_name}" >&2
        exit 1
    }
    original_apex="${staging_dir}/${apex_name}.original.apex"
    original_payload="${staging_dir}/${apex_name}.original.payload.img"
    original_embedded_key="${staging_dir}/${apex_name}.original.apex_pubkey"
    original_footer_key="${staging_dir}/${apex_name}.original.footer.avbpubkey"
    replacement_key="${staging_dir}/${apex_name}.replacement.avbpubkey"
    payload_info="${staging_dir}/${apex_name}.original.avb-info"
    mapped_private_key="${RELEASE_KEYS_DIR}/${apex_payload_key_map[${apex_name}]}"

    unzip -p "${prepared_target_files}" "SYSTEM/apex/${apex_name}" \
        >"${original_apex}"
    unzip -p "${original_apex}" apex_payload.img >"${original_payload}"
    unzip -p "${original_apex}" apex_pubkey >"${original_embedded_key}"
    [[ -s "${original_apex}" && -s "${original_payload}" && \
       -s "${original_embedded_key}" ]] || {
        echo "Archive APEX lacks container/payload/public-key bytes: ${apex_name}" >&2
        exit 1
    }
    cmp -s "${original_embedded_key}" "${source_apex_public_key}" || {
        echo "Archive APEX embedded key disagrees with META/apexkeys.txt: ${apex_name}" >&2
        exit 1
    }
    avbtool verify_image --image "${original_payload}" \
        --key "${source_apex_private_key}" >/dev/null || {
        echo "Original archive-APEX payload/key does not verify: ${apex_name}" >&2
        exit 1
    }
    avbtool extract_public_key --key "${source_apex_private_key}" \
        --output "${original_footer_key}"
    cmp -s "${original_embedded_key}" "${original_footer_key}" || {
        echo "Archive APEX source private/public identities disagree: ${apex_name}" >&2
        exit 1
    }
    avbtool info_image --image "${original_payload}" --output "${payload_info}"
    [[ -s "${payload_info}" ]] || {
        echo "Cannot inspect original archive-APEX AVB footer: ${apex_name}" >&2
        exit 1
    }

    mapfile -t original_algorithms < <(
        awk -F: '$1 ~ /^[[:space:]]*Algorithm[[:space:]]*$/ {
            value = $2
            gsub(/[[:space:]]/, "", value)
            print value
        }' "${payload_info}"
    )
    if [[ "${#original_algorithms[@]}" -ne 1 || \
          ! "${original_algorithms[0]}" =~ ^SHA(256|512)_RSA([0-9]+)$ ]]; then
        echo "Unsupported or ambiguous archive-APEX AVB algorithm: ${apex_name}" >&2
        exit 1
    fi
    required_apex_rsa_bits="${BASH_REMATCH[2]}"
    mapped_private_text="$(openssl pkey -in "${mapped_private_key}" -text -noout 2>/dev/null)" || {
        echo "Cannot inspect mapped archive-APEX key: ${apex_name}" >&2
        exit 1
    }
    mapped_private_bits="$(awk '
        /Private-Key: \([0-9]+ bit/ {
            value = $2
            gsub(/[^0-9]/, "", value)
            print value
            exit
        }
    ' <<<"${mapped_private_text}")"
    [[ "${mapped_private_bits}" == "${required_apex_rsa_bits}" ]] || {
        echo "Mapped archive-APEX key is RSA-${mapped_private_bits:-unknown}, but ${apex_name} requires ${original_algorithms[0]}." >&2
        exit 1
    }
    avbtool extract_public_key --key "${mapped_private_key}" \
        --output "${replacement_key}"
    [[ -s "${replacement_key}" ]] || {
        echo "Cannot derive mapped archive-APEX public key: ${apex_name}" >&2
        exit 1
    }
    ! cmp -s "${replacement_key}" "${original_embedded_key}" || {
        echo "Mapped archive-APEX key reuses the source payload identity: ${apex_name}" >&2
        exit 1
    }

    # APEX has two independent signatures. Use releasekey for the APK-like
    # outer container and the exact module-specific external key for the AVB
    # payload. Development/test source keys are replaced. A fully PRESIGNED
    # archive deliberately failed the auditable-source-key checks above rather
    # than being silently carried or described as replaceable.
    apex_key_args+=(--extra_apks "${apex_name}=${RELEASE_KEYS_DIR}/releasekey")
    apex_key_args+=(--extra_apex_payload_key \
        "${apex_name}=${RELEASE_KEYS_DIR}/${apex_payload_key_map[${apex_name}]}")
    signed_apex_names+=("${apex_name}")
done <"${apex_keys_file}"

for apex_name in "${!installed_apex_set[@]}"; do
    if [[ -z "${apex_key_record_set[${apex_name}]:-}" ]]; then
        echo "Installed APEX has no key record: ${apex_name}" >&2
        exit 1
    fi
done
"${RELEASE_PYTHON}" build/make/tools/releasetools/sign_target_files_apks.py \
    -o \
    -d "${RELEASE_KEYS_DIR}" \
    --replace_verity_private_key "${RELEASE_KEYS_DIR}/bootsignature" \
    "${apex_key_args[@]}" \
    "${prepared_target_files}" \
    "${signed_target_files}"

# PRESIGNED Google/base/split APKs and any other third-party prebuilts must be
# copied byte-for-byte through Tier 3. apkcerts metadata is not accepted as
# sufficient proof: compare the actual target-files entries after signing.
# `cmp -s <(unzip -p A x) <(unzip -p B x)` reports EQUAL when both streams are
# empty, and a process substitution hides the producer's exit status, so the
# strongest claim in this loop -- "the PRESIGNED APK came through byte for
# byte" -- was equally satisfied by "the APK is not in the signed package at
# all". Materialize both sides and require them non-empty, the way the
# signed-APK loop below already does with its `[[ ! -s "${apk_file}" ]]` guard.
presigned_apk_outputs=()
for apk_index in "${!presigned_apk_entries[@]}"; do
    apk_entry="${presigned_apk_entries[${apk_index}]}"
    presigned_apk_input="${staging_dir}/presigned-apk-${apk_index}.input"
    presigned_apk_output="${staging_dir}/presigned-apk-${apk_index}.output"
    # `unzip -p` exits 11 on a missing entry and writes nothing (measured), so
    # under `set -e` the run would abort here with unzip's own
    # "caution: filename not matched" instead of naming the APK. Let the
    # emptiness guard below do the reporting.
    unzip -p "${prepared_target_files}" "${apk_entry}" >"${presigned_apk_input}" || true
    unzip -p "${signed_target_files}" "${apk_entry}" >"${presigned_apk_output}" || true
    if [[ ! -s "${presigned_apk_input}" || ! -s "${presigned_apk_output}" ]]; then
        echo "PRESIGNED APK is empty or missing from a target-files package: ${apk_entry}" >&2
        exit 1
    fi
    if ! cmp -s "${presigned_apk_input}" "${presigned_apk_output}"; then
        echo "PRESIGNED APK was unexpectedly modified: ${apk_entry}" >&2
        exit 1
    fi
    case "${apk_entry}" in
        SYSTEM/app/CtsShimPrebuilt/CtsShimPrebuilt.apk | \
        SYSTEM/priv-app/K50CtsShimPrivPrebuilt/K50CtsShimPrivPrebuilt.apk)
            presigned_apk_outputs+=(--cts-shim "${apk_entry}")
            ;;
    esac
    presigned_apk_outputs+=("${presigned_apk_output}")
done
if [[ "${#presigned_apk_outputs[@]}" -gt 0 ]]; then
    "${PRESIGNED_APK_VERIFY_TOOL}" "${APKSIGNER_JAR}" \
        "${presigned_apk_outputs[@]}"
fi

# Metadata alone is not proof that releasetools actually replaced a test/dev
# signature. Verify every non-PRESIGNED APK, then compare its real signer digest
# with the exact mapped release certificate selected above.
for apk_index in "${!signed_apk_entries[@]}"; do
    apk_entry="${signed_apk_entries[${apk_index}]}"
    expected_release_key="${signed_apk_expected_keys[${apk_index}]}"
    apk_file="${staging_dir}/signed-apk-${apk_index}.apk"
    apk_cert_report="${staging_dir}/signed-apk-${apk_index}.certs"
    unzip -p "${signed_target_files}" "${apk_entry}" >"${apk_file}"
    if [[ ! -s "${apk_file}" ]] || \
       ! java -jar "${APKSIGNER_JAR}" verify --print-certs "${apk_file}" \
            >"${apk_cert_report}"; then
        echo "Signed APK verification failed: ${apk_entry}" >&2
        exit 1
    fi
    mapfile -t apk_certificate_digests < <(
        awk -F': ' \
            '/Signer #[0-9]+ certificate SHA-256 digest:/ {
                gsub(/[[:space:]:]/, "", $2); print tolower($2)
            }' "${apk_cert_report}"
    )
    if [[ ${#apk_certificate_digests[@]} -ne 1 || \
          "${apk_certificate_digests[0]:-}" != \
              "${RELEASE_CERTIFICATE_SHA[${expected_release_key}]}" ]]; then
        echo "Signed APK certificate mismatch: ${apk_entry}; expected ${expected_release_key}" >&2
        exit 1
    fi
done

unzip -oqj "${signed_target_files}" \
    IMAGES/boot.img \
    IMAGES/recovery.img \
    IMAGES/system.img \
    IMAGES/vendor.img \
    -d "${staged_release_dir}"

for image in boot.img recovery.img system.img vendor.img; do
    if [[ ! -s "${staged_release_dir}/${image}" ]]; then
        echo "Signed partition image is missing: ${image}" >&2
        exit 1
    fi
done

signed_system_build_prop="${staging_dir}/signed-system-build.prop"
unzip -p "${signed_target_files}" SYSTEM/build.prop >"${signed_system_build_prop}"
"${TIER3_PROPERTY_VERIFY_TOOL}" "${signed_target_files}"
signed_framework_res="${staging_dir}/signed-framework-res.apk"
unzip -p "${signed_target_files}" SYSTEM/framework/framework-res.apk \
    >"${signed_framework_res}"
[[ -s "${signed_framework_res}" ]] || {
    echo "Signed target-files has no framework-res.apk for the Tier-3 WFC gate." >&2
    exit 1
}
"${WFC_RESOURCE_TOOL}" --expect false \
    --framework-res "${signed_framework_res}"

release_certificate_sha="${RELEASE_CERTIFICATE_SHA[releasekey]}"
for trust_path in \
    SYSTEM/etc/security/otacerts.zip \
    RECOVERY/RAMDISK/system/etc/security/otacerts.zip; do
    trust_label="${trust_path//\//-}"
    trust_zip="${staging_dir}/${trust_label}"
    trust_certificate="${staging_dir}/${trust_label}.x509.pem"
    trust_entries=()

    unzip -p "${signed_target_files}" "${trust_path}" >"${trust_zip}"
    if ! unzip -tq "${trust_zip}" >/dev/null; then
        echo "Invalid signed OTA trust archive: ${trust_path}" >&2
        exit 1
    fi
    while IFS= read -r trust_entry; do
        [[ -n "${trust_entry}" ]] && trust_entries+=("${trust_entry}")
    done < <(unzip -Z1 "${trust_zip}")
    if [[ ${#trust_entries[@]} -ne 1 ]]; then
        echo "Expected exactly one release certificate in ${trust_path}." >&2
        exit 1
    fi
    unzip -p "${trust_zip}" "${trust_entries[0]}" >"${trust_certificate}"
    if ! trust_certificate_sha="$(
        openssl x509 -in "${trust_certificate}" -outform DER 2>/dev/null \
            | sha256sum | awk '{ print $1 }'
    )" || [[ -z "${trust_certificate_sha}" ]]; then
        echo "Cannot derive signed OTA trust digest: ${trust_path}" >&2
        exit 1
    fi
    if [[ "${trust_certificate_sha}" != "${release_certificate_sha}" ]]; then
        echo "Signed OTA trust does not contain only releasekey: ${trust_path}" >&2
        exit 1
    fi
done

declare -A APEX_PAYLOAD_PUBLIC_SHA=()
if [[ ${#signed_apex_names[@]} -gt 0 ]]; then
    for apex_name in "${signed_apex_names[@]}"; do
        apex_file="${staging_dir}/${apex_name}"
        apex_cert_report="${staging_dir}/${apex_name}.certs"
        apex_payload="${staging_dir}/${apex_name}.payload.img"
        apex_public_key="${staging_dir}/${apex_name}.avbpubkey"
        expected_apex_public_key="${staging_dir}/${apex_name}.expected.avbpubkey"
        apex_payload_private_key="${RELEASE_KEYS_DIR}/${apex_payload_key_map[${apex_name}]}"

        avbtool extract_public_key \
            --key "${apex_payload_private_key}" \
            --output "${expected_apex_public_key}"
        APEX_PAYLOAD_PUBLIC_SHA["${apex_name}"]="$(
            file_sha256 "${expected_apex_public_key}"
        )"

        unzip -p "${signed_target_files}" "SYSTEM/apex/${apex_name}" >"${apex_file}"
        if ! java -jar "${APKSIGNER_JAR}" verify --print-certs "${apex_file}" \
            >"${apex_cert_report}"; then
            echo "APEX container signature verification failed: ${apex_name}" >&2
            exit 1
        fi
        # "releasekey is the ONLY signer", not "Signer #1 is releasekey".
        # Reading Signer #1 and stopping accepted a container that also carries
        # a second signer, which apksigner reports as Signer #2 and which is a
        # full signing identity for the APEX. The non-PRESIGNED APK loop above
        # already collects every Signer #N digest and requires exactly one;
        # this is the same collection.
        mapfile -t apex_certificate_digests < <(
            awk -F': ' \
                '/Signer #[0-9]+ certificate SHA-256 digest:/ {
                    gsub(/[[:space:]:]/, "", $2); print tolower($2)
                }' "${apex_cert_report}"
        )
        if [[ ${#apex_certificate_digests[@]} -ne 1 || \
              "${apex_certificate_digests[0]:-}" != \
                  "${release_certificate_sha}" ]]; then
            echo "APEX container is not signed by releasekey alone: ${apex_name} has ${#apex_certificate_digests[@]} signer(s)" >&2
            exit 1
        fi

        unzip -p "${apex_file}" apex_pubkey >"${apex_public_key}"
        unzip -p "${apex_file}" apex_payload.img >"${apex_payload}"
        if ! cmp -s "${apex_public_key}" "${expected_apex_public_key}"; then
            echo "APEX embedded public key mismatch: ${apex_name}" >&2
            exit 1
        fi
        if ! avbtool verify_image --image "${apex_payload}" \
            --key "${apex_payload_private_key}" >/dev/null; then
            echo "APEX payload signature verification failed: ${apex_name}" >&2
            exit 1
        fi
    done
fi

for image in boot.img recovery.img; do
    if ! boot_signer -verify "${staged_release_dir}/${image}" \
        -certificate "${RELEASE_KEYS_DIR}/bootsignature.x509.pem" >/dev/null 2>&1; then
        echo "Legacy BootSignature verification failed: ${image}" >&2
        exit 1
    fi
done

# Publish only public certificate/key digests and mechanically established
# counts/posture.  Private paths, subjects, key bytes, and target-files are not
# release artifacts.  The explicit limitations prevent a release signature
# from being mistaken for verified boot, encryption, rollback protection, or
# an OTA validation claim.
release_keyset_path="${staged_release_dir}/${RELEASE_KEYSET_NAME}"
[[ ! -e "${release_keyset_path}" && ! -L "${release_keyset_path}" ]] || {
    echo "Refusing to overwrite Tier-3 release-keyset manifest." >&2
    exit 1
}
: >"${release_keyset_path}"
keyset_put() {
    local key="$1"
    local value="$2"
    [[ "${key}" =~ ^[a-z0-9_.]+$ && -n "${value}" && \
       "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] || {
        echo "Unsafe release-keyset manifest field: ${key}" >&2
        return 1
    }
    printf '%s=%s\n' "${key}" "${value}" >>"${release_keyset_path}"
}
keyset_put keyset.version 1
for key in releasekey platform shared media networkstack bootsignature; do
    keyset_put "certificate.${key}.sha256" \
        "${RELEASE_CERTIFICATE_SHA[${key}]}"
done
keyset_put apk.resigned_count "${#signed_apk_entries[@]}"
keyset_put apk.presigned_count "${#presigned_apk_entries[@]}"
keyset_put apex.archive_count "${#installed_apex_set[@]}"
keyset_put apex.flattened_present "${flattened_apex_found}"
if [[ "${#installed_apex_set[@]}" -gt 0 ]]; then
    sorted_apex_names=()
    while IFS= read -r apex_name; do
        [[ -n "${apex_name}" ]] && sorted_apex_names+=("${apex_name}")
    done < <(printf '%s\n' "${!installed_apex_set[@]}" | LC_ALL=C sort)
    [[ "${#sorted_apex_names[@]}" -eq "${#installed_apex_set[@]}" ]] || {
        echo "Could not derive a deterministic archive-APEX manifest order." >&2
        exit 1
    }
    for apex_index in "${!sorted_apex_names[@]}"; do
        apex_manifest_index=$((apex_index + 1))
        apex_name="${sorted_apex_names[${apex_index}]}"
        keyset_put "apex.payload.${apex_manifest_index}.name" "${apex_name}"
        keyset_put "apex.payload.${apex_manifest_index}.public_key_sha256" \
            "${APEX_PAYLOAD_PUBLIC_SHA[${apex_name}]}"
    done
fi
keyset_put boot_signature.verified_count 2
keyset_put ota_trust_certificate.sha256 "${release_certificate_sha}"
keyset_put posture.build_variant user
keyset_put posture.selinux enforcing
keyset_put posture.adb_default off
keyset_put posture.adb_when_enabled authenticated-nonroot
keyset_put posture.flash_locked 0
keyset_put posture.verified_boot_state orange
keyset_put posture.verified_boot absent
keyset_put posture.rollback_protection absent
keyset_put posture.encryption absent
keyset_put posture.ota_artifact not-produced
chmod 0644 "${release_keyset_path}"

emit_build_receipt "${staged_release_dir}" tier3-signed-target-files \
    target-files-package,sign-target-files,boot,recovery,system,vendor

if [[ -e "${release_dir}" ]]; then
    echo "Refusing to overwrite an existing Tier-3 release: ${release_dir}" >&2
    exit 1
fi

# Reuse the same four-image format/size/fixity and source-provenance contract
# as diagnostic builds. The explicit source override is accepted only for
# Tier 3, where these images came from the verified signed target-files above;
# stage-tier-images.sh refuses to mislabel mutable product output as Tier 3.
provenance_release_dir="${staging_dir}/release-with-provenance"
K50SV1_BUILD_TIER=3 \
K50SV1_STAGE_SOURCE_DIR="${staged_release_dir}" \
    "${STAGE_IMAGES_TOOL}" "${provenance_release_dir}"
mv -T "${provenance_release_dir}" "${release_dir}"

echo "Tier-3 signed partition images: ${release_dir}"
