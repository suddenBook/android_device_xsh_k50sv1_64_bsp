#!/usr/bin/env bash
# Emit a deterministic, content-bound description of every source checkout used
# by the k50sv1 build. The output intentionally has no timestamp: callers take
# it before and after a build/stage operation and require a byte-for-byte match.

set -euo pipefail

die() {
    printf 'Build-input capture failed: %s\n' "$*" >&2
    exit 1
}

REPO_MANIFEST_OUTPUT=""
if [[ "$#" -eq 2 && "$1" == --repo-manifest ]]; then
    REPO_MANIFEST_OUTPUT="$2"
elif [[ "$#" -ne 0 ]]; then
    printf 'Usage: %s [--repo-manifest OUTPUT.xml]\n' "$0" >&2
    exit 2
fi

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
REPO_TOOL="${LINEAGE_ROOT}/.repo/repo/repo"

for command in awk cp git mktemp python realpath sha256sum sort; do
    command -v "${command}" >/dev/null 2>&1 \
        || die "missing host command: ${command}"
done
[[ -x "${REPO_TOOL}" ]] || die "missing repo launcher: ${REPO_TOOL}"

if [[ -n "${REPO_MANIFEST_OUTPUT}" ]]; then
    repo_manifest_parent="$(dirname "${REPO_MANIFEST_OUTPUT}")"
    [[ ! -e "${REPO_MANIFEST_OUTPUT}" && ! -L "${REPO_MANIFEST_OUTPUT}" ]] \
        || die "repo-manifest output already exists: ${REPO_MANIFEST_OUTPUT}"
    [[ -d "${repo_manifest_parent}" && ! -L "${repo_manifest_parent}" ]] \
        || die "repo-manifest output parent must be an ordinary directory"
    repo_manifest_parent="$(realpath -e "${repo_manifest_parent}")"
    REPO_MANIFEST_OUTPUT="${repo_manifest_parent}/$(basename "${REPO_MANIFEST_OUTPUT}")"
fi

