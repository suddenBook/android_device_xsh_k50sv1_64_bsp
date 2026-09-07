#!/usr/bin/env bash
# Validate an external Tier-3 keyset and copy it into a private, caller-owned
# snapshot.  No later signing step is allowed to read the mutable source path.

set -euo pipefail

die() {
    printf 'Tier-3 keyset preparation failed: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || {
    printf 'Usage: K50SV1_RELEASE_KEYS_DIR=/absolute/private/path %s <empty-snapshot-directory>\n' "$0" >&2
    exit 2
}

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
SOURCE_INPUT="${K50SV1_RELEASE_KEYS_DIR:-}"
SNAPSHOT_INPUT="$1"
CURRENT_UID="$(id -u)"

[[ -n "${SOURCE_INPUT}" ]] \
    || die 'K50SV1_RELEASE_KEYS_DIR is required for Tier 3'
[[ "${SOURCE_INPUT}" == /* ]] \
    || die 'K50SV1_RELEASE_KEYS_DIR must be an absolute path'
[[ -d "${SOURCE_INPUT}" && ! -L "${SOURCE_INPUT}" ]] \
    || die 'K50SV1_RELEASE_KEYS_DIR must name an ordinary directory'
SOURCE_DIR="$(realpath -e -- "${SOURCE_INPUT}")" \
    || die 'cannot canonicalize K50SV1_RELEASE_KEYS_DIR'
[[ "${SOURCE_INPUT%/}" == "${SOURCE_DIR}" ]] \
    || die 'K50SV1_RELEASE_KEYS_DIR must be canonical and contain no symlink component'
[[ "${SOURCE_DIR}" != "${PROJECT_ROOT}" && \
   "${SOURCE_DIR}" != "${PROJECT_ROOT}/"* ]] \
    || die 'release keys must be outside PROJECT_ROOT'

# Inspect the actual repository and index, not inherited Git selectors.
source_git() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        git -C "${SOURCE_DIR}" "$@"
}

[[ "${SOURCE_DIR}/" != */.git/* ]] \
    || die 'release keys must not be inside Git metadata or a bare repository'
if source_git rev-parse --absolute-git-dir >/dev/null 2>&1; then
    [[ "$(source_git rev-parse --is-inside-git-dir)" == false && \
       "$(source_git rev-parse --is-bare-repository)" == false && \
       "$(source_git rev-parse --is-inside-work-tree)" == true ]] \
        || die 'release keys must not be inside Git metadata or a bare repository'
    # Ignoring just individual key files does not protect the entire directory.
    source_git check-ignore --no-index --quiet -- "${SOURCE_DIR}/" \
        || die 'release-key directory inside Git must be ignored as a whole'
    tracked_key_files="$(source_git ls-files --cached -- .)" \
        || die 'cannot inspect the release-key directory in the Git index'
    [[ -z "${tracked_key_files}" ]] \
        || die 'release-key directory contains tracked Git files'
fi

[[ "$(stat -c %u -- "${SOURCE_DIR}")" == "${CURRENT_UID}" ]] \
    || die 'release-key directory is not owned by the invoking uid'
[[ "$(stat -c %a -- "${SOURCE_DIR}")" == 700 ]] \
    || die 'release-key directory mode must be exactly 0700'

[[ "${SNAPSHOT_INPUT}" == /tmp/k50-tier3-keyset.* ]] \
    || die 'snapshot directory must be a private /tmp/k50-tier3-keyset.* path'
[[ -d "${SNAPSHOT_INPUT}" && ! -L "${SNAPSHOT_INPUT}" ]] \
    || die 'snapshot path must be an ordinary directory'
SNAPSHOT_DIR="$(realpath -e -- "${SNAPSHOT_INPUT}")" \
    || die 'cannot canonicalize snapshot directory'
[[ "${SNAPSHOT_INPUT%/}" == "${SNAPSHOT_DIR}" && \
   "$(stat -c %u -- "${SNAPSHOT_DIR}")" == "${CURRENT_UID}" && \
   "$(stat -c %a -- "${SNAPSHOT_DIR}")" == 700 ]] \
    || die 'snapshot directory must be canonical, caller-owned, and mode 0700'
[[ -z "$(find "${SNAPSHOT_DIR}" -mindepth 1 -print -quit)" ]] \
    || die 'snapshot directory must start empty'

for command in cmp cp find git id openssl realpath sha256sum stat; do
    command -v "${command}" >/dev/null 2>&1 \
        || die "missing host command: ${command}"
done

declare -A ALLOWED_RELATIVE_PATH=()
KEY_NAMES=(releasekey platform shared media networkstack bootsignature)
for key_name in "${KEY_NAMES[@]}"; do
    ALLOWED_RELATIVE_PATH["${key_name}.pk8"]=1
    ALLOWED_RELATIVE_PATH["${key_name}.x509.pem"]=1
done

source_file_is_safe() {
    local source_path="$1"
    local expected_mode="$2"
    local mode

    [[ -f "${source_path}" && ! -L "${source_path}" && \
       "$(stat -c %u -- "${source_path}")" == "${CURRENT_UID}" && \
       "$(stat -c %h -- "${source_path}")" == 1 ]] \
        || die "key input is not a caller-owned, single-link ordinary file: ${source_path}"
    mode="$(stat -c %a -- "${source_path}")"
    case "${expected_mode}:${mode}" in
        private:600 | map:600 | public:600 | public:644) ;;
        *) die "unsafe mode ${mode} on ${source_path}; expected ${expected_mode}" ;;
    esac
}

snapshot_file() {
    local relative_path="$1"
    local expected_mode="$2"
    local source_path="${SOURCE_DIR}/${relative_path}"
    local destination_path="${SNAPSHOT_DIR}/${relative_path}"
    local source_state_before source_state_after

    source_file_is_safe "${source_path}" "${expected_mode}"
    source_state_before="$(stat -c '%d:%i:%s:%Y:%f' -- "${source_path}")"
    mkdir -p -- "$(dirname "${destination_path}")"
    chmod 0700 -- "$(dirname "${destination_path}")"
    cp --reflink=never --no-preserve=mode,ownership,timestamps -- \
        "${source_path}" "${destination_path}"
    chmod 0600 -- "${destination_path}"
    source_state_after="$(stat -c '%d:%i:%s:%Y:%f' -- "${source_path}")"
    [[ "${source_state_before}" == "${source_state_after}" && \
       -f "${destination_path}" && ! -L "${destination_path}" && \
       "$(stat -c %u -- "${destination_path}")" == "${CURRENT_UID}" && \
       "$(stat -c %a -- "${destination_path}")" == 600 && \
       "$(stat -c %h -- "${destination_path}")" == 1 && \
       "$(stat -c %s -- "${destination_path}")" -gt 0 ]] \
        || die "key input changed or snapshot metadata is unsafe: ${relative_path}"
    cmp -s -- "${source_path}" "${destination_path}" \
        || die "key input changed while snapshotting: ${relative_path}"
}

for key_name in "${KEY_NAMES[@]}"; do
    snapshot_file "${key_name}.pk8" private
    snapshot_file "${key_name}.x509.pem" public
done

declare -A REVOKED_CERTIFICATE_SHA=(
    [f48bc02fbc79bfa64413e29e113f2deb7d8a31ecc1e00f1d8611cbc06c3e2140]=releasekey
    [8492187854b0514835ae97dac7259adf6282e5dcef38bb7264f920254aaf6ed3]=platform
    [ccce2337bc804f6cf9900b311f45bc4d7eb51b5a4cd0a7b93cb453c531394d03]=shared
    [33420d95547f3b5787f0af08f0aa11287acc91de4c0ce52594158b7d8fb9620b]=media
    [1a8e5a429c9b8376376fe0fc2608695de5e2b9d030f9536374fa1aab8e3a2515]=networkstack
    [1ce46e328af4f407ef128930eb937bbfa72e092eda6a0b002d6b4aabef40d996]=bootsignature
)
declare -A REVOKED_PUBLIC_KEY_SHA=(
    [9ecb37c53b1eaed239b6499889e923fa3ec8da805b912a90dd977139a33ae83e]=releasekey
    [ce971c311758671f6cb41251eb6d78f62a7e0a2ec4452d2dc25be2495a785ecc]=platform
    [c86950b88f7dfd08cef0d2f9d56d9242f5c7767435b0e6e506020d3211f5efa2]=shared
    [7436ba4e5a0564d4374e60fe8f62440f5d5e6022fcf4c613262e9a290ea1d6a0]=media
    [6d8e733d530e5fe925fe78fd722ab7fda91bd7dc798321976741601157ae0d01]=networkstack
    [8f458cc4ba2ff68ebfbbd998a2bd93b7afaae1238f6ae740d5882fff636383df]=bootsignature
)

# Payload identities must be independent of every global, revoked and source
# development identity. Build this deny set before accepting optional mappings.
declare -A FORBIDDEN_APEX_PUBLIC_SHA=()
for revoked_public_sha in "${!REVOKED_PUBLIC_KEY_SHA[@]}"; do
    FORBIDDEN_APEX_PUBLIC_SHA["${revoked_public_sha}"]="published/revoked ${REVOKED_PUBLIC_KEY_SHA[${revoked_public_sha}]}"
done
FORBIDDEN_APEX_PUBLIC_SHA[e6b000d8b0fb0ee5e9c8d03c791c57f0096e5cf3c923582fc43c149a84d47d92]='published/revoked global APEX key'

for key_name in "${KEY_NAMES[@]}"; do
    global_private_public_sha="$(
        openssl pkcs8 -inform DER -nocrypt \
            -in "${SNAPSHOT_DIR}/${key_name}.pk8" -outform PEM 2>/dev/null \
            | openssl pkey -pubout -outform DER 2>/dev/null \
            | sha256sum | awk '{print $1}'
    )" || die "cannot derive global private-key identity for APEX separation: ${key_name}"
    global_certificate_public_sha="$(
        openssl x509 -in "${SNAPSHOT_DIR}/${key_name}.x509.pem" \
            -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | sha256sum | awk '{print $1}'
    )" || die "cannot derive global certificate identity for APEX separation: ${key_name}"
    [[ "${global_private_public_sha}" =~ ^[0-9a-f]{64}$ && \
       "${global_certificate_public_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "malformed global public identity: ${key_name}"
    FORBIDDEN_APEX_PUBLIC_SHA["${global_private_public_sha}"]="global ${key_name} private key"
    FORBIDDEN_APEX_PUBLIC_SHA["${global_certificate_public_sha}"]="global ${key_name} certificate key"
done

for development_certificate in \
    "${LINEAGE_ROOT}"/build/make/target/product/security/*.x509.pem; do
    [[ -f "${development_certificate}" && ! -L "${development_certificate}" ]] \
        || continue
    development_public_sha="$(
        openssl x509 -in "${development_certificate}" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | sha256sum | awk '{print $1}'
    )" || die "cannot derive AOSP development public-key digest: ${development_certificate}"
    [[ "${development_public_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid AOSP development public-key digest: ${development_certificate}"
    FORBIDDEN_APEX_PUBLIC_SHA["${development_public_sha}"]="AOSP development certificate ${development_certificate}"
done

SOURCE_APEX_KEY_DIRS=(
    "${LINEAGE_ROOT}/art/build/apex"
    "${LINEAGE_ROOT}/external/conscrypt/apex"
    "${LINEAGE_ROOT}/frameworks/av/apex"
    "${LINEAGE_ROOT}/system/netd/apex"
    "${LINEAGE_ROOT}/system/timezone/apex"
)
while IFS= read -r -d '' source_apex_private_key; do
    if source_apex_public_sha="$(
        openssl pkey -in "${source_apex_private_key}" -pubout -outform DER 2>/dev/null \
            | sha256sum | awk '{print $1}'
    )" && [[ "${source_apex_public_sha}" =~ ^[0-9a-f]{64}$ ]]; then
        FORBIDDEN_APEX_PUBLIC_SHA["${source_apex_public_sha}"]="source-tree APEX key ${source_apex_private_key}"
    fi
done < <(find "${SOURCE_APEX_KEY_DIRS[@]}" -maxdepth 1 -type f -name '*.pem' -print0)

# Archive APEX is not expected today.  If it appears later, each installed
# archive must have its own payload key.  The optional TSV is deliberately
# strict: exactly "module.apex<TAB>apex/module.apex.pem", one record per line.
# Its presence is accepted here so the immutable snapshot can be made before
# the build; the release pipeline rejects it if the built archive count is 0,
# or if its exact module set differs from target-files.
APEX_MAP_RELATIVE=apex-map.tsv
declare -A APEX_PAYLOAD_RELATIVE=()
declare -A APEX_PAYLOAD_PUBLIC_SHA=()
if [[ -e "${SOURCE_DIR}/${APEX_MAP_RELATIVE}" || \
      -L "${SOURCE_DIR}/${APEX_MAP_RELATIVE}" ]]; then
    ALLOWED_RELATIVE_PATH["${APEX_MAP_RELATIVE}"]=1
    snapshot_file "${APEX_MAP_RELATIVE}" map
    while IFS=$'\t' read -r apex_name apex_relative extra || \
          [[ -n "${apex_name}${apex_relative}${extra}" ]]; do
        [[ -n "${apex_name}" && -n "${apex_relative}" && -z "${extra}" && \
           "${apex_name}" =~ ^[A-Za-z0-9._-]+\.apex$ && \
           "${apex_relative}" == "apex/${apex_name}.pem" ]] \
            || die "malformed archive-APEX mapping: ${apex_name}${apex_relative:+ -> ${apex_relative}}"
        [[ -z "${APEX_PAYLOAD_RELATIVE[${apex_name}]:-}" ]] \
            || die "duplicate archive-APEX mapping: ${apex_name}"
        APEX_PAYLOAD_RELATIVE["${apex_name}"]="${apex_relative}"
        ALLOWED_RELATIVE_PATH["${apex_relative}"]=1
        snapshot_file "${apex_relative}" private
        openssl rsa -check -noout \
            -in "${SNAPSHOT_DIR}/${apex_relative}" >/dev/null 2>&1 \
            || die "archive-APEX payload key is not valid RSA: ${apex_name}"
        apex_private_text="$(openssl pkey -in \
            "${SNAPSHOT_DIR}/${apex_relative}" -text -noout 2>/dev/null)" \
            || die "cannot inspect archive-APEX payload key: ${apex_name}"
        apex_private_bits="$(awk '
            /Private-Key: \([0-9]+ bit/ {
                value = $2
                gsub(/[^0-9]/, "", value)
                print value
                exit
            }
        ' <<<"${apex_private_text}")"
        [[ "${apex_private_bits}" == 4096 ]] \
            || die "archive-APEX RSA key must be exactly 4096 bits for this Android-Q product: ${apex_name}"
        apex_private_public_sha="$(
            openssl pkey -in "${SNAPSHOT_DIR}/${apex_relative}" \
                -pubout -outform DER 2>/dev/null \
                | sha256sum | awk '{ print $1 }'
        )" || die "cannot derive archive-APEX public-key digest: ${apex_name}"
        [[ "${apex_private_public_sha}" =~ ^[0-9a-f]{64}$ ]] \
            || die "invalid archive-APEX public-key digest: ${apex_name}"
        [[ -z "${FORBIDDEN_APEX_PUBLIC_SHA[${apex_private_public_sha}]:-}" ]] \
            || die "archive-APEX payload key reuses ${FORBIDDEN_APEX_PUBLIC_SHA[${apex_private_public_sha}]}: ${apex_name}"
        [[ -z "${APEX_PAYLOAD_PUBLIC_SHA[${apex_private_public_sha}]:-}" ]] \
            || die "archive-APEX payload key is reused by ${APEX_PAYLOAD_PUBLIC_SHA[${apex_private_public_sha}]} and ${apex_name}"
        APEX_PAYLOAD_PUBLIC_SHA["${apex_private_public_sha}"]="${apex_name}"
    done <"${SNAPSHOT_DIR}/${APEX_MAP_RELATIVE}"
    [[ "${#APEX_PAYLOAD_RELATIVE[@]}" -gt 0 ]] \
        || die 'apex-map.tsv must not be empty'
fi

# Reject stray material, including the revoked legacy names verity.* and the
# old global apex.pem.  A private directory is not a junk drawer: exact layout
# makes a future typo fail before it can select the wrong identity.
while IFS= read -r -d '' source_entry; do
    relative_entry="${source_entry#${SOURCE_DIR}/}"
    if [[ -d "${source_entry}" && ! -L "${source_entry}" ]]; then
        [[ "${relative_entry}" == apex && \
           "${#APEX_PAYLOAD_RELATIVE[@]}" -gt 0 && \
           "$(stat -c %u -- "${source_entry}")" == "${CURRENT_UID}" && \
           "$(stat -c %a -- "${source_entry}")" == 700 ]] \
            || die "unexpected or unsafe directory in release keyset: ${relative_entry}"
    elif [[ -z "${ALLOWED_RELATIVE_PATH[${relative_entry}]:-}" ]]; then
        die "unexpected file in release keyset: ${relative_entry}"
    fi
done < <(find "${SOURCE_DIR}" -mindepth 1 -print0)

declare -A CERTIFICATE_SHA=()
declare -A SEEN_CERTIFICATE_SHA=()
declare -A SEEN_PUBLIC_KEY_SHA=()
for key_name in "${KEY_NAMES[@]}"; do
    private_public_sha="$(
        openssl pkcs8 -inform DER -nocrypt \
            -in "${SNAPSHOT_DIR}/${key_name}.pk8" -outform PEM 2>/dev/null \
            | openssl pkey -pubout -outform DER 2>/dev/null \
            | sha256sum | awk '{ print $1 }'
    )" || die "cannot derive private-key public identity: ${key_name}"
    certificate_public_sha="$(
        openssl x509 -in "${SNAPSHOT_DIR}/${key_name}.x509.pem" \
            -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | sha256sum | awk '{ print $1 }'
    )" || die "cannot derive certificate public identity: ${key_name}"
    [[ "${private_public_sha}" =~ ^[0-9a-f]{64}$ && \
       "${private_public_sha}" == "${certificate_public_sha}" ]] \
        || die "private key/certificate mismatch: ${key_name}"
    [[ -z "${REVOKED_PUBLIC_KEY_SHA[${private_public_sha}]:-}" ]] \
        || die "${key_name} reuses the published/revoked ${REVOKED_PUBLIC_KEY_SHA[${private_public_sha}]} public key"
    [[ -z "${SEEN_PUBLIC_KEY_SHA[${private_public_sha}]:-}" ]] \
        || die "public key is reused by ${SEEN_PUBLIC_KEY_SHA[${private_public_sha}]} and ${key_name}"
    SEEN_PUBLIC_KEY_SHA["${private_public_sha}"]="${key_name}"
    openssl x509 -checkend 0 -noout \
        -in "${SNAPSHOT_DIR}/${key_name}.x509.pem" >/dev/null 2>&1 \
        || die "expired or invalid certificate: ${key_name}"
    certificate_text="$(openssl x509 -in \
        "${SNAPSHOT_DIR}/${key_name}.x509.pem" -noout -text 2>/dev/null)" \
        || die "cannot inspect certificate algorithm: ${key_name}"
    grep -Fq 'Public Key Algorithm: rsaEncryption' <<<"${certificate_text}" \
        || die "certificate is not an RSA identity: ${key_name}"
    certificate_bits="$(awk '
        /Public-Key: \([0-9]+ bit\)/ {
            value = $0
            gsub(/[^0-9]/, "", value)
            print value
            exit
        }
    ' <<<"${certificate_text}")"
    [[ "${certificate_bits}" =~ ^[0-9]+$ && \
       "${certificate_bits}" -ge 2048 ]] \
        || die "certificate RSA key is weaker than 2048 bits: ${key_name}"
    certificate_sha="$(
        openssl x509 -in "${SNAPSHOT_DIR}/${key_name}.x509.pem" \
            -outform DER 2>/dev/null | sha256sum | awk '{ print $1 }'
    )" || die "cannot derive certificate digest: ${key_name}"
    [[ "${certificate_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid certificate digest: ${key_name}"
    [[ -z "${REVOKED_CERTIFICATE_SHA[${certificate_sha}]:-}" ]] \
        || die "${key_name} reuses the published/revoked ${REVOKED_CERTIFICATE_SHA[${certificate_sha}]} certificate"
    [[ -z "${SEEN_CERTIFICATE_SHA[${certificate_sha}]:-}" ]] \
        || die "certificate is reused by ${SEEN_CERTIFICATE_SHA[${certificate_sha}]} and ${key_name}"
    SEEN_CERTIFICATE_SHA["${certificate_sha}"]="${key_name}"
    CERTIFICATE_SHA["${key_name}"]="${certificate_sha}"
done

for development_certificate in \
    "${LINEAGE_ROOT}"/build/make/target/product/security/*.x509.pem; do
    [[ -f "${development_certificate}" && ! -L "${development_certificate}" ]] \
        || continue
    development_sha="$(
        openssl x509 -in "${development_certificate}" -outform DER 2>/dev/null \
            | sha256sum | awk '{ print $1 }'
    )" || die "cannot derive AOSP development-certificate digest: ${development_certificate}"
    [[ "${development_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid AOSP development-certificate digest: ${development_certificate}"
    development_public_sha="$(
        openssl x509 -in "${development_certificate}" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | sha256sum | awk '{ print $1 }'
    )" || die "cannot derive AOSP development public-key digest: ${development_certificate}"
    [[ "${development_public_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid AOSP development public-key digest: ${development_certificate}"
    colliding_release_key="${SEEN_CERTIFICATE_SHA[${development_sha}]:-${SEEN_PUBLIC_KEY_SHA[${development_public_sha}]:-}}"
    [[ -z "${colliding_release_key}" ]] \
        || die "${colliding_release_key} reuses an AOSP development certificate/public key"
done

INPUT_MANIFEST="${SNAPSHOT_DIR}/KEYSET-INPUT"
: >"${INPUT_MANIFEST}"
printf 'keyset_input.version=1\n' >>"${INPUT_MANIFEST}"
for key_name in "${KEY_NAMES[@]}"; do
    printf 'certificate.%s.sha256=%s\n' \
        "${key_name}" "${CERTIFICATE_SHA[${key_name}]}" >>"${INPUT_MANIFEST}"
done
printf 'apex.mapping_count=%s\n' \
    "${#APEX_PAYLOAD_RELATIVE[@]}" >>"${INPUT_MANIFEST}"
chmod 0600 -- "${INPUT_MANIFEST}"

printf 'Tier-3 external keyset validated and privately snapshotted.\n'
