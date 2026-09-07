# Release build support

The archive contains the build, signing, staging and verification tools used for
the first Tier-3 release. Its files are byte-identical to the build's recorded
support revision. [SOURCE.json](SOURCE.json) records the archive and file hashes. See
[BUILDING.md](../BUILDING.md) for the Android checkout and additional inputs.

Extract `k50sv1-build-support.tar.xz` into `workspace/work/k50sv1-bringup/`,
alongside `workspace/lineage-17.1/`. That layout is required for the scripts to
resolve the correct workspace. Keeping the support payload archived in the
device tree also avoids having its diagnostic strings treated as active device
configuration by the source checks. The `workspace/work` directory must be a clean Git repository because
the build receipt records its commit and tree.

The archive's `upstream/` directory holds the three existing font, APN and Tinycompress build inputs
already used by the released images. No additional Trebuchet patch is included.
See [upstream/README.md](upstream/README.md) for their preparation.

The support files do not include the Android source tree, Google/Huawei add-on
repositories, a host toolchain or release private keys. The published source
revisions and additional inputs must be prepared before invoking the wrapper.
Rebuilding with a different keyset produces different signatures and image
hashes from the release.

The optional hardware verification helpers retain their original assumptions:
set `ADB_BIN` and `FASTBOOT_BIN` to executables from one Android platform-tools
installation. Their default local paths are from the original build host.
`flash-tier-images.sh` consumes a complete, original four-image stage-contract
bundle; for the downloadable five-image release use [FLASHING.md](../FLASHING.md).
The evidence file here contains only hashes used to recognize a historical
pre-transition pstore, not a dump of device data.