CAPTURE_TMP="$(mktemp -d)"
cleanup() {
    if [[ -d "${CAPTURE_TMP:-}" ]]; then
        find "${CAPTURE_TMP}" -mindepth 1 -depth -delete 2>/dev/null || true
        rmdir "${CAPTURE_TMP}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

file_sha256() {
    local file="$1"
    local digest

    [[ -f "${file}" && ! -L "${file}" && -r "${file}" ]] \
        || die "cannot hash missing, unreadable, or symlinked file: ${file}"
    digest="$(sha256sum -- "${file}" | awk '{ print $1 }')" \
        || die "cannot hash file: ${file}"
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid SHA-256 result for ${file}"
    printf '%s' "${digest}"
}

manifest_put() {
    local key="$1"
    local value="$2"

    [[ "${key}" =~ ^[a-z0-9_.]+$ && -n "${value}" && \
       "${value}" != *$'\n'* && "${value}" =~ ^[[:print:]]+$ ]] \
        || die "unsafe source-state field: ${key}"
    printf '%s=%s\n' "${key}" "${value}"
}

OWNED_REPO_LABELS=(
    work
    device
    vendor
    kernel
    gapps
    google_webview
    huawei_hms
)
OWNED_REPO_RELATIVE=(
    work
    lineage-17.1/device/xsh/k50sv1_64_bsp
    lineage-17.1/vendor/xsh/k50sv1_64_bsp
    lineage-17.1/kernel/xsh/k50sv1_64_bsp
    lineage-17.1/vendor/gapps
    lineage-17.1/vendor/google_webview
    lineage-17.1/vendor/huawei/hms
)
OWNED_REPO_PATHS=(
    "${PROJECT_ROOT}/work"
    "${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp"
    "${LINEAGE_ROOT}/vendor/xsh/k50sv1_64_bsp"
    "${LINEAGE_ROOT}/kernel/xsh/k50sv1_64_bsp"
    "${LINEAGE_ROOT}/vendor/gapps"
    "${LINEAGE_ROOT}/vendor/google_webview"
    "${LINEAGE_ROOT}/vendor/huawei/hms"
)
declare -a OWNED_REPO_HEADS=()
declare -a OWNED_REPO_TREES=()
[[ "${#OWNED_REPO_LABELS[@]}" -eq 7 && \
   "${#OWNED_REPO_RELATIVE[@]}" -eq "${#OWNED_REPO_LABELS[@]}" && \
   "${#OWNED_REPO_PATHS[@]}" -eq "${#OWNED_REPO_LABELS[@]}" ]] \
    || die "owned repository definition is internally inconsistent"

for repo_index in "${!OWNED_REPO_PATHS[@]}"; do
    repo_path="${OWNED_REPO_PATHS[${repo_index}]}"
    repo_relative="${OWNED_REPO_RELATIVE[${repo_index}]}"
    if ! repo_top="$(git -C "${repo_path}" rev-parse --show-toplevel 2>/dev/null)" || \
       [[ "$(realpath -e "${repo_top}")" != "$(realpath -e "${repo_path}")" ]]; then
        die "owned repository is missing or resolves to another worktree: ${repo_relative}"
    fi
    repo_status="${CAPTURE_TMP}/owned-${repo_index}.status"
    git -C "${repo_path}" status --porcelain=v1 -z --untracked-files=all \
        >"${repo_status}" \
        || die "cannot read owned repository status: ${repo_relative}"
    if [[ -s "${repo_status}" ]]; then
        printf 'Owned repository must be clean: %s\n' "${repo_relative}" >&2
        git -C "${repo_path}" status --short --untracked-files=all >&2 || true
        exit 1
    fi
    repo_head="$(git -C "${repo_path}" rev-parse --verify 'HEAD^{commit}')" \
        || die "cannot resolve owned repository HEAD: ${repo_relative}"
    repo_tree="$(git -C "${repo_path}" rev-parse --verify 'HEAD^{tree}')" \
        || die "cannot resolve owned repository tree: ${repo_relative}"
    [[ "${repo_head}" =~ ^[0-9a-f]{40,64}$ && \
       "${repo_tree}" =~ ^[0-9a-f]{40,64}$ ]] \
        || die "owned repository returned an invalid object ID: ${repo_relative}"
    OWNED_REPO_HEADS[${repo_index}]="${repo_head}"
    OWNED_REPO_TREES[${repo_index}]="${repo_tree}"
done

# Bind all 786-ish repo-managed Android projects, not only the local device
# repositories. Every managed project except vendor/lineage must be clean, and
# `repo manifest -r` pins the exact checked-out commit of each project.
ANDROID_MANIFEST="${CAPTURE_TMP}/android-manifest.xml"
(
    cd "${LINEAGE_ROOT}"
    "${REPO_TOOL}" manifest -r -o "${ANDROID_MANIFEST}"
) >/dev/null || die "cannot emit a revision-pinned Android repo manifest"
[[ -s "${ANDROID_MANIFEST}" && ! -L "${ANDROID_MANIFEST}" ]] \
    || die "revision-pinned Android repo manifest is empty"
ANDROID_PROJECT_COUNT="$(awk '/<project[[:space:]]/{ count++ } END { print count + 0 }' \
    "${ANDROID_MANIFEST}")"
(( ANDROID_PROJECT_COUNT > 0 )) || die "Android repo manifest has no projects"
if [[ -n "${REPO_MANIFEST_OUTPUT}" ]]; then
    cp -- "${ANDROID_MANIFEST}" "${REPO_MANIFEST_OUTPUT}" \
        || die "cannot copy revision-pinned manifest to ${REPO_MANIFEST_OUTPUT}"
    chmod 0644 "${REPO_MANIFEST_OUTPUT}"
    cmp -s "${ANDROID_MANIFEST}" "${REPO_MANIFEST_OUTPUT}" \
        || die "copied revision-pinned Android repo manifest changed"
fi

MANAGED_DIRTY="${CAPTURE_TMP}/managed-dirty.txt"
(
    cd "${LINEAGE_ROOT}"
    "${REPO_TOOL}" forall -e -j32 -c '
        if [ "${REPO_PATH}" = vendor/lineage ]; then
            exit 0
        fi
        status="$(git status --porcelain=v1 --untracked-files=all)" || {
            printf "unreadable:%s\n" "${REPO_PATH}" >&2
            exit 7
        }
        if [ -n "${status}" ]; then
            printf "%s\n" "${REPO_PATH}"
        fi
    '
) | sort -u >"${MANAGED_DIRTY}" \
    || die "cannot inspect Android repo-managed worktrees"
if [[ -s "${MANAGED_DIRTY}" ]]; then
    printf 'Android repo-managed projects must be clean (except vendor/lineage):\n' >&2
    sed 's/^/  /' "${MANAGED_DIRTY}" >&2
    exit 1
fi

# vendor/lineage is the one deliberate managed-repository exception. Only the
# font customization may be dirty. The APN base stays at clean HEAD while the
# device fragment and Lineage merge tool are content-bound separately.
VENDOR_LINEAGE="${LINEAGE_ROOT}/vendor/lineage"
VENDOR_LINEAGE_STATUS="${CAPTURE_TMP}/vendor-lineage.status"
VENDOR_LINEAGE_HEAD="$(git -C "${VENDOR_LINEAGE}" \
    rev-parse --verify 'HEAD^{commit}')" \
    || die "cannot resolve vendor/lineage base revision"
[[ "${VENDOR_LINEAGE_HEAD}" =~ ^[0-9a-f]{40,64}$ ]] \
    || die "vendor/lineage returned an invalid commit ID"
git -C "${VENDOR_LINEAGE}" status --porcelain=v1 -z --untracked-files=all \
    >"${VENDOR_LINEAGE_STATUS}" \
    || die "cannot read vendor/lineage status"
font_status_seen=0
apn_status_seen=0
while IFS= read -r -d '' status_record; do
    [[ "${#status_record}" -ge 4 && "${status_record:2:1}" == ' ' && \
       "${status_record:0:2}" == *M* ]] \
        || die "vendor/lineage contains a non-approved status record"
    case "${status_record:3}" in
        prebuilt/common/etc/fonts_customization.xml)
            font_status_seen=$((font_status_seen + 1))
            ;;
        prebuilt/common/etc/apns-conf.xml)
            apn_status_seen=$((apn_status_seen + 1))
            ;;
        *) die "vendor/lineage contains an unapproved changed path: ${status_record:3}" ;;
    esac
