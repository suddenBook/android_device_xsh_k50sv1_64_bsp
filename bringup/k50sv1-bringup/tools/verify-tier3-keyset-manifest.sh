#!/usr/bin/env bash
# Validate the public, non-secret key/posture manifest emitted by Tier 3.

set -euo pipefail

die() {
    printf 'Tier-3 release-keyset manifest verification failed: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -eq 1 ]] || {
    printf 'Usage: %s <K50SV1-RELEASE-KEYSET>\n' "$0" >&2
    exit 2
}
MANIFEST="$1"
[[ -f "${MANIFEST}" && ! -L "${MANIFEST}" && -s "${MANIFEST}" ]] \
    || die 'manifest must be an ordinary non-empty file'

manifest_get_exact() {
    local key="$1"
    awk -v key="${key}" '
        index($0, key "=") == 1 {
            count++
            value = substr($0, length(key) + 2)
        }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "${MANIFEST}" || die "manifest has no unique non-empty ${key}"
}

[[ "$(manifest_get_exact keyset.version)" == 1 ]] \
    || die 'unsupported keyset.version'

KEY_NAMES=(releasekey platform shared media networkstack bootsignature)
declare -A SEEN_CERTIFICATE=()
for key_name in "${KEY_NAMES[@]}"; do
    certificate_sha="$(manifest_get_exact "certificate.${key_name}.sha256")"
    [[ "${certificate_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid certificate digest for ${key_name}"
    [[ -z "${SEEN_CERTIFICATE[${certificate_sha}]:-}" ]] \
        || die "certificate digest is reused by ${SEEN_CERTIFICATE[${certificate_sha}]} and ${key_name}"
    SEEN_CERTIFICATE["${certificate_sha}"]="${key_name}"
done

for count_key in apk.resigned_count apk.presigned_count apex.archive_count; do
    count_value="$(manifest_get_exact "${count_key}")"
    [[ "${count_value}" =~ ^(0|[1-9][0-9]*)$ ]] \
        || die "${count_key} is not a canonical non-negative integer"
    [[ "${#count_value}" -le 6 && "${count_value}" -le 100000 ]] \
        || die "${count_key} exceeds the verifier's bounded release size"
done
APEX_ARCHIVE_COUNT="$(manifest_get_exact apex.archive_count)"
[[ "${#APEX_ARCHIVE_COUNT}" -le 4 && "${APEX_ARCHIVE_COUNT}" -le 1024 ]] \
    || die 'apex.archive_count exceeds the bounded module set'
case "$(manifest_get_exact apex.flattened_present)" in true | false) ;; *)
    die 'apex.flattened_present must be true or false' ;;
esac
[[ "${APEX_ARCHIVE_COUNT}" -gt 0 || \
   "$(manifest_get_exact apex.flattened_present)" == true ]] \
    || die 'release contains neither archive nor flattened APEX content'

declare -A SEEN_APEX_NAME=()
declare -A SEEN_APEX_PUBLIC_KEY=()
for ((apex_index = 1; apex_index <= APEX_ARCHIVE_COUNT; apex_index++)); do
    apex_name="$(manifest_get_exact "apex.payload.${apex_index}.name")"
    apex_sha="$(manifest_get_exact "apex.payload.${apex_index}.public_key_sha256")"
    [[ "${apex_name}" =~ ^[A-Za-z0-9._-]+\.apex$ && \
       "${apex_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "invalid archive-APEX public-key record ${apex_index}"
    [[ -z "${SEEN_APEX_NAME[${apex_name}]:-}" && \
       -z "${SEEN_APEX_PUBLIC_KEY[${apex_sha}]:-}" ]] \
        || die "archive-APEX name or payload key is reused: ${apex_name}"
    SEEN_APEX_NAME["${apex_name}"]=1
    SEEN_APEX_PUBLIC_KEY["${apex_sha}"]="${apex_name}"
done

[[ "$(manifest_get_exact boot_signature.verified_count)" == 2 ]] \
    || die 'both boot and recovery must pass BootSignature verification'
OTA_TRUST_SHA="$(manifest_get_exact ota_trust_certificate.sha256)"
[[ "${OTA_TRUST_SHA}" == \
   "$(manifest_get_exact certificate.releasekey.sha256)" ]] \
    || die 'OTA/recovery trust is not exactly releasekey'

declare -A EXPECTED_POSTURE=(
    [build_variant]=user
    [selinux]=enforcing
    [adb_default]=off
    [adb_when_enabled]=authenticated-nonroot
    [flash_locked]=0
    [verified_boot_state]=orange
    [verified_boot]=absent
    [rollback_protection]=absent
    [encryption]=absent
    [ota_artifact]=not-produced
)
for posture_key in "${!EXPECTED_POSTURE[@]}"; do
    [[ "$(manifest_get_exact "posture.${posture_key}")" == \
       "${EXPECTED_POSTURE[${posture_key}]}" ]] \
        || die "incorrect posture.${posture_key}"
done

expected_records=$((23 + (2 * APEX_ARCHIVE_COUNT)))
actual_records="$(awk 'NF { count++ } END { print count + 0 }' "${MANIFEST}")"
[[ "${actual_records}" -eq "${expected_records}" ]] \
    || die "manifest has ${actual_records} records; expected ${expected_records}"

printf 'Tier-3 public release-keyset/posture manifest: PASS\n'
