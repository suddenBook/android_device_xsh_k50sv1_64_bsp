#!/usr/bin/env bash
# Verify active/history certificate and SPKI identities for carried APK bytes.

set -euo pipefail

die() {
    printf 'PRESIGNED APK signer verification failed: %s\n' "$*" >&2
    exit 1
}

[[ "$#" -ge 2 ]] || {
    printf 'Usage: %s <apksigner.jar> [--cts-shim <target-files-entry>] <apk> ...\n' "$0" >&2
    exit 2
}

APKSIG_JAR="$1"
shift
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
IDENTITY_SOURCE="${TOOL_DIR}/K50ApkSignerIdentities.java"

[[ -f "${APKSIG_JAR}" && ! -L "${APKSIG_JAR}" && -r "${APKSIG_JAR}" ]] \
    || die 'apksigner/apksig jar must be an ordinary readable file'
[[ "$(sha256sum "${APKSIG_JAR}" | awk '{print $1}')" == \
   b9b61b17a11523da8e10e454f35ef1093397014e22b67323576816456e64537c ]] \
    || die 'apksigner/apksig jar changed; re-audit and update its pinned digest'
[[ -f "${IDENTITY_SOURCE}" && ! -L "${IDENTITY_SOURCE}" ]] \
    || die 'missing APK signer-identity source helper'
[[ "$(sha256sum "${IDENTITY_SOURCE}" | awk '{print $1}')" == \
   3847598ed8dab3848248a813b22a99bbd128a217d7044551a13afcda7f61a4a4 ]] \
    || die 'APK signer-identity helper changed; re-audit and update its pinned digest'

for command in awk java javac openssl sha256sum; do
    command -v "${command}" >/dev/null 2>&1 \
        || die "missing host command: ${command}"
done

declare -A REJECTED_CERTIFICATE_SHA=(
    [f48bc02fbc79bfa64413e29e113f2deb7d8a31ecc1e00f1d8611cbc06c3e2140]='revoked releasekey certificate'
    [8492187854b0514835ae97dac7259adf6282e5dcef38bb7264f920254aaf6ed3]='revoked platform certificate'
    [ccce2337bc804f6cf9900b311f45bc4d7eb51b5a4cd0a7b93cb453c531394d03]='revoked shared certificate'
    [33420d95547f3b5787f0af08f0aa11287acc91de4c0ce52594158b7d8fb9620b]='revoked media certificate'
    [1a8e5a429c9b8376376fe0fc2608695de5e2b9d030f9536374fa1aab8e3a2515]='revoked networkstack certificate'
    [1ce46e328af4f407ef128930eb937bbfa72e092eda6a0b002d6b4aabef40d996]='revoked bootsignature certificate'
)
declare -A REJECTED_PUBLIC_KEY_SHA=(
    [9ecb37c53b1eaed239b6499889e923fa3ec8da805b912a90dd977139a33ae83e]='revoked releasekey public key'
    [ce971c311758671f6cb41251eb6d78f62a7e0a2ec4452d2dc25be2495a785ecc]='revoked platform public key'
    [c86950b88f7dfd08cef0d2f9d56d9242f5c7767435b0e6e506020d3211f5efa2]='revoked shared public key'
    [7436ba4e5a0564d4374e60fe8f62440f5d5e6022fcf4c613262e9a290ea1d6a0]='revoked media public key'
    [6d8e733d530e5fe925fe78fd722ab7fda91bd7dc798321976741601157ae0d01]='revoked networkstack public key'
    [8f458cc4ba2ff68ebfbbd998a2bd93b7afaae1238f6ae740d5882fff636383df]='revoked bootsignature public key'
    [e6b000d8b0fb0ee5e9c8d03c791c57f0096e5cf3c923582fc43c149a84d47d92]='revoked global APEX public key'
)

