# PRESIGNED APK release repair

Build22 completed its clean Tier-3 compilation but failed release verification;
it produced no flashable release and was not installed. Auditing all 16 installed
PRESIGNED APKs found two separate defects:

- The signer gate incorrectly rejected the two official AOSP CTS shim fixtures.
  Q's [CTS signature test](https://android.googlesource.com/platform/cts/+/refs/tags/android-10.0.0_r47/tests/tests/security/src/android/security/cts/PackageSignatureTest.java#117)
  explicitly permits their test certificate. Re-signing breaks the privileged
  shim's signature and exact-hash update contract. Both source APKs match the
  files downloaded from Google's `android-10.0.0_r47` tag byte-for-byte.
- Q's Make/Soong prebuilt processing uncompressed JNI/DEX entries and stripped
  v2/v3 signatures from CtsShimPrivPrebuilt, SetupWizardPrebuilt and Velvet.
  Their original source APKs verify; the installed build22 copies do not.
  The other 13 installed APKs equal their source bytes and verify.

Device `a76fb0b` replaces only the three affected module declarations with
device-owned `K50*` wrappers. Q's replacement-copy branch preserves each APK;
14 JNI files are extracted separately beside the APK and included in its build
dependencies and installed-file metadata. The original modules are overridden.
This is necessary because Q does not extract JNI for bundled system apps.
Velvet's signed `armeabi-v7a/libmultiarch_dummy.so` is actually ELF64/AArch64;
its original bytes are preserved, without claiming a working ARM32 library.
Google's real libraries and selected primary ABI remain ARM64. Upstream source
and all original APKs are unchanged. The targeted user-variant module build
passes: all three installed APKs equal their sources and verify, and all 14 JNI
files equal their ZIP members. The generated system-image graph contains these
17 files, excludes the overridden app paths, and uses plain-copy APK rules.
[Module results](module-results.json) bind those checks. This diagnostic build
is followed by a complete clean release build; no module output was flashed.

The gate now permits the CTS identity only with the two explicit installed
paths and exact official APK hashes. It still verifies the actual signatures,
requires the sole audited active certificate/SPKI, and rejects other development
or revoked keys, including reissued certificates and signing history. Package
names alone grant no exception. The privileged wrapper's path is
`SYSTEM/priv-app/K50CtsShimPrivPrebuilt/K50CtsShimPrivPrebuilt.apk`.

The extended signer fixture suite passes, including mixed ordinary/shim inputs,
wrong paths, swapped shims, altered bytes and another testkey APK claiming the
shim exception. Independent review found no blocker. This is host evidence;
final target-files verification and runtime checks remain required.

Private full inputs/reports are in
`work/.capture-staging/device-review-20260907/presigned-apk-audit/` and
`policy-review/cts-shim-audit/`. The compact [inventory](inventory.json) binds
the failed build and verified source identities. No private keys or APKs are
included here.
