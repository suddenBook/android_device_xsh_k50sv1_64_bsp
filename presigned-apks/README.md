# Signed APK preservation on Android Q

Q's Make and Soong prebuilt rules can rewrite JNI/dex ZIP entries even for
`PRESIGNED` APKs, invalidating v2/v3 signatures. `K50CtsShimPrivPrebuilt` uses
`LOCAL_REPLACE_PREBUILT_APK_INSTALLED` to install the original APK unchanged,
while registering its two compressed JNI files beside the APK.

Google APK rules now belong to the generated `vendor/gapps` and
`vendor/google_webview` payloads. They use the same unchanged-copy path.
Aligned uncompressed JNI loads directly from `APK!/lib/<ABI>` through Q's
`LoadedApk.makePaths`; APKs requesting extraction need separate native files
because Q skips extraction for unupdated system apps. The importer derives
that inventory from each APK's manifest and ZIP instead of naming old libraries.

Google SetupWizard is excluded. LineageSetupWizard remains installed, and the
Google app's former `K50Velvet` wrapper has been removed.

Build verification must compare installed APK bytes/signatures with the inputs
and confirm compressed JNI outputs are in the image. On a clean-data boot,
check package scanning, the Google WebView provider, app native loading and the
Lineage setup flow. Source inspection alone does not establish runtime success.

References: [Q prebuilt rules](https://github.com/aosp-mirror/platform_build/blob/android-10.0.0_r47/core/app_prebuilt_internal.mk),
[Q app native paths](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-10.0.0_r47/core/java/android/app/LoadedApk.java),
[Chromium system integration](https://chromium.googlesource.com/chromium/src/+/main/android_webview/docs/aosp-system-integration.md).
