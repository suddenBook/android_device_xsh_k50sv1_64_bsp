#!/usr/bin/env bash
# Host-only positive and hostile fixtures for external Tier-3 key handling.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
DEVICE_REPO="${PROJECT_ROOT}/lineage-17.1/device/xsh/k50sv1_64_bsp"
PREPARE="${TOOL_DIR}/prepare-tier3-keyset.sh"
TEST_ROOT="$(mktemp -d /tmp/k50-tier3-keyset.test.XXXXXX)"

cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-tier3-keyset.test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT

make_pair() {
    local directory="$1"
    local name="$2"
    local bits="${3:-2048}"
    local private_pem="${directory}/.${name}.private.pem"

    openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${bits}" \
        -out "${private_pem}" >/dev/null 2>&1
    openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt \
        -in "${private_pem}" -out "${directory}/${name}.pk8"
    openssl req -new -x509 -sha256 -days 3650 \
        -key "${private_pem}" -out "${directory}/${name}.x509.pem" \
        -subj "/CN=k50 fixture ${name}" >/dev/null 2>&1
    find "${private_pem}" -delete
    chmod 0600 "${directory}/${name}.pk8"
    chmod 0644 "${directory}/${name}.x509.pem"
}

make_keyset() {
    local directory="$1"
    mkdir -m 0700 "${directory}"
    for name in releasekey platform shared media networkstack bootsignature; do
        make_pair "${directory}" "${name}"
    done
}

clone_keyset() {
    local name="$1"
    local directory="${TEST_ROOT}/${name}"
    cp -a "${TEST_ROOT}/valid-source" "${directory}"
    printf '%s' "${directory}"
}

new_snapshot() {
    local name="$1"
    local directory="${TEST_ROOT}/snapshot-${name}"
    mkdir -m 0700 "${directory}"
    printf '%s' "${directory}"
}

expect_fail() {
    local source="$1"
    local name="$2"
    local expected_error="${3:-}"
    local snapshot
    snapshot="$(new_snapshot "${name}")"
    if K50SV1_RELEASE_KEYS_DIR="${source}" \
        "${PREPARE}" "${snapshot}" >"${TEST_ROOT}/${name}.out" \
        2>"${TEST_ROOT}/${name}.err"; then
        printf 'Expected keyset fixture to fail: %s\n' "${name}" >&2
        exit 1
    fi
    if [[ -n "${expected_error}" ]] && \
       ! grep -Fq -- "${expected_error}" "${TEST_ROOT}/${name}.err"; then
        printf 'Keyset fixture %s failed for the wrong reason; expected: %s\n' \
            "${name}" "${expected_error}" >&2
        sed -n '1,80p' "${TEST_ROOT}/${name}.err" >&2
        exit 1
    fi
}

make_keyset "${TEST_ROOT}/valid-source"
valid_snapshot="$(new_snapshot valid)"
K50SV1_RELEASE_KEYS_DIR="${TEST_ROOT}/valid-source" \
    "${PREPARE}" "${valid_snapshot}" >/dev/null
[[ -s "${valid_snapshot}/KEYSET-INPUT" && \
   ! -e "${valid_snapshot}/verity.pk8" && \
   ! -e "${valid_snapshot}/apex.pem" ]]
snapshot_release_sha="$(sha256sum "${valid_snapshot}/releasekey.pk8" | awk '{print $1}')"
printf 'source mutation after snapshot\n' \
    >>"${TEST_ROOT}/valid-source/releasekey.pk8"
[[ "$(sha256sum "${valid_snapshot}/releasekey.pk8" | awk '{print $1}')" == \
   "${snapshot_release_sha}" ]]
# Restore the base fixture for hostile clones.
find "${TEST_ROOT}/valid-source" -mindepth 1 -depth -delete
rmdir "${TEST_ROOT}/valid-source"
make_keyset "${TEST_ROOT}/valid-source"

unsafe_mode="$(clone_keyset unsafe-mode)"
chmod 0644 "${unsafe_mode}/releasekey.pk8"
expect_fail "${unsafe_mode}" unsafe-mode

symlink_file="$(clone_keyset symlink-file)"
find "${symlink_file}/platform.pk8" -delete
ln -s releasekey.pk8 "${symlink_file}/platform.pk8"
expect_fail "${symlink_file}" symlink-file