done <"${VENDOR_LINEAGE_STATUS}"
[[ "${font_status_seen}" -eq 1 && "${apn_status_seen}" -eq 1 ]] \
    || die "vendor/lineage must be dirty at exactly fonts_customization.xml and apns-conf.xml"

FONT_DIFF="${CAPTURE_TMP}/vendor-lineage-font.diff"
git -C "${VENDOR_LINEAGE}" diff --no-ext-diff --binary --full-index HEAD -- \
    prebuilt/common/etc/fonts_customization.xml >"${FONT_DIFF}" \
    || die "cannot derive approved font diff"
[[ -s "${FONT_DIFF}" ]] \
    || die "the approved vendor/lineage font diff is unexpectedly empty"

APN_DEFAULT_RELATIVE="lineage-17.1/vendor/lineage/prebuilt/common/etc/apns-conf.xml"
APN_OVERRIDE_RELATIVE="lineage-17.1/device/xsh/k50sv1_64_bsp/configs/apns-conf.xml"
APN_MERGE_TOOL_RELATIVE="lineage-17.1/vendor/lineage/tools/custom_apns.py"
APN_DEFAULT="${PROJECT_ROOT}/${APN_DEFAULT_RELATIVE}"
APN_OVERRIDE="${PROJECT_ROOT}/${APN_OVERRIDE_RELATIVE}"
APN_MERGE_TOOL="${PROJECT_ROOT}/${APN_MERGE_TOOL_RELATIVE}"
APN_VALIDATOR="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp/tools/validate-custom-apns.py"
APN_INTERNAL="${LINEAGE_ROOT}/frameworks/base/core/res/res/xml/apns.xml"
APN_PYTHON2="${LINEAGE_ROOT}/prebuilts/python/linux-x86/2.7.5/bin/python2.7"
for apn_input in "${APN_DEFAULT}" "${APN_OVERRIDE}" "${APN_MERGE_TOOL}" \
                 "${APN_VALIDATOR}" "${APN_INTERNAL}"; do
    [[ -f "${apn_input}" && ! -L "${apn_input}" && -r "${apn_input}" ]] \
        || die "missing, unreadable, or symlinked APN input: ${apn_input}"
done
[[ -x "${APN_PYTHON2}" && ! -L "${APN_PYTHON2}" ]] \
    || die "missing or symlinked Android Python 2 merge runtime: ${APN_PYTHON2}"
# NOT clean HEAD any more: seven China Mobile / China Unicom WAP rows carry an
# added type= attribute, without which they claim the ims type and the IMS PDN
# is dialled on a WAP APN (E-181). Bind the exact approved outcome, the same way
# the font patch is bound above, so "dirty" can never mean "unreviewed". The
# resulting content is bound a second time by apns.default_sha256 below, which
# is what the stage contract compares.
APN_APPROVED_PATCH="${TOOL_DIR}/../upstream/apns-conf.xml.patch"
[[ -f "${APN_APPROVED_PATCH}" && ! -L "${APN_APPROVED_PATCH}" ]] \
    || die "missing approved APN patch: ${APN_APPROVED_PATCH}"
