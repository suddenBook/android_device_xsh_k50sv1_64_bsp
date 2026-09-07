# Building LineageOS 17.1 for k50sv1_64_bsp

The release is built from Android 10 / LineageOS 17.1, the three device
repositories, additional Google/Huawei application repositories and the
published build-support archive. A compatible Android checkout and those
additional application inputs are required before the commands below can build
the product. Cloning the three device repositories alone is insufficient.

## Required inputs

Use a Linux Android build host with the Android Q host dependencies and bundled
toolchains. The support scripts also require Bash, Git, Python 3, Java/Javac,
OpenSSL, XML tools (`xmllint`), zip/unzip, xz, standard GNU utilities and
`unpack_bootimg` on `PATH`. The Android checkout must retain its bundled release
Python, JDK, compiler prebuilts and APK verifier; the wrapper checks selected
tool hashes and does not silently substitute host versions.

| Input | Required location / condition |
| --- | --- |
| LineageOS 17.1 | `workspace/lineage-17.1`, a complete `repo` checkout with its launcher and manifest metadata |
| Device, vendor and kernel repositories | Paths listed below; each must be a clean Git checkout |
| MindTheGapps for Android 10 arm64 | Prepared, clean Git repository at `lineage-17.1/vendor/gapps`, including `arm64/arm64-vendor.mk` and its referenced payloads |
| Google WebView | Prepared, clean Git repository at `lineage-17.1/vendor/google_webview` |
| Huawei Mobile Services | Prepared, clean Git repository at `lineage-17.1/vendor/huawei/hms`, including `products/huawei.mk` and its referenced payloads |
| Build support | Published archive unpacked into the independent Git repository at `workspace/work` as shown below |
| Tier-3 signing keys | A new external keyset outside the workspace and every Git checkout; see [security/README.md](security/README.md) |

The Google/Huawei application repositories and their complete import recipes
are not included in these three repositories or the support archive. Obtain and
prepare those inputs separately; the product and source receipt require all
three repositories. The tested Google payload baseline used
`MindTheGapps-10.0.0-arm64-20230922_081111.zip`. An arbitrary GApps package or an
empty placeholder repository is not an equivalent input.

The release's `K50SV1-BUILD-SOURCE-STATE` and
`K50SV1-ANDROID-REPO-MANIFEST.xml` record the source revisions used for its
images; both are included in the release asset `build-provenance.tar.xz`.
Use those records when comparing a rebuild with the published release;
the current `main` branches also contain publication documentation. Support
file provenance and hashes are recorded in
[build-support/SOURCE.json](build-support/SOURCE.json).

## Workspace layout

Prepare a fresh workspace with these two sibling directories:

```text
workspace/
├── lineage-17.1/                         # Android repo checkout
│   ├── device/xsh/k50sv1_64_bsp/          # device repository
│   ├── vendor/xsh/k50sv1_64_bsp/          # proprietary vendor repository
│   ├── kernel/xsh/k50sv1_64_bsp/          # kernel repository
│   ├── vendor/gapps/                     # separately prepared Git repository
│   ├── vendor/google_webview/            # separately prepared Git repository
│   └── vendor/huawei/hms/                # separately prepared Git repository
└── work/                                # independent, clean Git repository
    └── k50sv1-bringup/
        ├── tools/
        ├── upstream/
        └── evidence/
```

From `workspace/`, with a prepared Android checkout and empty device locations:

```sh
git clone --branch main https://github.com/suddenBook/android_device_xsh_k50sv1_64_bsp.git lineage-17.1/device/xsh/k50sv1_64_bsp
git clone --branch main https://github.com/suddenBook/android_vendor_xsh_k50sv1_64_bsp.git lineage-17.1/vendor/xsh/k50sv1_64_bsp
git clone --branch main https://github.com/suddenBook/android_kernel_xsh_k50sv1_64_bsp.git lineage-17.1/kernel/xsh/k50sv1_64_bsp

mkdir -p work/k50sv1-bringup
tar -xJf lineage-17.1/device/xsh/k50sv1_64_bsp/build-support/k50sv1-build-support.tar.xz -C work/k50sv1-bringup
```

The scripts derive the Android checkout path from their own location. Run the
installed copy under `work/k50sv1-bringup/tools/`. Initialize the new `work`
repository and commit its support inputs before building:

