#!/bin/bash
#
# Import a MindTheGapps release zip into vendor/gapps.
#
# The layout, the file split between common/ and arm64/, and the generated
# Android.bp / *-vendor.mk are MindTheGapps' own, from
#   https://gitlab.com/MindTheGapps/vendor_gapps @ 59bcb4c6
# The payload is the newer released zip, because the repo's checked-in blobs
# lag its releases. Everything this script writes is derived from the zip; the
# only hand-written file in vendor/gapps is README.md.
#
# Nothing is extracted until the archive is proven to be signed by the
# certificate the caller supplied out of band -- normally the copy kept at
# vendor/gapps/security/mindthegapps-release.x509.pem.
#
# Usage: import-mindthegapps.sh <MindTheGapps-*.zip> <release.x509.pem> [<lineage root>]

set -euo pipefail

ZIP=${1:?usage: import-mindthegapps.sh <zip> <release.x509.pem> [<lineage root>]}
CERT=${2:?usage: import-mindthegapps.sh <zip> <release.x509.pem> [<lineage root>]}
ROOT=${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lineage-17.1}

VENDOR="$ROOT/vendor/gapps"

die() { echo "import-mindthegapps: $*" >&2; exit 1; }

[ -f "$ZIP" ]     || die "no such zip: $ZIP"
[ -f "$CERT" ]    || die "no such certificate: $CERT"
[ -d "$ROOT" ]    || die "no such lineage root: $ROOT"
[ -d "$VENDOR" ]  || die "no such vendor directory: $VENDOR"
[ -f "$VENDOR/arm64/arm64-vendor.mk" ] \
    || die "$VENDOR does not hold the MindTheGapps makefiles; nothing to import into"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- authenticity -----------------------------------------------------------
#
# The ONLY question worth asking is "did the key I was given sign this
# archive", and the only tool here that can answer it is jarsigner with a
# trust store that contains nothing else. Three tempting checks cannot answer
# it, and composing them does not either:
#
#   * META-INF/com/android/otacert is an ordinary file inside the zip. An
#     attacker copies it in verbatim.
#   * `jarsigner -verify` alone proves that SOME signature is valid. It never
#     names the key, and it exits 0 on an archive with no signature at all
#     (measured).
#   * the certificate inside META-INF/CERT.RSA is also attacker-chosen: the
#     block name is arbitrary, so a payload signed as EVIL.SF/EVIL.RSA can
#     carry a genuine but orphaned CERT.RSA beside it.
#
# All three of those were in an earlier version of this script and a forged
# archive signed by CN=Attacker passed all three. The alias-pinned verify
# below rejects that same archive with exit 36.
#
# apksigner cannot be used: an OTA zip has no AndroidManifest.xml and it
# refuses to look at one.
command -v jarsigner >/dev/null || die "jarsigner not on PATH; cannot verify the zip"
command -v keytool   >/dev/null || die "keytool not on PATH; cannot verify the zip"
command -v openssl   >/dev/null || die "openssl not on PATH; cannot verify the zip"

openssl x509 -in "$CERT" -outform DER -out "$tmp/owner.der" 2>/dev/null \
    || die "supplied certificate is not a PEM X.509 certificate: $CERT"
keytool -importcert -noprompt -alias mtg -file "$tmp/owner.der" \
        -keystore "$tmp/trust.jks" -storetype JKS -storepass k50sv1 >/dev/null 2>&1 \
    || die "could not build a trust store from $CERT"

# The alias is POSITIONAL for -verify: jarsigner then requires that THIS alias
# signed the archive. -strict folds signer errors into the exit code, which is
# what makes a self-signed release certificate acceptable only because it is
# the one in the trust store.
jarsigner -verify -strict -keystore "$tmp/trust.jks" -storepass k50sv1 "$ZIP" mtg \
        >/dev/null 2>&1 \
    || die "zip is not signed by $(basename "$CERT")"

# -strict still exits 0 for an archive with no manifest, so assert separately
# that it is signed at all, and by exactly one signer.
jarsigner -verify -verbose:summary "$ZIP" 2>&1 \
    | sed -n 's/^- Signed by "\(.*\)"$/\1/p' > "$tmp/signers"
signer_count=$(grep -c . "$tmp/signers" || true)
[ "$signer_count" = 1 ] \
    || die "zip has $signer_count signers; exactly one was expected"
echo "verified: signed by $(cat "$tmp/signers")"

# The otacert comparison is kept, AFTER the real check, for a different
# purpose: it proves the zip carries the recovery trust anchor this import
# claims, so a future sideload of the same zip is verifiable on device.
unzip -p "$ZIP" META-INF/com/android/otacert > "$tmp/otacert.pem" 2>/dev/null \
    || die "zip has no META-INF/com/android/otacert"
cmp -s "$tmp/otacert.pem" "$CERT" \
    || die "zip otacert differs from the supplied certificate"