duplicate="$(clone_keyset duplicate-cert)"
cp "${duplicate}/releasekey.pk8" "${duplicate}/platform.pk8"
cp "${duplicate}/releasekey.x509.pem" "${duplicate}/platform.x509.pem"
chmod 0600 "${duplicate}/platform.pk8"
chmod 0644 "${duplicate}/platform.x509.pem"
expect_fail "${duplicate}" duplicate-cert

legacy_name="$(clone_keyset legacy-name)"
cp "${legacy_name}/bootsignature.pk8" "${legacy_name}/verity.pk8"
chmod 0600 "${legacy_name}/verity.pk8"
expect_fail "${legacy_name}" legacy-name

legacy_apex="$(clone_keyset legacy-apex)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "${legacy_apex}/apex.pem" >/dev/null 2>&1
chmod 0600 "${legacy_apex}/apex.pem"
expect_fail "${legacy_apex}" legacy-apex

git_parent="${TEST_ROOT}/git-parent"
mkdir -m 0700 "${git_parent}"
git -C "${git_parent}" init -q
cp -a "${TEST_ROOT}/valid-source" "${git_parent}/keys"
expect_fail "${git_parent}/keys" inside-git \
    'inside Git must be ignored as a whole'
printf '/keys/\n' >"${git_parent}/.gitignore"
ignored_snapshot="$(new_snapshot ignored-git-directory)"
K50SV1_RELEASE_KEYS_DIR="${git_parent}/keys" \
    "${PREPARE}" "${ignored_snapshot}" >/dev/null
[[ -s "${ignored_snapshot}/KEYSET-INPUT" ]]
cmp -s "${git_parent}/keys/releasekey.pk8" \
    "${ignored_snapshot}/releasekey.pk8"
# Force-add only a public fixture certificate, never a private key.
git -C "${git_parent}" add -f -- keys/releasekey.x509.pem
expect_fail "${git_parent}/keys" tracked-in-ignored-git \
    'contains tracked Git files'

bare_parent="${TEST_ROOT}/bare.git"
git init --bare -q "${bare_parent}"
cp -a "${TEST_ROOT}/valid-source" "${bare_parent}/keys"
expect_fail "${bare_parent}/keys" bare-git \
    'inside Git metadata or a bare repository'

cp -a "${TEST_ROOT}/valid-source" "${git_parent}/.git/keys"
expect_fail "${git_parent}/.git/keys" git-metadata \
    'inside Git metadata or a bare repository'

symlink_dir="${TEST_ROOT}/symlink-dir"
ln -s "${TEST_ROOT}/valid-source" "${symlink_dir}"
expect_fail "${symlink_dir}" symlink-dir

expect_fail "${PROJECT_ROOT}" inside-project

aosp_dev="$(clone_keyset aosp-dev-cert)"
cp "${PROJECT_ROOT}/lineage-17.1/build/make/target/product/security/testkey.pk8" \
    "${aosp_dev}/releasekey.pk8"
cp "${PROJECT_ROOT}/lineage-17.1/build/make/target/product/security/testkey.x509.pem" \
    "${aosp_dev}/releasekey.x509.pem"
chmod 0600 "${aosp_dev}/releasekey.pk8"
chmod 0644 "${aosp_dev}/releasekey.x509.pem"
expect_fail "${aosp_dev}" aosp-dev-cert

revoked="$(clone_keyset revoked-published-cert)"
git -C "${DEVICE_REPO}" show \
    'ba4f963^:security/releasekey.pk8' >"${revoked}/releasekey.pk8"
git -C "${DEVICE_REPO}" show \
    'ba4f963^:security/releasekey.x509.pem' >"${revoked}/releasekey.x509.pem"
chmod 0600 "${revoked}/releasekey.pk8"
chmod 0644 "${revoked}/releasekey.x509.pem"
expect_fail "${revoked}" revoked-published-cert

reissued="$(clone_keyset reissued-revoked-public-key)"
git -C "${DEVICE_REPO}" show \
    'ba4f963^:security/releasekey.pk8' >"${reissued}/releasekey.pk8"
openssl pkcs8 -inform DER -nocrypt -in "${reissued}/releasekey.pk8" \
    -out "${reissued}/.reissued-private.pem"
openssl req -new -x509 -sha256 -days 3650 \
    -key "${reissued}/.reissued-private.pem" \
    -out "${reissued}/releasekey.x509.pem" \
    -subj '/CN=reissued compromised public key' >/dev/null 2>&1
