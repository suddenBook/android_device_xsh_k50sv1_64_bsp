# Signed APK preservation on Android Q

The Q Make prebuilt rule uncompresses embedded JNI and privileged-app dex even
for `PRESIGNED` inputs. Q Soong `android_app_import` also rewrites those entries.
Those ZIP changes invalidate the supplied APK v2/v3 signatures. These three
device-owned wrappers use Q's supported `LOCAL_REPLACE_PREBUILT_APK_INSTALLED`
copy branch so the installed APK remains byte-for-byte identical to its source.
No APK or native-library copy is stored in this device repository.

| Device module | Overrides | Native files beside the APK |
| --- | --- | --- |
| `K50CtsShimPrivPrebuilt` | `CtsShimPrivPrebuilt` | `lib/arm64/libshim_jni.so`, `lib/arm/libshim_jni.so` |
| `K50SetupWizardPrebuilt` | `SetupWizardPrebuilt`, `Provision` | `lib/arm64/libbarhopper.so` |
| `K50Velvet` | `Velvet` | Ten files in `lib/arm64`, one placeholder in `lib/arm` |

All retain privileged installation and disabled dexpreopt from their original
modules. Module names also determine installed APK basenames, directories and
`apkcerts.txt` names; the old names are not forced back with a custom stem.
Android package names and certificate identities inside the APKs are unchanged.
The Google wrappers and product entries are conditional on the existing
`vendor/gapps/arm64/arm64-vendor.mk` payload. They do not alter the product's
separate policy for requiring that import.

## Native loading is part of the fix

`PackageManagerService.derivePackageAbi` in this Q tree explicitly disables
native extraction for an unupdated system app. Its cluster-install path points
`nativeLibraryDir` at the APK directory's `lib/<instruction-set>` directory.
`LoadedApk.makePaths` adds that directory to the native search path. Leaving the
signed, compressed JNI entries only inside the APK would therefore be incomplete.

Q `install_jni_libs_internal.mk` recognizes `LOCAL_PREBUILT_JNI_LIBS` entries
starting with `@`, but does not extract those entries into installed files. Its
separate-file branch installs external prebuilts beside the app and adds them
to `ALL_MODULES.<module>.INSTALLED`. The helper here uses the same per-app path
and accounting, with each native output depending directly on the original APK
and the installed APK depending on every native output. `unzip -p` reads the
signed archive; it does not rewrite it. Failed extraction fails the build and
removes its temporary output.

The CTS shim and Velvet declare `multiArch`, so entries from both their
`arm64-v8a` and `armeabi-v7a` directories are installed. SetupWizard contains only
ARM64 JNI. Keep the explicit 14-entry inventory in sync with the source APKs.

Velvet's `lib/armeabi-v7a/libmultiarch_dummy.so` is an existing exception to the
directory's implied ELF architecture: it is ELF64/AArch64, SHA-256
`cab80b90a700908c461af1fa2970ce53617c815e307f15520ac693d1dfd5a20e`.
Its only defined function export is `doNotUseDummyMethodForDummyFile()`; it has
no JNI exports, no direct name reference in any of the five DEX files, and no
`DT_NEEDED` reference from the ten real ARM64 libraries. This supports treating
it as a placeholder, not claiming an ARM32 load test. Preserve its original
entry and bytes instead of replacing it with a different binary. The 13 other
native files have ELF architectures matching their installed directories.

Velvet's manifest has `multiArch=true` and no `use32bitAbi` override. Q defaults
that override to false and chooses the supported ARM64 ABI as primary when both
ABI directories are present. These rules therefore preserve `arm64-v8a` as the
primary ABI and the original ZIP's secondary-ABI presence; verify the derived
values again on the clean-data boot.

Inspected source SHA-256 values:

```text
32434dbb4bbc03a50c0e114d27c76760173364b070f1898326ee8e6134266731  frameworks/base/packages/CtsShim/apk/arm/CtsShimPriv.apk
40b0121b415e606d484d18dfd2106a2bbd161ef0f8070e9a7c60b1b19244b24f  vendor/gapps/arm64/proprietary/priv-app/SetupWizardPrebuilt/SetupWizardPrebuilt.apk
d91b7eea0897a730922d029ebc5d9e61d5f1102e0ae0a713a9d4cc9b613b23d5  vendor/gapps/arm64/proprietary/priv-app/Velvet/Velvet.apk
```

The implementation follows [Q's replacement copy branch](https://github.com/aosp-mirror/platform_build/blob/android-10.0.0_r47/core/app_prebuilt_internal.mk),
[Q's JNI installation rules](https://github.com/aosp-mirror/platform_build/blob/android-10.0.0_r47/core/install_jni_libs_internal.mk),
and [Q PackageManager's ABI and native paths](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-10.0.0_r47/services/core/java/com/android/server/pm/PackageManagerService.java).
APK container changes are covered by the [v2 signing scheme](https://source.android.com/docs/security/features/apksigning/v2).

## Required graph, build and runtime checks

1. Build the three `K50*` modules and inspect the generated graph: replacement
   APK rules must be plain copies of the source paths, all 14 JNI extraction
   targets must be reachable, and the product-installed set must exclude the
   overridden originals and `Provision`. Check `apkcerts.txt` records each new
   APK basename as `PRESIGNED` and each app remains under `system/priv-app`.
2. Compare each installed APK to its source and verify its signature. Compare
   every installed native file to the corresponding ZIP member, including both
   ABI directories and the documented Velvet placeholder. Confirm a clean full
   image contains those files; old output directories
   from a previous build are not evidence of the final installed set.
3. On a clean-data boot, verify all three packages are scanned without signing
   errors, their native-library directories and ABIs match the files, and the
   SetupWizard/Google app flows load JNI without `UnsatisfiedLinkError`. The CTS
   shim's update/signing checks remain the separate CTS compatibility test.

Only source inspection and archive/manifest inventory were performed while
adding these rules. The parent build workflow performs the targeted and clean
full builds plus runtime checks.
