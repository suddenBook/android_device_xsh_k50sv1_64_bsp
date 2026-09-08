# HICA default-write repair

The shipped `libpowerhal.so` parses `Prefix=10^` as `10 `, but its
`loadConTable()` startup path calls `set_value(path, DefaultValue)` without
that prefix. The HICA entry therefore writes `1` to `/proc/ppm/policy_status`,
whose kernel interface requires a policy number followed by an enable value.

This library interposes only the scalar `set_value(const char *, int)` export.
For the exact `policy_status` path it calls the original two-integer overload
with `(path, 10, value)`. Other scalar paths go to the original scalar setter.
The string and two-integer overloads are not interposed. Values are neither
clamped nor replaced; byte-count returns and `errno` are preserved. A corrected
write logs its command and result for bring-up verification.

Keep the [HICA command entry](../configs/powercontable.xml) at `DefaultValue=1`,
`SportValue=1`, `Prefix=10^`. Omitting the default, or using the blob's
`-123456` sentinel, makes it read the multi-line `policy_status` report with
`atoi()`, producing a fallback of zero. Releasing a later HICA lock can then
write `10 0`. `-1` is not a skip sentinel and still produces a malformed
startup write. This repair leaves default restoration and scenario arbitration
inside the original Power HAL.

## Audited binary contract

The source and Tier1-installed ARM64 blob have SHA-256
`a7a777a8f845579b083cf81107b5c838b8d312f067421a0ffb12891a5fcd39cf`.
Addresses below are ELF virtual addresses, before load bias:

| Contract | Evidence |
| --- | --- |
| Scalar setter | `_Z9set_valuePKci`, `0x14508`, global/default visibility |
| Startup call | `loadConTable` at `0x16ae0` calls PLT `0x1b380`, backed by `R_AARCH64_JUMP_SLOT` at `0x1d610` |
| Two-integer setter | `_Z9set_valuePKcii`, `0x14348`; format at `0x74d1` is `%d %d` |
| Return value | Shared writer at `0x143d0` saves the length in `w21`, returns it at `0x144f8` after a complete write, or sets it to zero at `0x144ec` on failure |
| Interposition | `NOW/BIND_NOW`, no `DT_SYMBOLIC` or `DF_SYMBOLIC` |

The resulting ABI is `int (const char *, int)` and
`int (const char *, int, int)`, including non-boolean success returns: `10 1`
returns four. This conclusion comes from the instructions, not from the C++
symbol names, which do not encode the return type.

Before adding the global export, all 133 source vendor AArch64 ELFs, 163
Tier1-installed vendor/lib64 ELFs, and 687 installed system/lib64 ELFs were
checked. Only `libpowerhal.so` defines these setter overloads. Recheck this
contract when changing the blob or adding a library with the same export.

## Product integration

Add to `BoardConfig.mk`:

```make
TARGET_LD_SHIM_LIBS += /vendor/lib64/libpowerhal.so|libpowerhal-k50sv1-shim.so
```

Add to `device.mk`:

```make
PRODUCT_PACKAGES += libpowerhal-k50sv1-shim
```

This uses the existing Lineage Q linker shim support. `Android.bp` sets
`-Wl,-z,global` because Q searches `DF_1_GLOBAL` libraries before the local
group; an ordinary injected dependency would lose to the blob's own symbol.
The shim must be present before the blob's relocations are resolved. Setting
`LD_PRELOAD` in the init service is not sufficient under `AT_SECURE`.

The original setters are resolved once through an explicit, already-loaded
`libpowerhal.so` handle. `RTLD_NEXT` is deliberately avoided because the HAL
can be loaded with `RTLD_LOCAL`. The handle is retained for the process
lifetime. Missing required symbols or a missing backend cause a fatal log and
abort; no replacement file writer or unchecked fallback runs in that case.

## Verification

Run `power-shim/run-host-tests.sh` from the device repository. The host fixture
uses real shared objects and PLT dispatch, loading the shim globally and the
fake vendor backend locally. Tests cover corrected enable/disable commands,
signed integer limits, other and near-match paths, null-path forwarding,
untouched prefixed overloads, byte counts, `errno`, and fatal resolution errors.

A standalone Android 29 AArch64 build with this checkout's Clang, vendor
headers, CRT objects, and LLNDK libraries passed. Its dynamic flags are
`NOW GLOBAL`, its only defined dynamic symbol is `_Z9set_valuePKci`, and its
instructions pass policy 10 plus the original value to the real pair setter.
Retained commands and outputs are under
`bringup/logs/power-shim-20260908/` in the workspace. This standalone check does
not replace the product's Soong build.

After product integration, verify the installed library's export and global
flag, the linker's exact shim mapping, and vendor ELF closure. Live proof is
still required: confirm the shim is mapped into the Power HAL process and logs
`policy_status scalar write "10 1" returned 4`, then verify the startup
`Invalid input` error is gone and HICA/default restoration remains correct.
No device commands were used while implementing or testing this change.