# --- payload ----------------------------------------------------------------
#
# MindTheGapps splits its files between an architecture-independent set and a
# per-architecture set. The two arrays below are proprietary-files-common*.txt
# and proprietary-files-arm64*.txt from the upstream repo, verbatim.
COMMON_FILES=(
    app/GoogleCalendarSyncAdapter/GoogleCalendarSyncAdapter.apk
    app/GoogleContactsSyncAdapter/GoogleContactsSyncAdapter.apk
    priv-app/AndroidMigratePrebuilt/AndroidMigratePrebuilt.apk
    priv-app/GoogleFeedback/GoogleFeedback.apk
    priv-app/GooglePartnerSetup/GooglePartnerSetup.apk
    priv-app/GoogleServicesFramework/GoogleServicesFramework.apk
    priv-app/Phonesky/Phonesky.apk
    framework/com.google.android.dialer.support.jar
    framework/com.google.android.maps.jar
    etc/permissions/com.google.android.dialer.support.xml
    etc/permissions/com.google.android.maps.xml
    etc/permissions/privapp-permissions-google.xml
    etc/permissions/privapp-permissions-google-p.xml
    etc/permissions/privapp-permissions-google-ps.xml
    etc/sysconfig/google-hiddenapi-package-whitelist.xml
    etc/sysconfig/google.xml
    etc/sysconfig/google_build.xml
)
ARM64_FILES=(
    app/MarkupGoogle/MarkupGoogle.apk
    app/MarkupGoogle/lib/arm64/libsketchology_native.so
    priv-app/PrebuiltGmsCore/PrebuiltGmsCore.apk
    priv-app/SetupWizardPrebuilt/SetupWizardPrebuilt.apk
    priv-app/Velvet/Velvet.apk
    lib/libjni_latinimegoogle.so
    lib64/libjni_latinimegoogle.so
)

# Deliberately NOT imported. The completeness check below treats these as
# claimed, so a payload change upstream is still caught, but the files never
# reach the tree.
#
# PrebuiltExchange3Google: MindTheGapps' own README says it ships it because it
# "is no longer included in Google system images and is required for using
# Exchange accounts in the Gmail app" -- and this payload has no Gmail, while
# AOSP's Exchange2 is already in the product. It is also the one APK in the
# payload whose signature is stripped: its META-INF/CERT.SF declares
# `X-Android-APK-Signed: 2` with no APK Signing Block, so `apksigner verify`
# reports "Signature stripped?" and fails where the other eleven pass. Tiers 1
# and 2 do not care -- PackageManagerService sets skipVerify for a
# system-partition scan -- but Tier 3 hands every PRESIGNED APK in the signed
# target-files to verify-presigned-apk-signers.sh, which dies when identity
# extraction fails. Not importing it removes it from that gate's input instead
# of carving an exception into the gate.
EXCLUDED_FILES=(
    app/PrebuiltExchange3Google/PrebuiltExchange3Google.apk
)

extract_set() {
    local dest=$1; shift
    local f
    for f in "$@"; do
        mkdir -p "$dest/$(dirname "$f")"
        unzip -p "$ZIP" "system/$f" > "$dest/$f" \
            || die "zip is missing system/$f"
        [ -s "$dest/$f" ] || die "zip entry system/$f is empty"
    done
}

# Anything in the zip that neither array claims is a payload change upstream
# has not been told about. Fail loudly rather than ship an incomplete import.
#
# THIS RUNS BEFORE THE EXTRACTION, and it has to. It needs nothing from the
# extraction -- only the zip's own index -- and when it ran after, "refusing
# an incomplete import" happened with the old vendor/gapps tree already
# rm -rf'd and the partial new one already in place, while payload.sha256
# (written last) still described the old payload. The failure left the tree
# in the state the message says it refused to create.
# addon.d holds the installer's own OTA-survival scripts, which an inline
# build does not use; directory entries end in / and are not files.
unzip -Z1 "$ZIP" 'system/*' \
    | sed 's|^system/||' \
    | grep -v '/$' \
    | grep -v '^addon\.d/' \
    | LC_ALL=C sort > "$tmp/in-zip"
printf '%s\n' "${COMMON_FILES[@]}" "${ARM64_FILES[@]}" "${EXCLUDED_FILES[@]}" \
    | LC_ALL=C sort > "$tmp/claimed"
if ! cmp -s "$tmp/in-zip" "$tmp/claimed"; then
    echo "the zip's file set no longer matches the upstream common/arm64 split:" >&2
    diff "$tmp/claimed" "$tmp/in-zip" >&2 || true
    die "refusing an incomplete import"
fi

rm -rf "$VENDOR/common/proprietary" "$VENDOR/arm64/proprietary"
extract_set "$VENDOR/common/proprietary" "${COMMON_FILES[@]}"
extract_set "$VENDOR/arm64/proprietary"  "${ARM64_FILES[@]}"

# --- provenance -------------------------------------------------------------
{
    echo "# MindTheGapps payload imported into vendor/gapps."
    echo "# source-zip: $(basename "$ZIP")"
    echo "# source-zip-sha256: $(sha256sum "$ZIP" | cut -d' ' -f1)"
    echo "# signer: $(cat "$tmp/signers")"
    echo "# certificate: $(basename "$CERT") sha256 $(sha256sum "$CERT" | cut -d' ' -f1)"
    echo "# imported-by: $(basename "${BASH_SOURCE[0]}")"
    echo
    ( cd "$VENDOR" && find common/proprietary arm64/proprietary -type f | LC_ALL=C sort \
        | xargs sha256sum )
} > "$VENDOR/payload.sha256"

echo "imported $(( ${#COMMON_FILES[@]} + ${#ARM64_FILES[@]} )) files into $VENDOR" \
     "(${#EXCLUDED_FILES[@]} deliberately excluded)"
