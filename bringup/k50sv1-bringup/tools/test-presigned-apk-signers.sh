#!/usr/bin/env bash
# Positive and compromised-key hostile fixtures for PRESIGNED APK trust.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
LINEAGE_ROOT="${PROJECT_ROOT}/lineage-17.1"
DEVICE_REPO="${LINEAGE_ROOT}/device/xsh/k50sv1_64_bsp"
VERIFY="${TOOL_DIR}/verify-presigned-apk-signers.sh"
APKSIG_JAR="${LINEAGE_ROOT}/prebuilts/sdk/tools/linux/lib/apksigner.jar"
SOURCE_APK="${LINEAGE_ROOT}/vendor/gapps/common/proprietary/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"
TEST_ROOT="$(mktemp -d /tmp/k50-presigned-apk-test.XXXXXX)"

cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-presigned-apk-test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete || true
        rmdir "${TEST_ROOT}" || true
    fi
}
trap cleanup EXIT

sign_apk() {
    local key="$1"
    local certificate="$2"
    local output="$3"

    java -jar "${APKSIG_JAR}" sign \
        --key "${key}" \
        --cert "${certificate}" \
        --out "${output}" \
        "${SOURCE_APK}"
}

expect_fail() {
    local apk="$1"
    local name="$2"
    local expected_error="${3:-}"
    local verify_options=("${@:4}")

    if "${VERIFY}" "${APKSIG_JAR}" "${verify_options[@]}" "${apk}" \
        >"${TEST_ROOT}/${name}.out" 2>"${TEST_ROOT}/${name}.err"; then
        printf 'Expected PRESIGNED signer fixture to fail: %s\n' "${name}" >&2
        exit 1
    fi
    if [[ -n "${expected_error}" ]] && \
       ! grep -Fq -- "${expected_error}" "${TEST_ROOT}/${name}.err"; then
        printf 'PRESIGNED signer fixture %s failed for the wrong reason; expected: %s\n' \
            "${name}" "${expected_error}" >&2
        sed -n '1,80p' "${TEST_ROOT}/${name}.err" >&2
        exit 1
    fi
}

[[ -x "${VERIFY}" && -r "${APKSIG_JAR}" && -s "${SOURCE_APK}" ]]

# Dependency substitution must fail before any verifier class is loaded.
cp "${APKSIG_JAR}" "${TEST_ROOT}/tampered-apksigner.jar"
printf 'tamper\n' >>"${TEST_ROOT}/tampered-apksigner.jar"
if "${VERIFY}" "${TEST_ROOT}/tampered-apksigner.jar" "${SOURCE_APK}" \
    >"${TEST_ROOT}/tampered-jar.out" 2>"${TEST_ROOT}/tampered-jar.err"; then
    printf 'Expected tampered apksigner fixture to fail\n' >&2
    exit 1
fi
grep -Fq 'apksigner/apksig jar changed' "${TEST_ROOT}/tampered-jar.err" || {
    printf 'Tampered apksigner fixture failed for the wrong reason\n' >&2
    exit 1
}

# A real third-party Google split and a fresh non-development fixture key pass.
"${VERIFY}" "${APKSIG_JAR}" "${SOURCE_APK}" >/dev/null
mapfile -d '' carried_apks < <(
    find \
        "${LINEAGE_ROOT}/vendor/gapps/common/proprietary" \
        "${LINEAGE_ROOT}/vendor/gapps/arm64/proprietary" \
        "${LINEAGE_ROOT}/vendor/huawei/hms/proprietary" \
        -type f -name '*.apk' -print0
)
[[ "${#carried_apks[@]}" -eq 13 ]] || {
    printf 'Expected 13 carried Google/Huawei APKs, found %s\n' \
        "${#carried_apks[@]}" >&2
    exit 1
}
"${VERIFY}" "${APKSIG_JAR}" "${carried_apks[@]}" >/dev/null

# CTS exempts only these two original fixtures from its testkey prohibition.
# The explicit installed path must select the corresponding exact APK bytes.
CTS_SYSTEM="${LINEAGE_ROOT}/frameworks/base/packages/CtsShim/apk/arm/CtsShim.apk"
CTS_PRIV="${LINEAGE_ROOT}/frameworks/base/packages/CtsShim/apk/arm/CtsShimPriv.apk"
CTS_SYSTEM_ENTRY=SYSTEM/app/CtsShimPrebuilt/CtsShimPrebuilt.apk
CTS_PRIV_ENTRY=SYSTEM/priv-app/K50CtsShimPrivPrebuilt/K50CtsShimPrivPrebuilt.apk
"${VERIFY}" "${APKSIG_JAR}" \
    --cts-shim "${CTS_SYSTEM_ENTRY}" "${CTS_SYSTEM}" \
    --cts-shim "${CTS_PRIV_ENTRY}" "${CTS_PRIV}" \
    "${SOURCE_APK}" >/dev/null
expect_fail "${CTS_SYSTEM}" shim-without-context 'AOSP development certificate'
expect_fail "${CTS_PRIV}" swapped-shim 'differs from the audited AOSP Q APK' \
    --cts-shim "${CTS_SYSTEM_ENTRY}"
expect_fail "${CTS_SYSTEM}" unrelated-shim-path 'unrecognized CTS shim installed entry' \
    --cts-shim SYSTEM/app/Other/Other.apk
