# Niagara Launcher preinstall

The user-supplied `Niagara_Launcher_v1.16.27-release.apk` is installed as
`/system/priv-app/NiagaraLauncher/NiagaraLauncher.apk`. The source APK is tracked
here unchanged; `SHA256SUMS` records its exact bytes.
The device's one-level Make discovery includes `apps/Android.mk`, which then
includes this application's module. The first full graph generation exposed
the missing intermediate makefile; the source integration now supplies it.

| Field | Verified value |
| --- | --- |
| Package | `bitpit.launcher` |
| Version | `1.16.27`, version code `1633` |
| Minimum / target SDK | `26` / `36`; device platform is `29` |
| HOME activity | `bitpit.launcher.ui.HomeActivity` |
| Native ABIs | `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64` |
| Signature | APK Signature Scheme v2, original RSA 2048 signer |
| Signer certificate SHA-256 | `ccb918002c40334b416899258de4f730a36c5d38821b3cb6fcb8c15a4b8198ed` |
| APK SHA-256 | `9bd8a1998eac9a972599a33b6d22f490d98061735bf5e49b731844ead17780b2` |

`LOCAL_CERTIFICATE := PRESIGNED` retains the signing identity in build metadata.
`LOCAL_REPLACE_PREBUILT_APK_INSTALLED` selects the unchanged-copy rule in
`build/make/core/app_prebuilt_internal.mk`. Its ordinary prebuilt path can
rewrite ZIP entries when uncompressing JNI or aligning the package, invalidating
the v2 signature. Dex preoptimization is disabled for this prebuilt.

The APK sets `extractNativeLibs=false`. All eight native-library entries are
stored without compression and aligned to 4096-byte boundaries, so they load
directly from the APK. The two ARM64 libraries depend only on Q's `libc.so`,
`libm.so` and `libdl.so`.

## Permissions on Android Q

The allowlist and APK both install on the system partition. Comparing the
APK's requested permissions, including `maxSdkVersion`, with
`frameworks/base/core/res/AndroidManifest.xml` gives these complete sets:

| Mechanism | Permissions |
| --- | --- |
| Privileged allowlist | `BIND_APPWIDGET`, `PACKAGE_USAGE_STATS` |
| Default runtime grants, `fixed=false` | `ACCESS_COARSE_LOCATION`, `READ_CALENDAR`, `READ_CONTACTS` |

The runtime permissions remain revocable by the user. Q's
`DefaultPermissionGrantPolicy` reads the exception file from
`/system/etc/default-permissions` for installed system apps that support runtime
permissions. Normal permissions are handled by PackageManager automatically.
`WRITE_EXTERNAL_STORAGE` has `maxSdkVersion=28`, so it is inapplicable on Q.

Q's `UsageStatsService.BinderService.hasPermission()` accepts the privileged
`PACKAGE_USAGE_STATS` grant when the usage AppOp is `MODE_DEFAULT`; an explicit
user AppOp denial remains effective.

Notification-listener access, the accessibility service and Do Not Disturb
access use separate Settings controls. `BIND_NOTIFICATION_LISTENER_SERVICE` and
`BIND_ACCESSIBILITY_SERVICE` guard binding to Niagara's services; they are not
permissions requested by this APK. `ACCESS_NOTIFICATION_POLICY` is normal but
does not itself enable Do Not Disturb access. No secure-setting or AppOp
overrides are installed.

Permissions introduced after Q, such as `POST_NOTIFICATIONS`,
`BLUETOOTH_CONNECT`, `QUERY_ALL_PACKAGES`, `ACCESS_HIDDEN_PROFILES` and the
AdServices permissions, have no Q framework grant to configure. Google service
and billing permissions depend on their declaring packages. Niagara's own
`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` uses its own signature. These do not
belong in the framework privileged allowlist.

## Initial home app

`configs/preferred-apps-trebuchet.xml` installs under
`/system/etc/preferred-apps`, the directory read by Q's
`Settings.applyDefaultPreferredAppsLPw()`. Its `item/filter/action/cat` syntax
matches `PreferredComponent`, `PreferredActivity` and `IntentFilter` parsing.
PackageManager queries the actual installed candidates to populate the
preference's match set.

The selected component is
`com.android.launcher3/com.android.launcher3.lineage.LineageLauncher`, from the
base manifest merged into the inherited `TrebuchetQuickStep` module. The default
is initialized on fresh data. Q does not migrate this preference into the HOME
role: actual clean-data testing showed the role's priority fallback replacing it
with SetupWizard, then returning no winner after setup because both launchers
have equal priority.

The PermissionController overlay therefore supplies
`config_defaultHome=com.android.launcher3`. It requires the paired local
PermissionController source patch recorded in the bring-up repository's
`upstream/permissioncontroller-default-home.patch`. That patch selects the
configured package from eligible HOME candidates when no role holder exists.
Existing qualified role holders are retained by the normal role controller.

This is a regular preferred activity. The user can choose Niagara later in
Settings and retain that choice after reboot. Existing user defaults are
preserved on an ordinary upgrade; this configuration does not force Trebuchet
on every boot.

## Verification

Host checks performed on 2026-09-05:

- Exact source copy and `sha256sum -c SHA256SUMS` passed.
- This tree's Q `aapt` and `aapt2` read the package and SDK metadata successfully.
- Q's `apksigner.jar` verified the signature for API 29, as did SDK 37's
  `apksigner`; Q and SDK 37 `zipalign -c -p 4` passed.
- ZIP CRCs, native compression/alignment, ARM64 ELF headers and dependencies
  passed.
- XML parsing and exact requested-permission comparisons against the local Q
  framework passed, including runtime revocability and the storage SDK limit.
- The preferred component was checked against both actual Trebuchet manifests;
  module settings and all three system copy destinations were checked.

After the full build, compare the installed APK against this checksum and
verify its signature again. Fresh-data device verification is still required:

1. Complete setup and confirm HOME opens Trebuchet without a launcher chooser.
2. Confirm `pm path bitpit.launcher` points to the system privileged app and
   `dumpsys package bitpit.launcher` shows both privileged and all three runtime
   grants.
3. Launch Niagara and verify widgets and usage statistics work; confirm the
   separate special-access controls behave normally.
4. Choose Niagara in Settings, reboot and confirm it remains the home app.
5. Revoke a runtime permission in Settings and confirm it remains revoked after
   reboot.

A read-only resolver check after setup is:

```sh
adb shell cmd package resolve-activity --brief --user 0 \
    -a android.intent.action.MAIN -c android.intent.category.HOME \
    -c android.intent.category.DEFAULT
```

When replacing the APK, repeat the manifest/permission, signature and native
checks before updating the checksum or allowlists. A successful host check does
not establish application runtime compatibility with Android Q.
