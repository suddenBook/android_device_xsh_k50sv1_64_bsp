# Android Q release property verification

Build23 completed a clean Tier-3 compile and verified every APK signature, but
the property gate incorrectly required `BOOT/RAMDISK/prop.default`. This device's
Q boot ramdisk contains first-stage init/fstab. Main Android reads
`SYSTEM/etc/prop.default`; recovery reads its own `/prop.default`, as specified
by [Q init](https://android.googlesource.com/platform/system/core/+/refs/tags/android-10.0.0_r47/init/property_service.cpp#882).
The gate now requires these actual sources and also sweeps ROOT for unsafe
properties and debug components.

A second false positive treated a device comment mentioning `test-keys` as an
active identity. The verifier now ignores whole comment lines like Q init;
inline `#` remains part of a property value. All existing security values,
override/import checks and active development-key rejection remain enforced.

The real build23 archive was independently signed again using Q releasetools
and the validated release keyset. Its actual properties pass the corrected
gate. [Results](result.json) bind the archive, real entries and verifier.
The host fixtures use the actual symlink layout and cover stray BOOT/ROOT
properties, debug markers and inline development tags. Independent review
found no blocker. The same signed archive also passes the subsequent OTA trust,
both BootSignature checks, WFC resource gate and stage property reads. Eleven
consumed system/vendor image paths equal their signed ZIP entries; six flattened
APEX directories match the zero-archive branch. Neither the failed build nor
this diagnostic archive was flashed; the formal clean release build and runtime
checks remain required.