cp "${CTS_SYSTEM}" "${TEST_ROOT}/changed-shim.apk"
printf 'changed\n' >>"${TEST_ROOT}/changed-shim.apk"
expect_fail "${TEST_ROOT}/changed-shim.apk" changed-shim 'differs from the audited AOSP Q APK' \
    --cts-shim "${CTS_SYSTEM_ENTRY}"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "${TEST_ROOT}/fresh.pem" >/dev/null 2>&1
openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
    -in "${TEST_ROOT}/fresh.pem" -out "${TEST_ROOT}/fresh.pk8"
openssl req -new -x509 -sha256 -days 30 \
    -key "${TEST_ROOT}/fresh.pem" \
    -out "${TEST_ROOT}/fresh.x509.pem" \
    -subj '/CN=fresh third-party fixture' >/dev/null 2>&1
sign_apk "${TEST_ROOT}/fresh.pk8" "${TEST_ROOT}/fresh.x509.pem" \
    "${TEST_ROOT}/fresh.apk"
"${VERIFY}" "${APKSIG_JAR}" "${TEST_ROOT}/fresh.apk" >/dev/null

# Exact AOSP development certificate: rejected by both certificate and SPKI.
sign_apk \
    "${LINEAGE_ROOT}/build/make/target/product/security/testkey.pk8" \
    "${LINEAGE_ROOT}/build/make/target/product/security/testkey.x509.pem" \
    "${TEST_ROOT}/aosp-exact.apk"
expect_fail "${TEST_ROOT}/aosp-exact.apk" aosp-exact
expect_fail "${TEST_ROOT}/aosp-exact.apk" testkey-as-shim 'differs from the audited AOSP Q APK' \
    --cts-shim "${CTS_SYSTEM_ENTRY}"

# The same public/private key wrapped in a newly issued certificate must still
# fail. This is the certificate-DER-only bypass the adversarial review found.
openssl pkcs8 -inform DER -nocrypt \
    -in "${LINEAGE_ROOT}/build/make/target/product/security/testkey.pk8" \
    -out "${TEST_ROOT}/aosp-private.pem"
openssl req -new -x509 -sha256 -days 30 \
    -key "${TEST_ROOT}/aosp-private.pem" \
    -out "${TEST_ROOT}/aosp-reissued.x509.pem" \
    -subj '/CN=reissued AOSP development public key' >/dev/null 2>&1
sign_apk \
    "${LINEAGE_ROOT}/build/make/target/product/security/testkey.pk8" \
    "${TEST_ROOT}/aosp-reissued.x509.pem" \
    "${TEST_ROOT}/aosp-reissued.apk"
expect_fail "${TEST_ROOT}/aosp-reissued.apk" aosp-reissued \
    'AOSP development public key'

# A clean active signer does not sanitize a compromised certificate retained in
# a valid v3 proof-of-rotation lineage. The helper must enumerate history too.
java -jar "${APKSIG_JAR}" rotate \
    --out "${TEST_ROOT}/aosp-history.lineage" \
    --old-signer \
    --key "${LINEAGE_ROOT}/build/make/target/product/security/testkey.pk8" \
    --cert "${LINEAGE_ROOT}/build/make/target/product/security/testkey.x509.pem" \
    --new-signer \
    --key "${TEST_ROOT}/fresh.pk8" \
    --cert "${TEST_ROOT}/fresh.x509.pem"
java -jar "${APKSIG_JAR}" sign \
    --key "${LINEAGE_ROOT}/build/make/target/product/security/testkey.pk8" \
    --cert "${LINEAGE_ROOT}/build/make/target/product/security/testkey.x509.pem" \
    --next-signer \
    --key "${TEST_ROOT}/fresh.pk8" \
    --cert "${TEST_ROOT}/fresh.x509.pem" \
    --lineage "${TEST_ROOT}/aosp-history.lineage" \
    --out "${TEST_ROOT}/aosp-history.apk" \
    "${SOURCE_APK}"
expect_fail "${TEST_ROOT}/aosp-history.apk" aosp-history '(history)'

# Repeat the same attack with the device's published/revoked release key.
git -C "${DEVICE_REPO}" show 'ba4f963^:security/releasekey.pk8' \
    >"${TEST_ROOT}/revoked.pk8"
openssl pkcs8 -inform DER -nocrypt \
    -in "${TEST_ROOT}/revoked.pk8" \
    -out "${TEST_ROOT}/revoked-private.pem"
openssl req -new -x509 -sha256 -days 30 \
    -key "${TEST_ROOT}/revoked-private.pem" \
    -out "${TEST_ROOT}/revoked-reissued.x509.pem" \
    -subj '/CN=reissued revoked device public key' >/dev/null 2>&1
sign_apk \
    "${TEST_ROOT}/revoked.pk8" \
    "${TEST_ROOT}/revoked-reissued.x509.pem" \
    "${TEST_ROOT}/revoked-reissued.apk"
expect_fail "${TEST_ROOT}/revoked-reissued.apk" revoked-reissued \
    'revoked releasekey public key'

printf 'PRESIGNED APK CERTIFICATE/SPKI HOSTILE FIXTURE MATRIX: PASS\n'