find "${reissued}/.reissued-private.pem" -delete
chmod 0600 "${reissued}/releasekey.pk8"
chmod 0644 "${reissued}/releasekey.x509.pem"
expect_fail "${reissued}" reissued-revoked-public-key

mapped="$(clone_keyset mapped-apex)"
mkdir -m 0700 "${mapped}/apex"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
    -out "${mapped}/apex/com.android.fixture.apex.pem" >/dev/null 2>&1
chmod 0600 "${mapped}/apex/com.android.fixture.apex.pem"
printf 'com.android.fixture.apex\tapex/com.android.fixture.apex.pem\n' \
    >"${mapped}/apex-map.tsv"
chmod 0600 "${mapped}/apex-map.tsv"
mapped_snapshot="$(new_snapshot mapped-apex)"
K50SV1_RELEASE_KEYS_DIR="${mapped}" \
    "${PREPARE}" "${mapped_snapshot}" >/dev/null
[[ -s "${mapped_snapshot}/apex/com.android.fixture.apex.pem" ]]

weak_apex="$(clone_keyset weak-apex)"
mkdir -m 0700 "${weak_apex}/apex"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "${weak_apex}/apex/com.android.fixture.apex.pem" >/dev/null 2>&1
chmod 0600 "${weak_apex}/apex/com.android.fixture.apex.pem"
printf 'com.android.fixture.apex\tapex/com.android.fixture.apex.pem\n' \
    >"${weak_apex}/apex-map.tsv"
chmod 0600 "${weak_apex}/apex-map.tsv"
expect_fail "${weak_apex}" weak-apex 'must be exactly 4096 bits'

global_reuse_apex="$(clone_keyset global-reuse-apex)"
find "${global_reuse_apex}/releasekey.pk8" \
    "${global_reuse_apex}/releasekey.x509.pem" -delete
make_pair "${global_reuse_apex}" releasekey 4096
mkdir -m 0700 "${global_reuse_apex}/apex"
openssl pkcs8 -inform DER -nocrypt \
    -in "${global_reuse_apex}/releasekey.pk8" \
    -out "${global_reuse_apex}/apex/com.android.fixture.apex.pem"
chmod 0600 "${global_reuse_apex}/apex/com.android.fixture.apex.pem"
printf 'com.android.fixture.apex\tapex/com.android.fixture.apex.pem\n' \
    >"${global_reuse_apex}/apex-map.tsv"
chmod 0600 "${global_reuse_apex}/apex-map.tsv"
expect_fail "${global_reuse_apex}" global-reuse-apex \
    'reuses global releasekey'

source_apex="$(clone_keyset source-apex)"
mkdir -m 0700 "${source_apex}/apex"
cp "${PROJECT_ROOT}/lineage-17.1/art/build/apex/com.android.runtime.pem" \
    "${source_apex}/apex/com.android.fixture.apex.pem"
chmod 0600 "${source_apex}/apex/com.android.fixture.apex.pem"
printf 'com.android.fixture.apex\tapex/com.android.fixture.apex.pem\n' \
    >"${source_apex}/apex-map.tsv"
chmod 0600 "${source_apex}/apex-map.tsv"
expect_fail "${source_apex}" source-apex 'reuses source-tree APEX key'

revoked_apex="$(clone_keyset revoked-apex-public-key)"
mkdir -m 0700 "${revoked_apex}/apex"
git -C "${DEVICE_REPO}" show 'ba4f963^:security/apex.pem' \
    >"${revoked_apex}/apex/com.android.fixture.apex.pem"
chmod 0600 "${revoked_apex}/apex/com.android.fixture.apex.pem"
printf 'com.android.fixture.apex\tapex/com.android.fixture.apex.pem\n' \
    >"${revoked_apex}/apex-map.tsv"
chmod 0600 "${revoked_apex}/apex-map.tsv"
expect_fail "${revoked_apex}" revoked-apex-public-key \
    'reuses published/revoked global APEX key'

bad_map="$(clone_keyset bad-apex-map)"
printf 'com.android.fixture.apex\t../escape.pem\n' \
    >"${bad_map}/apex-map.tsv"
chmod 0600 "${bad_map}/apex-map.tsv"
expect_fail "${bad_map}" bad-apex-map

printf 'TIER-3 EXTERNAL KEYSET FIXTURE MATRIX: PASS\n'
