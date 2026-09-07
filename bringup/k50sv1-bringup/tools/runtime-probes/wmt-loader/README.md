# WMT loader control probe

This runs a **copy** of the Android ARM64 source WMT loader against imported-call
replacements. It tests readiness publication, initialization ordering, scalar
chip-ID arguments, malformed cached IDs, node retry and returned errors. It does
not open the real detector or initialize hardware.

`loader_mock.c` installs a mandatory seccomp filter before loader `main` runs.
The filter rejects real ioctl, openat, ownership-changing calls and the socket
paths used by property publication. Direct fallback ioctl/socket/open calls must
return EPERM before the fixture announces readiness. Before its constructor,
the fixture permits only the read-only Android property maps and the allocator's
transparent-hugepage setting. Fixture sleeps are simulated and bounded.

Build the fixture with the installed Android NDK's ARM64 API-29 compiler:

```sh
aarch64-linux-android29-clang -shared -fPIC -O2 -Wall -Wextra -Werror \
  loader_mock.c -o /absolute/output/libloader_mock.so
```

Use the real product's `out/target/product/k50sv1_64_bsp/vendor/bin/wmt_loader`
after its Android build. An NDK-linked development binary can also be checked,
but its result does not establish that the product selected or installed it.
Run on an already-ready diagnostic device with zero taint:

```sh
python3 run.py --adb /absolute/path/to/adb --serial DEVICE_SERIAL \
  --loader /absolute/path/to/wmt_loader \
  --source /absolute/path/to/device/xsh/k50sv1_64_bsp/wmt-loader/main.c \
  --mock-library /absolute/output/libloader_mock.so \
  --output /absolute/path/to/new-capture-directory
```

Each of the 23 cases retains its native trace and checks that containment ran.
The runner compares freshly captured real WMT properties, taint and boot ID
before and after the run, records input hashes, and removes its two temporary
device files. Production boot, firmware loading and radio operation need
separate testing. See the [current review](../../../evidence/E-210.md).
