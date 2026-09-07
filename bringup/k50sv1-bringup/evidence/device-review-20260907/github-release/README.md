# First public Tier-3 release

The owner authorized GitHub publication of the three source repositories and
the final installed Tier-3 image set on 2026-09-07. Release
[v1.0.0](https://github.com/suddenBook/android_device_xsh_k50sv1_64_bsp/releases/tag/v1.0.0)
was published at 18:09:05 UTC and is the device repository's latest release.

| Repository | Published `main` / `v1.0.0` commit |
| --- | --- |
| [Device](https://github.com/suddenBook/android_device_xsh_k50sv1_64_bsp) | `5d3e1ea296d71fc2a6b976cd67a404b67447fecb` |
| [Vendor](https://github.com/suddenBook/android_vendor_xsh_k50sv1_64_bsp) | `fde9f3850b2460ae9b95673729ea158306c21863` |
| [Kernel](https://github.com/suddenBook/android_kernel_xsh_k50sv1_64_bsp) | `3c03dab12d0b92b6f4bb285ade60be1e59359345` |

Device reused the owner's existing repository and preserved its old
`lineage-17.1` branch. Vendor and kernel repositories were created with `gh`.
Device/vendor preserve their existing commit histories, including historical
signing material the owner explicitly allowed to remain public. The current
external Tier-3 private keyset was not added to these source trees.

The kernel's current source exported completely, but the original local Git
history contained missing blobs. One was recovered from the exact upstream
Git blob; traversal then found another missing object. The public repository
therefore starts from the complete current-source snapshot. Its Git tree
matches the local export exactly, including tracked files excluded by ordinary
Git ignore rules. Original local history remains preserved; the public README
credits the upstream and records the actual build revision. [Source proof](kernel-source.json).

The five images are `boot.img`, `recovery.img`, `system.img`, `vendor.img` and
`logo.img`. The four Android images match the final build24 stage byte-for-byte.
The logo contains the owner's HarmonyOS graphic; it matches the repaired image
read back from the handset, including its factory certificate records.

The other four assets are `SHA256SUMS`, `FLASHING.md`, `RELEASE-MANIFEST.json`
and `build-provenance.tar.xz`. The provenance archive retains all nine original
stage metadata files. The manifest separates actual build commits from the
publication commits that add README/build-support/flashing documentation.
The device support archive contains 26 byte-identical frozen build inputs;
additional Google/Huawei repositories remain external documented prerequisites.

All three public `main` branches and annotated tags match the intended local
commits. All nine uploaded asset sizes and GitHub SHA-256 digests match the
prepared release. An unauthenticated download of `SHA256SUMS` also matched the
local file. [Publication receipt](result.json).

Local prepared assets remain under
`work/.capture-staging/github-publish-20260907/release-v1.0.0/`. The original
four-image stage remains unchanged under
`work/.capture-staging/device-review-20260907/tier3-release-20260907/`.
The public kernel checkout is
`work/.capture-staging/github-publish-20260907/kernel/`.

The owner declined the proposed new Trebuchet upstream patch because
LineageOS 17.1 is frozen. That patch remains unapplied and is no longer an open
release task. Publication did not rebuild or reflash the handset; it remains
on final Tier 3 with ADB disabled.
