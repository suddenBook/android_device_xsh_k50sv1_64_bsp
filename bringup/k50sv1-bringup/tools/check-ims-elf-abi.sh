#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
BUILD_TOP="${PROJECT_ROOT}/lineage-17.1"
DEFAULT_PRODUCT_OUT="${BUILD_TOP}/out/target/product/k50sv1_64_bsp"

if [[ "$#" -gt 1 ]]; then
    echo "Usage: $0 [PRODUCT_OUT]" >&2
    exit 2
fi

PRODUCT_OUT="${1:-${DEFAULT_PRODUCT_OUT}}"

PYTHON2="${BUILD_TOP}/prebuilts/python/linux-x86/2.7.5/bin/python"
CHECK_ELF="${BUILD_TOP}/build/make/tools/check_elf_file.py"
# Keep this in lockstep with build/soong/cc/config/global.go in LineageOS 17.1.
LLVM_READOBJ="${BUILD_TOP}/prebuilts/clang/host/linux-x86/clang-r353983c1/bin/llvm-readobj"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file() {
    local path="$1"

    [[ -f "${path}" ]] || die "required file is missing: ${path}"
}

require_executable() {
    local path="$1"

    [[ -x "${path}" ]] || die "required executable is missing: ${path}"
}

require_executable "${PYTHON2}"
require_file "${CHECK_ELF}"
require_executable "${LLVM_READOBJ}"

[[ -d "${PRODUCT_OUT}" ]] || die "PRODUCT_OUT does not exist: ${PRODUCT_OUT}"
PRODUCT_OUT="$(cd "${PRODUCT_OUT}" && pwd -P)"
[[ -d "${PRODUCT_OUT}/vendor" ]] || die "vendor output is missing: ${PRODUCT_OUT}/vendor"
[[ -d "${PRODUCT_OUT}/system" ]] || die "system output is missing: ${PRODUCT_OUT}/system"

# This is the deliberately selected core voice-MMTEL native closure. The
# 64-bit IMSA service and interface bridge to the legacy 32-bit MAL/VoLTE
# processes. WFC/ePDG has its own closure gate; video telephony, UT and RCS are
# not roots here.
#
# Record format: ELF bits | kind | path below PRODUCT_OUT
ims_roots=(
    "64|bin|vendor/bin/hw/vendor.mediatek.hardware.imsa@1.0-service"
    "32|bin|vendor/bin/mtkmal"
    "32|bin|vendor/bin/volte_imcb"
    "32|bin|vendor/bin/volte_stack"
    "32|bin|vendor/bin/volte_ua"
    "32|lib|vendor/lib/libipsec_ims_shr.so"
    "32|lib|vendor/lib/libmal.so"
    "32|lib|vendor/lib/libmal_datamngr.so"
    "32|lib|vendor/lib/libmal_imsmngr.so"
    "32|lib|vendor/lib/libmal_mdmngr.so"
    "32|lib|vendor/lib/libmal_nwmngr.so"
    "32|lib|vendor/lib/libmal_rds.so"
    "32|lib|vendor/lib/libmal_rilproxy.so"
    "32|lib|vendor/lib/libmal_simmngr.so"
    "32|lib|vendor/lib/libmdfx.so"
    "32|lib|vendor/lib/libverno.so"
    "32|lib|vendor/lib/libvolte_core_shr.so"
    "32|lib|vendor/lib/libvolte_xdmc_shr.so"
    "32|lib|vendor/lib/volte_imsm.so"
    "64|lib|vendor/lib64/vendor.mediatek.hardware.imsa@1.0.so"
)

llvm_metadata() {
    local path="$1"

    "${LLVM_READOBJ}" -file-headers -dynamic-table "${path}"
}

elf_bits() {
    local path="$1"
    local metadata
    local value
    local -a values=()

    metadata="$(llvm_metadata "${path}")" \
        || die "llvm-readobj could not parse ELF metadata: ${path}"
    while IFS= read -r value; do
        [[ -n "${value}" ]] && values+=("${value}")
    done < <(sed -n 's/^[[:space:]]*AddressSize: \([0-9][0-9]*\)bit$/\1/p' <<<"${metadata}")

    [[ "${#values[@]}" -eq 1 ]] \
        || die "ELF class is missing or ambiguous in ${path}"
    case "${values[0]}" in
        32|64)
            printf '%s\n' "${values[0]}"
            ;;
        *)
            die "unsupported ELF class ${values[0]} in ${path}"
            ;;
    esac
}