```sh
cat > work/.gitignore <<'EOF'
logs/
out/
.capture-staging/
__pycache__/
*.py[cod]
EOF
git -C work init -b main
git -C work add .gitignore k50sv1-bringup
git -C work commit -m "Import published k50sv1 build support"
```

Keep logs and generated files outside tracked input paths. The wrapper captures
the seven owned repositories and every Android `repo` project before and after
the build. Uncommitted changes are rejected except for the two expected
`vendor/lineage` changes described next.

## Prepare the existing Android integrations

Read [build-support/upstream/README.md](build-support/upstream/README.md). The
archive supplies the published font, APN and Tinycompress patches. On a fresh, clean Tinycompress
checkout, create its required local commit from the documented base:

```sh
git -C lineage-17.1/external/tinycompress checkout -b k50sv1-17.1 848ec3ad67cc414294d18776a2b4d644be95fd64
git -C lineage-17.1/external/tinycompress apply "$PWD/work/k50sv1-bringup/upstream/tinycompress-kernel-headers.patch"
git -C lineage-17.1/external/tinycompress add Android.bp
git -C lineage-17.1/external/tinycompress commit -m "Use device audio kernel headers"
```

The checker validates the complete base-to-HEAD diff, so an independently made
commit can have a different ID while retaining the required content.
PermissionController must have the clean tree of
`d90ff6d3d7d15775edfc853dd59bf1e7f3e06f25`. No additional Trebuchet or HOME
fallback patch is part of this release.

Apply and check the font and APN integrations from `workspace/`:

```sh
work/k50sv1-bringup/tools/apply-upstream-patches.sh
work/k50sv1-bringup/tools/apply-upstream-patches.sh --check
```

These retain exactly two expected modified files in `vendor/lineage`.
Tinycompress is checked by this tool but must already have been prepared and
committed as above. A later `repo sync` can remove the expected integrations;
prepare and check them again before building.

## Build Tier 3

Prepare the six distinct external certificate/key pairs documented in
[security/README.md](security/README.md). The wrapper validates their ownership,
permissions, pairing and separation from revoked/development keys. The current
release's private keys are not supplied.

Run from `workspace/`:

```sh
K50SV1_BUILD_TIER=3 \
K50SV1_RELEASE_KEYS_DIR=/absolute/path/to/your/external-release-keys \
K50_BUILD_JOBS=16 \
    work/k50sv1-bringup/tools/run-lineage-build.sh
```

Choose `K50_BUILD_JOBS` for the host; the wrapper defaults to 32. It selects
`lineage_k50sv1_64_bsp-user` internally. Leave `OUT_DIR`, `OUT_DIR_COMMON_BASE`
and Android identity override variables unset, and do not pass extra build
targets to Tier 3.

**Tier 3 requires a clean build and deletes the entire generated
`lineage-17.1/out` directory before compilation.** Save any older build outputs
elsewhere first. `K50SV1_CLEAN_BUILD=0` is rejected for this tier.

The pipeline builds target-files as a signing intermediate, re-signs and checks
the release contents, verifies kernel/module ABI compatibility, then stages
`boot.img`, `recovery.img`, `system.img` and `vendor.img` with `SHA256SUMS` and
provenance records. The final directory is printed as
`Tier-3 signed partition images: ...`; it defaults beneath
`lineage-17.1/out/release/`. `K50SV1_RELEASE_OUTPUT_ROOT` can select another
release destination.

The builder does not produce an OTA ZIP or the release's separate `logo.img`.
Rebuilding with your own keys changes signatures and image hashes. The
downloadable release includes the independently verified logo image; use
[FLASHING.md](FLASHING.md) for installation of that release.

## Diagnostic builds

For bring-up only, the same prepared inputs support:

```sh
K50SV1_BUILD_TIER=1 work/k50sv1-bringup/tools/run-lineage-build.sh
K50SV1_BUILD_TIER=2 work/k50sv1-bringup/tools/run-lineage-build.sh
```

Both are `userdebug` builds with unauthenticated root ADB; Tier 1 is permissive
and Tier 2 is enforcing. They build the four Android partition images directly
with development signing. Keep these configurations separate from the Tier-3
release posture described in [README.md](README.md).
