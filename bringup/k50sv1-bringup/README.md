# k50sv1 LineageOS 17.1

Android 10 for the owner's MT6755 BSP handset. Read [HANDOFF](notes/HANDOFF.md)
for installed versus candidate state, [work items](workitems.md) for remaining
work, and [the current review](evidence/E-210.md) for measurements and changes.

The [document inventory](evidence/device-review-20260907/docs-inventory.tsv)
records the individual review of 166 E documents, eight notes and the work-item
list. Resolved narratives are deleted; original captures remain tied to their
actual build. Git preserves removed documentation.

| Reference | Purpose |
|---|---|
| [Hardware](notes/hardware-verification.md) | Physical observations, actual drivers and measurement limits |
| [Source providers](notes/aosp-source-migration.md) | Installed source replacements and remaining blob boundaries |
| [SELinux](notes/sepolicy.md) | Policy causes, tests and outstanding Enforcing coverage |
| [IMS/WFC](notes/vowifi-feasibility.md) | Carrier fixture, service dependencies and tier contract |
| [F2FS](notes/f2fs-feasibility.md) | Adopted storage configuration and retained fallback |
| [Setup](notes/setupwizard-feasibility.md) | SetupWizard product behavior |
| [Scope](scope.md) | Workspace, source priority and flash limits |

Work and trial repositories belong under `work/`. Commit logical changes; do
not push. Read tool headers for exact arguments. Every device-facing command
must select its adb/fastboot target explicitly.

| Operation | Tools |
|---|---|
| Full tier build | `tools/run-lineage-build.sh`; explicit `K50SV1_BUILD_TIER=1`, `2` or `3` |
| Stage and inspect | `stage-tier-images.sh <new-directory>`, `verify-stage-contract.sh` |
| OS flash and readback | `flash-tier-images.sh`, `verify-post-flash.sh` |
| Kernel-only iteration | `tools/kernel/flash-boot-images.sh`; reuse matching Android outputs only |
| Separate logo repair | `tools/flash-logo-image.sh <image> <fastboot-serial>` |
| Release signing | `prepare-tier3-keyset.sh`; fresh private `K50SV1_RELEASE_KEYS_DIR` outside the build's `PROJECT_ROOT` |
| Radio diagnosis | `check-volte-chain.sh`, `check-vowifi-chain.sh`; capture a 64 MiB radio ring first |
| Feature checks | [Runtime probes](tools/runtime-probes/README.md), `classify-avc-denials.sh` |
| Standby and thermal | `measure-standby.py`, `mtk-thermal-conf.py`; USB-connected data is not standby |
| Intermittent keypad | `capture-stuck-key-fault.sh`, `watch-stuck-key.sh`; capture before reboot |

A key directory under `work/` is accepted only when Git ignores the whole directory and tracks none of its files; Git metadata and bare repositories remain forbidden.

The full build wrapper produces its own source and image receipts. Do not
repurpose older receipts or label an incremental developer target a complete
four-image build. Stageable product builds remove orphan output files. The
[build19 record](evidence/E-209.md) retains the tested predecessor and its raw
readback evidence while this review's candidate is being completed.