elf_sonames() {
    local path="$1"
    local metadata

    metadata="$(llvm_metadata "${path}")" \
        || die "llvm-readobj could not parse dynamic metadata: ${path}"
    sed -n 's/^[[:space:]]*0x[0-9A-Fa-f][0-9A-Fa-f]*[[:space:]]\+SONAME[[:space:]]\+Library soname: \[\(.*\)\]$/\1/p' \
        <<<"${metadata}"
}

elf_needed() {
    local path="$1"
    local metadata

    metadata="$(llvm_metadata "${path}")" \
        || die "llvm-readobj could not parse dynamic metadata: ${path}"
    sed -n 's/^[[:space:]]*0x[0-9A-Fa-f][0-9A-Fa-f]*[[:space:]]\+NEEDED[[:space:]]\+Shared library: \[\(.*\)\]$/\1/p' \
        <<<"${metadata}"
}

check_elf_class() {
    local path="$1"
    local expected_bits="$2"
    local actual_bits

    actual_bits="$(elf_bits "${path}")"
    [[ "${actual_bits}" == "${expected_bits}" ]] \
        || die "wrong ELF class for ${path}: expected ELF${expected_bits}, got ELF${actual_bits}"
}

check_shared_object_identity() {
    local path="$1"
    local expected_bits="$2"
    local expected_soname="$3"
    local soname
    local soname_text
    local -a sonames=()

    [[ -f "${path}" ]] || die "shared library is missing or has a broken link: ${path}"
    check_elf_class "${path}" "${expected_bits}"

    soname_text="$(elf_sonames "${path}")"
    while IFS= read -r soname; do
        [[ -n "${soname}" ]] && sonames+=("${soname}")
    done <<<"${soname_text}"

    [[ "${#sonames[@]}" -eq 1 ]] \
        || die "expected exactly one DT_SONAME in ${path}, found ${#sonames[@]}"
    [[ "${sonames[0]}" == "${expected_soname}" ]] \
        || die "DT_SONAME mismatch in ${path}: expected ${expected_soname}, got ${sonames[0]}"
}

resolve_runtime_apex_link() {
    local staging_path="$1"
    local bits="$2"
    local soname="$3"
    local libdir
    local target
    local expected_target
    local symbols_path
    local canonical_symbols
    local canonical_apex_root

    if [[ "${bits}" == 32 ]]; then
        libdir=lib
    else
        libdir=lib64
    fi

    target="$(readlink -- "${staging_path}")" \
        || die "could not read system staging link: ${staging_path}"
    expected_target="/apex/com.android.runtime/${libdir}/bionic/${soname}"
    [[ "${target}" == "${expected_target}" ]] \
        || die "unexpected absolute system library link ${staging_path} -> ${target}"

    symbols_path="${PRODUCT_OUT}/symbols${target}"
    [[ -f "${symbols_path}" ]] \
        || die "runtime APEX symbols target is missing: ${symbols_path}"

    canonical_symbols="$(readlink -f -- "${symbols_path}")" \
        || die "could not canonicalize runtime APEX symbols target: ${symbols_path}"
    canonical_apex_root="$(readlink -f -- "${PRODUCT_OUT}/symbols/apex/com.android.runtime")" \
        || die "runtime APEX symbols root is missing"
    case "${canonical_symbols}" in
        "${canonical_apex_root}"/*)
            ;;
        *)
            die "runtime APEX symbols target escapes its root: ${canonical_symbols}"
            ;;
    esac

    printf '%s\n' "${canonical_symbols}"
}

validate_candidate() {
    local path="$1"
    local bits="$2"
    local soname="$3"
    local resolved_path="${path}"

    if [[ -L "${path}" ]]; then
        if [[ "$(readlink -- "${path}")" == /* ]]; then
            resolved_path="$(resolve_runtime_apex_link "${path}" "${bits}" "${soname}")"
        else
            resolved_path="$(readlink -f -- "${path}")" \
                || die "shared-library link is broken: ${path}"
            case "${resolved_path}" in
                "${PRODUCT_OUT}"/*)
                    ;;
                *)
                    die "shared-library link escapes PRODUCT_OUT: ${path} -> ${resolved_path}"
                    ;;
            esac
        fi
    fi

    check_shared_object_identity "${resolved_path}" "${bits}" "${soname}"
    printf '%s\n' "${resolved_path}"
}

resolve_dependency() {
    local bits="$1"
    local soname="$2"
    local libdir
    local path
    local resolved
    local -a vndk_candidates=()

    [[ -n "${soname}" && "${soname}" != */* ]] \
        || die "invalid DT_NEEDED name: ${soname}"

    if [[ "${bits}" == 32 ]]; then
        libdir=lib
    else
        libdir=lib64
    fi

    # The vendor namespace searches its own directory first.  A present but
    # malformed candidate is fatal; it must not silently fall through to a
    # different partition's implementation.
    path="${PRODUCT_OUT}/vendor/${libdir}/${soname}"
    if [[ -e "${path}" || -L "${path}" ]]; then
        validate_candidate "${path}" "${bits}" "${soname}"
        return
    fi

    # VNDK-core and VNDK-SP are distinct namespace exports at the same ABI
    # level.  The same SONAME appearing in both is an ambiguous build output.
    for path in \
        "${PRODUCT_OUT}/system/${libdir}/vndk-29/${soname}" \
        "${PRODUCT_OUT}/system/${libdir}/vndk-sp-29/${soname}"; do
        if [[ -e "${path}" || -L "${path}" ]]; then
            resolved="$(validate_candidate "${path}" "${bits}" "${soname}")"
            vndk_candidates+=("${resolved}")
        fi
    done
    if [[ "${#vndk_candidates[@]}" -gt 1 ]]; then
        die "ambiguous ELF${bits} VNDK dependency ${soname}: ${vndk_candidates[*]}"
    fi
    if [[ "${#vndk_candidates[@]}" -eq 1 ]]; then
        printf '%s\n' "${vndk_candidates[0]}"
        return
    fi

    path="${PRODUCT_OUT}/system/${libdir}/${soname}"
    if [[ -e "${path}" || -L "${path}" ]]; then
        validate_candidate "${path}" "${bits}" "${soname}"
        return
    fi

    die "missing ELF${bits} dependency ${soname}; searched vendor/${libdir}, system/${libdir}/vndk-{29,sp-29}, and system/${libdir}"
}

