# Existing Android build inputs

The first Tier-3 release already contains these three local integrations:

| Project | Input | Preparation |
| --- | --- | --- |
| `vendor/lineage` | `fonts_customization.xml.patch` | Adds the HarmonyOS font family and aliases. |
| `vendor/lineage` | `apns-conf.xml.patch` | Gives seven existing China Mobile/Unicom WAP rows explicit non-IMS types. |
| `external/tinycompress` | `tinycompress-kernel-headers.patch` | Selects the device's audio header library for the existing source module. |

For Tinycompress, start from
`848ec3ad67cc414294d18776a2b4d644be95fd64`, apply its patch and commit it locally.
The checker compares the complete base-to-HEAD diff, so the local commit ID may
differ while the content remains verifiable. Keep that checkout clean.

PermissionController must have the clean tree of
`d90ff6d3d7d15775edfc853dd59bf1e7f3e06f25`; no device HOME fallback patch or
overlay is used.

After the support directory has been installed in the layout documented in
[BUILDING.md](../../BUILDING.md), run
`work/k50sv1-bringup/tools/apply-upstream-patches.sh` from the workspace. It
applies the font and APN patches to `vendor/lineage`, retaining exactly those
two expected working-tree changes. Its `--check` mode validates those inputs,
the Tinycompress integration and the HOME/launcher baseline without modifying
the Android tree. The build wrapper requires that check to pass.

The device's additional IMS APNs remain in `configs/apns-conf.xml` and use
Lineage's existing merge hook. The three inputs above are the release's existing
build dependencies. There is no new Trebuchet change or upstream submission in
this publication.
