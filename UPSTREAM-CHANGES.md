# What this device changes in LineageOS 17.1

Everything needed to reproduce the tree this device builds from, on top of a
plain `lineage-17.1` manifest. LineageOS 17.1 is no longer updated, so the
upstream side of this is fixed and will not drift.

Scope was measured, not recalled: `repo forall` compared every one of the 652
manifest projects against its `m/lineage-17.1` ref and its working tree.
**Three** projects differ. The other 649 are untouched, and nothing here
patches the platform, the frameworks or the build system.

## 1. Projects the manifest does not contain

`repo sync` does not fetch any of these; `.repo/local_manifests/` starts empty.
Three are published, two are not.

| Path | Source |
| --- | --- |
| `device/xsh/k50sv1_64_bsp` | `github.com/suddenBook/android_device_xsh_k50sv1_64_bsp` @ `lineage-17.1` |
| `vendor/xsh/k50sv1_64_bsp` | `github.com/suddenBook/android_vendor_xsh_k50sv1_64_bsp` @ `lineage-17.1` |
| `kernel/xsh/k50sv1_64_bsp` | `github.com/suddenBook/android_kernel_xsh_k50sv1_64_bsp` @ `lineage-17.1` |
| `vendor/huawei/hms` | **not published** — 219 MB, HMS Core + AppGallery payload |
| `vendor/gapps` | **not published** — 388 MB, MindTheGapps payload |

Save as `.repo/local_manifests/k50sv1_64_bsp.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="suddenBook" fetch="https://github.com/suddenBook" />
  <project path="device/xsh/k50sv1_64_bsp" name="android_device_xsh_k50sv1_64_bsp"
           remote="suddenBook" revision="lineage-17.1" />
  <project path="vendor/xsh/k50sv1_64_bsp" name="android_vendor_xsh_k50sv1_64_bsp"
           remote="suddenBook" revision="lineage-17.1" />
  <project path="kernel/xsh/k50sv1_64_bsp" name="android_kernel_xsh_k50sv1_64_bsp"
           remote="suddenBook" revision="lineage-17.1" />
</manifest>
```

`vendor/huawei/hms` and `vendor/gapps` have to be supplied separately.
`lineage_k50sv1_64_bsp.mk` calls `$(error ...)` for each if it is missing, so a
build without them fails immediately and by name rather than quietly producing
an image without the payload. `vendor/gapps` is rebuilt from a MindTheGapps
release zip by `bringup/k50sv1-bringup/tools/import-mindthegapps.sh`, which
takes the zip as an argument and does not download it:

    import-mindthegapps.sh <MindTheGapps-*.zip> <release.x509.pem> [<lineage root>]

The shipped payload came from `MindTheGapps-10.0.0-arm64-20230922_081111.zip`
with `vendor/gapps` layout pinned to `gitlab.com/MindTheGapps/vendor_gapps`
@ `59bcb4c6d5d86e423afe975044e40f44bece99fc`.

## 2. Modified upstream projects

### `external/tinycompress` — 1 commit

`5f2b0e5 Use only the device audio UAPI when building Tinycompress`

`Android.bp`, one line:

```diff
-        "generated_kernel_headers",
+        "k50_tinycompress_kernel_headers",
```

The generic `generated_kernel_headers` pulls the wrong `sound/compress_*.h` for
this kernel. `k50_tinycompress_kernel_headers` is defined by
`device/xsh/k50sv1_64_bsp/tinycompress/` and points at this device's own audio
UAPI, which `tools/check-tinycompress-kernel-headers.py` verifies.

### `vendor/lineage` — 2 files, uncommitted in the working tree

Both are edits to prebuilts, left uncommitted upstream-side. Reapply by hand.

**`prebuilt/common/etc/apns-conf.xml`** — adds `type="default,supl"` to four
Chinese-carrier WAP entries that upstream ships with no `type` attribute at
all (China Mobile `cmwap` under MCC/MNC 460/00 and 460/02, China Unicom
`3gwap` and `uniwap` under 460/01). An APN row with no `type` is not offered
as a data APN, so those carriers had no usable WAP fallback.

**`prebuilt/common/etc/fonts_customization.xml`** — appends the HarmonyOS Sans
family.

This one has to live in `vendor/lineage` and *cannot* move into the device
tree, which is worth stating because it looks like device-tree material:
`SystemFonts.java:313` reads exactly one hardcoded path,
`/product/etc/fonts_customization.xml`, and `base_rules.mk:510` emits an
install rule for every parsed module, so a second module writing that same
path is a ckati *"overriding commands for target"* error rather than an
override. The two halves that *are* device-tree material stay there:

* the `.ttf` files, installed to `/product/fonts` by
  `device/xsh/k50sv1_64_bsp/fonts/Android.mk`
* the Styles entry selecting the family,
  `device/xsh/k50sv1_64_bsp/rro/HarmonyOSSansFont`

### `packages/apps/PermissionController` — no net change

Carries two commits, `aabed6d9 Honor a configured HOME fallback ...` and
`494e742a Revert "Honor a configured HOME fallback ..."`. They cancel:
`git diff m/lineage-17.1..HEAD` is empty and the tree is byte-identical to
upstream. Listed here only so a future audit that spots the two commits does
not go looking for a change that is not there. **Nothing to reproduce.**

## 3. Reproducing

```sh
repo init -u https://github.com/LineageOS/android.git -b lineage-17.1
mkdir -p .repo/local_manifests
# write .repo/local_manifests/k50sv1_64_bsp.xml from section 1
repo sync -c -j8

# section 2, external/tinycompress
sed -i 's/"generated_kernel_headers"/"k50_tinycompress_kernel_headers"/' \
    external/tinycompress/Android.bp

# section 2, vendor/lineage: reapply both prebuilt edits by hand

# payloads
work/k50sv1-bringup/tools/import-mindthegapps.sh <zip> <release.x509.pem>
# supply vendor/huawei/hms separately

# build (see device/xsh/k50sv1_64_bsp/bringup/README.md for the keyset)
K50SV1_BUILD_TIER=3 work/k50sv1-bringup/tools/run-lineage-build.sh
```