APN_DIFF="${CAPTURE_TMP}/vendor-lineage-apns.diff"
git -c core.abbrev=8 -C "${VENDOR_LINEAGE}" diff --no-ext-diff --binary HEAD -- \
    prebuilt/common/etc/apns-conf.xml >"${APN_DIFF}" \
    || die "cannot derive the approved APN diff"
cmp -s "${APN_APPROVED_PATCH}" "${APN_DIFF}" \
    || die "Lineage's apns-conf.xml does not match the approved patch outcome"
APN_VALIDATION="$(python "${APN_VALIDATOR}" "${APN_DEFAULT}" \
    "${APN_OVERRIDE}" "${APN_INTERNAL}")" \
    || die "the device APN fragment or merged identities failed validation"
validation_get_exact() {
    local key="$1"
    awk -F= -v key="${key}" '
        $1 == key { count++; value = substr($0, length(key) + 2) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' <<<"${APN_VALIDATION}"
}
[[ "$(validation_get_exact status)" == PASS && \
   "$(validation_get_exact custom_rows)" == 10 && \
   "$(validation_get_exact network_type_bitmask)" == 512903 ]] \
    || die "APN validator returned an incomplete semantic result"
APN_MERGED_SHA256="$(validation_get_exact merged_sha256)" \
    || die "APN validator returned no merged digest"
[[ "${APN_MERGED_SHA256}" =~ ^[0-9a-f]{64}$ ]] \
    || die "APN validator returned an invalid merged digest"
APN_ACTUAL_MERGE="${CAPTURE_TMP}/actual-merged-apns-conf.xml"
(
    cd "${LINEAGE_ROOT}"
    "${APN_PYTHON2}" vendor/lineage/tools/custom_apns.py \
        "${APN_ACTUAL_MERGE}" "${APN_OVERRIDE}"
) || die "Lineage's actual custom_apns.py merge failed"
[[ -f "${APN_ACTUAL_MERGE}" && ! -L "${APN_ACTUAL_MERGE}" && \
   -s "${APN_ACTUAL_MERGE}" ]] \
    || die "Lineage's actual APN merge produced no ordinary output"
[[ "$(file_sha256 "${APN_ACTUAL_MERGE}")" == "${APN_MERGED_SHA256}" ]] \
    || die "Lineage's actual APN merge differs from the validated merge"

manifest_put source_state.version 4
manifest_put android_repo.project_count "${ANDROID_PROJECT_COUNT}"
manifest_put android_repo.revision_manifest_sha256 "$(file_sha256 "${ANDROID_MANIFEST}")"
for repo_index in "${!OWNED_REPO_PATHS[@]}"; do
    repo_label="${OWNED_REPO_LABELS[${repo_index}]}"
    manifest_put "repo.${repo_label}.path" "${OWNED_REPO_RELATIVE[${repo_index}]}"
    manifest_put "repo.${repo_label}.head" "${OWNED_REPO_HEADS[${repo_index}]}"
    manifest_put "repo.${repo_label}.tree" "${OWNED_REPO_TREES[${repo_index}]}"
    manifest_put "repo.${repo_label}.dirty" false
done
manifest_put vendor_lineage.path lineage-17.1/vendor/lineage
manifest_put vendor_lineage.base_head "${VENDOR_LINEAGE_HEAD}"
manifest_put vendor_lineage.status_sha256 "$(file_sha256 "${VENDOR_LINEAGE_STATUS}")"
manifest_put vendor_lineage.font_diff_sha256 "$(file_sha256 "${FONT_DIFF}")"
manifest_put vendor_lineage.font_result_sha256 \
    "$(file_sha256 "${VENDOR_LINEAGE}/prebuilt/common/etc/fonts_customization.xml")"
manifest_put apns.default_path "${APN_DEFAULT_RELATIVE}"
manifest_put apns.default_sha256 "$(file_sha256 "${APN_DEFAULT}")"
manifest_put apns.override_path "${APN_OVERRIDE_RELATIVE}"
manifest_put apns.override_sha256 "$(file_sha256 "${APN_OVERRIDE}")"
manifest_put apns.merge_tool_path "${APN_MERGE_TOOL_RELATIVE}"
manifest_put apns.merge_tool_sha256 "$(file_sha256 "${APN_MERGE_TOOL}")"
manifest_put apns.merged_sha256 "${APN_MERGED_SHA256}"
