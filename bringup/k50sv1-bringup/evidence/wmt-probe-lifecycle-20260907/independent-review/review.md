Reviewed the MT6755 probe change from `0b3f7a10f39bff7c1e94d21956e88d0da797fa8e`
to the clean integrated candidate `372a643505f6b0aab0b3adbd150ecb9d9291d8d9`,
including its existing platform initialization and callback barrier. The probe
production change matches standalone commit
`da0a099216d01913e1f57ee691eadafacbefa5c5`.

PASS for the requested MT6755 OF/CCF/nonlegacy-regulator scope: no finding at
confidence 80 or higher. No production file or device was changed.

| Independent validation | Result |
| --- | --- |
| Existing probe resource/failure suite on integrated candidate, ASan/UBSan/leak checks | 54/54 |
| Added framework, resource boundary and platform/barrier/probe composition cases, ASan/UBSan | 10/10 |
| Added thermal/assert/clock teardown compositions, TSan | 3/3 |
| Same three compositions with only the builtin bridge replaced by 54b's old implementation | 0/3, expected semantic assertions |

The added cases exercise clock-default failure before the WMT callback, deferred
PM-domain attachment, the local framework's allowed non-defer attach error,
`-ENODEV` from a required regulator, the exact valid coredump-region size,
duplicate probe without disturbing the existing binding, and a real
`wmt_plat_init()` failure that must leave callbacks unpublished and wake resources
released. Every case then completes a fresh successful platform init/deinit.

The three concurrent cases execute complete production functions through
`wmt_plat_init()`, module-stub registration, builtin dispatch, platform callback
dispatch, `wmt_plat_deinit()`, stub unregistration, bridge draining, hardware
unregistration, `mtk_wmt_remove()` and devres release. A host payload holds one
callback while teardown closes admission. The check requires all acquired
MT6755 resources to remain live, rejects all new bridge callbacks, then releases
the held callback and requires cleanup to complete. Thermal and assertion
payloads are typed backend substitutes; the clock case holds the STEP backend
of the actual clock-dump function. These tests do not run thermal firmware
commands or real register I/O.

Each old-bridge control compiles successfully and aborts at the independent
resource ledger with `devres release while callback is active` (SIGABRT, -6).
There are no control compile failures, timeouts or ambiguous sanitizer startup
failures. This isolates the barrier's contribution without replacing the probe
or platform implementation.

The source review confirmed these points:

- Local 3.18 `really_probe()` hides callback failure from driver registration,
  releases devres after failed probe, and releases devres after remove during
  detach. `platform_driver_probe()` tests for a real binding, unregisters an
  unbound driver, suppresses bind/unbind attributes and rejects later probes.
  The recorded WMT result preserves errors from an entered callback. Failure
  before entry remains `-ENODEV`, as the patch documents; a driver-group rollback
  keeps its own error and must not be unregistered a second time.
- MT6755 mappings use managed, nonexclusive acquisition, preserving the shared
  TOPCKGEN/SPM behavior. Clock and regulator handles are published only after
  successful acquisition. Checked failure and remove clear the retained EMI
  pointer, register bases, clock/regulator handles, pinctrl and GPIO globals
  before framework devres release. GPS node references are paired. Duplicate
  hardware init and repeated deinit preserve ownership.
- The local `drivers/of/address.c:866` implementation of `of_iomap()` has no
  separate `IORESOURCE_MEM` check: it translates the resource then calls
  `ioremap()`. The default OF bus returns `IORESOURCE_MEM` at line 91. The actual
  `mt6755.dts` device is on a simple bus and has the four expected memory ranges.
  Consequently this change did not omit a check present in this tree, and a
  hypothetical PCI I/O resource is not a target blocker.
- Successful platform initialization publishes callbacks after hardware init.
  Platform deinit drains the bridge before hardware unregister; the integrated
  outer/library teardown also drains it before releasing their earlier
  resources. The resource lifetime improvement therefore composes with the
  existing callback protocol.

`review.json` binds the source revision, clean state, source/context hashes,
source excerpts, test outputs and review scripts. `run_extended_review.py`
creates a new fixture from the checked-out production sources and the existing
probe fixture, and changes only host adapters/oracles. Complete production
function bodies and the whole builtin bridge section remain unchanged.

For reproduction, run `run_extended_review.py --kernel <candidate> --output
<new-directory>`; select the three `callback-*-before-devres` cases with repeated
`--case` arguments and `--sanitizer thread` for the concurrent check. The negative
control adds `--bridge-revision 54bdf406ee9963e3b926d8f19fc2bb4c1a3975eb`.

This is a review of a fixed, already enumerated MT6755 device and serialized WMT
construction/destruction. Automatic retry after a deferred fixed-device probe,
hot unplug, simultaneous owner initialization, runtime power-off sequencing,
EMI-MPU restoration and optional callbacks/private resources used by other ICs
are outside this evidence. The target has no runtime-PM-storage/dedicated-log/
DEVAPC/reset-control ops and hibernation is disabled. Root independently owns
the integrated platform/callback regressions and seven ARM64 compilation checks;
they were not repeated or claimed as this review's work.