checked=0
checked_bins=0
checked_lib32=0
checked_lib64=0

for record in "${ims_roots[@]}"; do
    IFS='|' read -r expected_bits kind relative_path <<<"${record}"
    root="${PRODUCT_OUT}/${relative_path}"

    [[ -f "${root}" && ! -L "${root}" ]] \
        || die "IMS ELF root is missing, not regular, or unexpectedly a link: ${relative_path}"
    check_elf_class "${root}" "${expected_bits}"

    root_name="$(basename "${relative_path}")"
    if [[ "${kind}" == lib ]]; then
        check_shared_object_identity "${root}" "${expected_bits}" "${root_name}"
        if [[ "${expected_bits}" == 32 ]]; then
            ((checked_lib32 += 1))
        else
            ((checked_lib64 += 1))
        fi
    elif [[ "${kind}" == bin ]]; then
        root_soname_text="$(elf_sonames "${root}")"
        root_sonames=()
        while IFS= read -r soname; do
            [[ -n "${soname}" ]] && root_sonames+=("${soname}")
        done <<<"${root_soname_text}"
        [[ "${#root_sonames[@]}" -eq 0 ]] \
            || die "IMS executable unexpectedly has DT_SONAME ${root_sonames[*]}: ${relative_path}"
        ((checked_bins += 1))
    else
        die "invalid IMS root kind ${kind}: ${relative_path}"
    fi

    needed_text="$(elf_needed "${root}")"
    needed=()
    declare -A seen_needed=()
    while IFS= read -r soname; do
        [[ -n "${soname}" ]] || continue
        [[ -z "${seen_needed[${soname}]+present}" ]] \
            || die "duplicate DT_NEEDED ${soname} in ${relative_path}"
        seen_needed["${soname}"]=1
        needed+=("${soname}")
    done <<<"${needed_text}"
    unset seen_needed

    checker_args=(
        "${CHECK_ELF}"
        --llvm-readobj "${LLVM_READOBJ}"
        --soname "${root_name}"
    )
    for soname in "${needed[@]}"; do
        dependency="$(resolve_dependency "${expected_bits}" "${soname}")"
        checker_args+=(--shared-lib "${dependency}")
    done
    checker_args+=("${root}")

    # Deliberately do not pass --allow-undefined-symbols: every imported symbol
    # must resolve from the root itself or its exact direct DT_NEEDED closure.
    "${PYTHON2}" "${checker_args[@]}"

    ((checked += 1))
    printf 'PASS [%02d/%02d] ELF%s %s (%d direct dependencies)\n' \
        "${checked}" "${#ims_roots[@]}" "${expected_bits}" \
        "${relative_path}" "${#needed[@]}"
done

# The four counter assertions that stood here counted the literal ims_roots
# array declared 270 lines above, re-counted after a loop with no `continue`:
# every iteration increments, so they could only restate the array's own
# length. The counts are still printed, as a description of what ran.
printf 'PASS: verified %d core voice-MMTEL ELF roots: %d executables, %d ELF32 libraries, %d ELF64 library.\n' \
    "${checked}" "${checked_bins}" "${checked_lib32}" "${checked_lib64}"
