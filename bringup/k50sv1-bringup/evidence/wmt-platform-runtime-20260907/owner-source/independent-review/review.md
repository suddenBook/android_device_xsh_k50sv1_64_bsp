# Independent review: platform one-shot probe ownership

**PASS: no actionable findings.** Reviewed frozen commit
`fcd8380a217368b55a06d9913647913a14748267`, based on
`372a643505f6b0aab0b3adbd150ecb9d9291d8d9`, in
`wmt-platform-owner-kernel-work`. Production was read-only throughout this
review. The tree identifies itself as Linux 3.18.119.

The change at `drivers/base/platform.c:642` passes the caller's existing
`drv->driver.owner` to `__platform_driver_register()`. The previous macro
substituted `THIS_MODULE` from the built-in platform core. That value is NULL
(`include/linux/export.h:32`), even when a loadable caller supplied its own
owner. `drivers/base/Makefile:6` builds `platform.o` into the core. WMT supplies
`.owner = THIS_MODULE` at
`drivers/misc/mediatek/connectivity/source/common/common_main/platform/mtk_wcn_consys_hw.c:121`
and its required-probe branch calls `platform_driver_probe()` at line 693.
The new call preserves that explicit owner.

The exported function name and signature are unchanged. Registration still
sets the bus before returning any registration error. The helper still rejects
deferred probing, disables manual bind/unbind attributes, clears its temporary
probe callback, prevents later probes, and unregisters a successful registration
that bound no device. The change does not alter those return or cleanup paths.
It also applies when `platform_create_bundle()` calls this helper at
`drivers/base/platform.c:704`.

The resulting module relationship matches this tree's driver-core contracts:
`bus_add_driver()` passes the preserved owner to `module_add_driver()` at
`drivers/base/bus.c:698`. The latter uses the owner's module kobject to create
both module/driver links (`drivers/base/module.c:35`). Removal first detaches
the driver, then removes both links using the same owner
(`drivers/base/bus.c:751`, `drivers/base/module.c:74`). This path does not add
an unconditional module reference. It does not replace WMT's callback draining
or resource teardown, and the review does not claim an observed use-after-free.

## Other callers

The checked-in `callers.json` accounts for every matching call in tracked C
sources, excluding the platform core definition/internal forwarding call and
the host-test directory. An independent enumeration after stripping comments
matched all 162 call sites exactly:

| API | Call sites |
| --- | ---: |
| `platform_driver_probe()` | 63 |
| `module_platform_driver_probe()` | 96 |
| `platform_create_bundle()` | 3 |

These are call sites across all architectures, not 162 selected drivers in
the MT6755 image. Of them, 130 use static driver aggregates with explicit
`THIS_MODULE`; 31 use static aggregates whose omitted owner is zero; one ASUS
bundle call forwards the owner from its enclosing static driver. Both in-tree
ASUS callers explicitly supply their own `THIS_MODULE`
(`asus-nb-wmi.c:373`, `eeepc-wmi.c:256`), which `asus-wmi.c:1939` copies before
the bundle call. The `__refdata` aggregates in `sh_veu.c:1235` and
`sh_vou.c:1448` also explicitly initialize their owners. No caller remains
unresolved, and none supplies an uninitialized stack driver.

The 31 omitted owners retain NULL. The fix does not infer module ownership for
these callers, even if their configuration builds them as modules. Inspection
of those source files found no later assignment to the corresponding platform
driver's owner before the call. This is an existing limitation, not a new
regression. `platform_driver_register()` remains unchanged and continues to
capture `THIS_MODULE` at its ordinary caller's macro expansion site.

## Verification

- Independently reran the existing host runner against the exact frozen commit:
  **8/8 passed with ASan and UBSan**. The extracted production registration,
  probe, and unregister helpers retain module and NULL owners on success,
  registration failure, no-device rollback, retry, and distinct-owner cases.
- Verified all artifacts and source hashes in the original fixed and baseline
  runs. The pinned baseline passes the three NULL-owner cases and fails the five
  module-owner cases at the owner assertion: **3/8**, as expected. These expected
  failures establish the regression and are not candidate failures.
- Verified the retained actual ARM64 GCC 4.9 `-Werror` compile, source hash,
  configuration hash, saved command hash, and object hash. The object is ELF64
  little-endian AArch64. This review did not rerun that compilation.
- Verified all 162 caller file hashes, reviewed source hashes, exact parent and
  commit, and the clean worktree. `verify_review.py` records these checks and
  hashes the report and caller audit into `result.json`.

The host adapter models bus registration and list state; it does not run the
actual sysfs implementation or unload a real module. Full integration build
and a device check of the module links remain separate adoption evidence.
This review made no production changes and did not access ADB or the phone.
