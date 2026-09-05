# Legacy software Gatekeeper

`gatekeeper.default` builds the 64-bit vendor HAL at
`vendor/lib64/hw/gatekeeper.default.so`. It replaces the extracted MTK
`libSoftGatekeeper.so` installed at that path. The existing AOSP
`android.hardware.gatekeeper@1.0-impl` and service continue to discover its
`HMI` entry and use the legacy Gatekeeper API.

## Source and compatibility

The software backend and legacy API translation are derived from AOSP
`system/core/gatekeeperd/SoftGateKeeper.h` and `SoftGateKeeperDevice.cpp`
(local source revision `6d27634866be5b646a8cea1f9abeae902fd831e5`). The module
entry follows `device/generic/goldfish/gatekeeper/module.cpp` (revision
`9cf803e7e4f0ce139de4a3e01998cf180d150409`). The original Apache 2.0 notices
are retained; the complete license is in `LICENSE`.

Primary source locations:

- [AOSP Q software backend](https://android.googlesource.com/platform/system/core/+/android-10.0.0_r1/gatekeeperd/SoftGateKeeper.h)
- [AOSP Q legacy module example](https://android.googlesource.com/device/generic/goldfish/+/android-10.0.0_r1/gatekeeper/module.cpp)
- [AOSP Q Gatekeeper implementation](https://android.googlesource.com/platform/system/gatekeeper/+/android-10.0.0_r1/gatekeeper.cpp)
- [AOSP Q HAL interface](https://android.googlesource.com/platform/hardware/libhardware/+/android-10.0.0_r1/include/hardware/gatekeeper.h)

The linked, existing `libgatekeeper` (revision
`95a65511bd48ea8da24a2ecb97e6196ce23503b4`) owns enrollment, constant-time
signature comparison, authentication-token serialization and retry policy.
`libscrypt_static` comes from `external/scrypt` (revision
`d6114db148b1ededd120de0cf2d1fc73ba1611ac`); it remains a normal source-built
dependency with its own license.

The stock binary's mini-debug symbols and disassembly establish the same
scrypt parameters (N=16384, r=8, p=1), eight-byte salt, 32-byte signature,
58-byte packed password handle and zero authentication-token HMAC. Failure
records remain in process memory as in that binary. The flag that labels a
handle hardware-backed remains true solely because Q `gatekeeperd` uses it
to route HAL credentials and preserve SID during re-enrollment. **This
implementation provides no TEE, hardware-backed key, authenticated token
HMAC or persistent secure throttle.** Changing that flag alone would change
credential routing without adding any of those properties.

Each open owns a separate device and state; calls on a device serialize the
failure map and crypto-error state. Close releases both allocations. The
HAL rejects malformed or incomplete handles, clears outputs on errors,
checks RNG/scrypt/clock failures and returns caller-owned `new[]` buffers.
Optional deletion operations remain unimplemented, matching the existing
software backend's stateless credential storage.

The AOSP software password cache is deliberately omitted: its key is only
SID, so a successful password cached before re-enrollment can authenticate a
new handle with that same SID. This module verifies the complete supplied
handle using scrypt on every request, including after password changes.

## Host regression

Run from any directory, passing the Android checkout and a scratch output
directory outside the source tree:

```sh
python3 gatekeeper/tests/run-host-tests.py /path/to/lineage-17.1 /path/to/scratch/gatekeeper-tests
```

The script compiles the actual `module.cpp`, unchanged Q `libgatekeeper`
sources and the actual portable scrypt implementation. It uses host
OpenSSL for PBKDF2/RNG, ASan, UBSan and leak detection. It does not compile
Android or use credentials from a handset.

The 176 assertions cover enrollment; correct, wrong and embedded-NUL
passwords; challenge, SID and token fields; optional token output;
re-enrollment with preserved SID and rejected old password; corrupted
signatures; separate opens/close/reopen; malformed lengths/null parameters;
injected random/scrypt/clock failures; retry throttling; concurrent calls;
and a legacy-format test handle independently encoded with Python/OpenSSL
scrypt. A successful host run is not a claim of Android linkage or handset
validation; integration owns those checks.

The unchanged Q `GateKeeper::MintAuthToken` allocates `hw_auth_token_t` and
holds it in `UniquePtr<uint8_t>`, whose scalar delete has a different static
size. The host compiler's newer default sized deletion makes ASan report
this existing dependency issue. The test explicitly uses
`-fno-sized-deallocation` to match the checked-in Q clang-r353983c1 default
(which does not define `__cpp_sized_deallocation`). No sanitizer category
is disabled, and upstream source is unchanged. This documents the existing
dependency limitation rather than claiming it was repaired by this HAL.