for development_certificate in \
    "${LINEAGE_ROOT}"/build/make/target/product/security/*.x509.pem; do
    [[ -f "${development_certificate}" && ! -L "${development_certificate}" ]] \
        || continue
    development_certificate_sha="$(
        openssl x509 -in "${development_certificate}" -outform DER 2>/dev/null \
            | sha256sum | awk '{print $1}'
    )" || die "cannot derive development certificate identity: ${development_certificate}"
    development_public_sha="$(
        openssl x509 -in "${development_certificate}" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null \
            | sha256sum | awk '{print $1}'
    )" || die "cannot derive development public-key identity: ${development_certificate}"
    [[ "${development_certificate_sha}" =~ ^[0-9a-f]{64}$ && \
       "${development_public_sha}" =~ ^[0-9a-f]{64}$ ]] \
        || die "malformed development identity: ${development_certificate}"
    REJECTED_CERTIFICATE_SHA["${development_certificate_sha}"]="AOSP development certificate ${development_certificate}"
    REJECTED_PUBLIC_KEY_SHA["${development_public_sha}"]="AOSP development public key ${development_certificate}"
done

VERIFY_TMP="$(mktemp -d /tmp/k50-apk-signers.XXXXXX)"
cleanup() {
    if [[ -d "${VERIFY_TMP:-}" && ! -L "${VERIFY_TMP}" && \
          "${VERIFY_TMP}" == /tmp/k50-apk-signers.* ]]; then
        find "${VERIFY_TMP}" -mindepth 1 -depth -delete || true
        rmdir "${VERIFY_TMP}" || true
    fi
}
trap cleanup EXIT

javac -encoding UTF-8 -source 8 -target 8 \
    -cp "${APKSIG_JAR}" -d "${VERIFY_TMP}" "${IDENTITY_SOURCE}" \
    >"${VERIFY_TMP}/javac.out" 2>"${VERIFY_TMP}/javac.err" \
    || die 'cannot compile the APK signer-identity helper'

verified_count=0
cts_shim_count=0
while [[ "$#" -gt 0 ]]; do
    cts_shim_sha=
    if [[ "$1" == --cts-shim ]]; then
        [[ "$#" -ge 3 ]] || die '--cts-shim needs an installed entry and APK'
        # AOSP Q deliberately retains these two CTS fixtures under testkey.
        # Exact official bytes bind their package IDs, hasCode=false declarations
        # and restrict-update hashes. A name or certificate alone is no exception.
        case "$2" in
            SYSTEM/app/CtsShimPrebuilt/CtsShimPrebuilt.apk)
                cts_shim_sha=7511d5fa669e86cdeb02be41009cf788b2c97ec1a39f4b004b9983342f9bdb09
                ;;
            SYSTEM/priv-app/K50CtsShimPrivPrebuilt/K50CtsShimPrivPrebuilt.apk)
                cts_shim_sha=32434dbb4bbc03a50c0e114d27c76760173364b070f1898326ee8e6134266731
                ;;
            *) die "unrecognized CTS shim installed entry: $2" ;;
        esac
        shift 2
    fi
    apk="$1"
    shift
    [[ -f "${apk}" && ! -L "${apk}" && -s "${apk}" ]] \
        || die "APK must be an ordinary non-empty file: ${apk}"
    if [[ -n "${cts_shim_sha}" ]]; then
        [[ "$(sha256sum "${apk}" | awk '{print $1}')" == "${cts_shim_sha}" ]] \
            || die "CTS shim differs from the audited AOSP Q APK: ${apk}"
    fi
    identity_report="${VERIFY_TMP}/identity-${verified_count}.tsv"
    # Put the freshly compiled, source-hash-pinned helper first so a same-named
    # class can never shadow it from the dependency jar.
    java -cp "${VERIFY_TMP}:${APKSIG_JAR}" K50ApkSignerIdentities "${apk}" \
        >"${identity_report}" \
        || die "APK signature/identity extraction failed: ${apk}"

    active_count=0
    identity_count=0
    while IFS=$'\t' read -r role certificate_sha public_key_sha extra; do
        [[ -z "${extra}" && "${role}" =~ ^(active|history)$ && \
           "${certificate_sha}" =~ ^[0-9a-f]{64}$ && \
           "${public_key_sha}" =~ ^[0-9a-f]{64}$ ]] \
            || die "malformed signer identity record for ${apk}"
        identity_count=$((identity_count + 1))
        [[ "${role}" == active ]] && active_count=$((active_count + 1))
        if [[ -n "${cts_shim_sha}" ]]; then
            [[ "${role}" == active && \
               "${certificate_sha}" == a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc && \
               "${public_key_sha}" == ef57b690165cb561b5026922c00d2d6574e8b184fa7d161e076f06e06e6d35db ]] \
                || die "CTS shim signer differs from audited AOSP Q identity: ${apk}"
            continue
        fi
        if [[ -n "${REJECTED_CERTIFICATE_SHA[${certificate_sha}]:-}" ]]; then
            die "${apk} uses ${REJECTED_CERTIFICATE_SHA[${certificate_sha}]} (${role})"
        fi
        if [[ -n "${REJECTED_PUBLIC_KEY_SHA[${public_key_sha}]:-}" ]]; then
            die "${apk} uses ${REJECTED_PUBLIC_KEY_SHA[${public_key_sha}]} (${role})"
        fi
    done <"${identity_report}"
    [[ "${active_count}" -gt 0 && "${identity_count}" -ge "${active_count}" ]] \
        || die "APK exposes no active signer identity: ${apk}"
    if [[ -n "${cts_shim_sha}" ]]; then
        [[ "${identity_count}" -eq 1 ]] || die "CTS shim has additional signers: ${apk}"
        cts_shim_count=$((cts_shim_count + 1))
    fi
    verified_count=$((verified_count + 1))
done

printf 'PRESIGNED APK certificate/SPKI active+history contract: PASS (%s APKs, %s exact AOSP Q CTS shims)\n' \
    "${verified_count}" "${cts_shim_count}"
