# K50 WMT loader

This implementation targets the MT6755 SoC/BTIF configuration of this product.
It uses the source kernel's scalar wmtdetect ioctl ABI and the existing Android
ready/chip properties. The raw 0x0326 silicon alias is retained for SET_CHIP_ID;
cleanup and initialization receive 0x6755. Init still loads the kernel modules
through the existing device-owned service rules.

The loader accepts a complete, supported hexadecimal cached ID or queries the
SoC ID from the detector. A replacement cache value must be published before
initialization: the retained launcher parses nonempty chip properties before
trying its kernel fallback. Each initialization ioctl must succeed before the
loader sets vendor.connsys.driver.ready to yes. The device-node wait permits
200 attempts at 300 ms intervals; permanent open errors fail immediately.
An already-ready invocation succeeds without opening the detector again.

The original executable publishes readiness even after SET_CHIP_ID, cleanup
or initialization fails. This was verified by executing its unchanged ARM64
bytes with native imported-call replacements, after a mandatory seccomp filter
blocked real device ioctls, device opens and property-service sockets. The same
method passes 23 cases on this source compiled for Android API 29, including
those failures, malformed/overflowed cached values, alias handling, finite node
retry, property errors and an already-ready invocation. Device boot ID, taint and
real WMT properties remain unchanged during these simulated tests.

These results establish userspace control behavior. A complete Android build,
vendor extraction/provider check and real boot/radio activation are still
required before adoption. Raw traces, both fixture-library versions, exact
binary/source hashes and the test runner are retained in the bring-up workspace
at work/.capture-staging/source-replacement-20260905/wmt-userspace-assessment/.

The protocol references are the local kernel's common_detect/wmt_detect.h and
wmt_detect.c, the unchanged factory wmt_loader (SHA-256
e44a0e1c5e4b8b1ad204318f2f19b92c9a1bf97704b12f04722c26eb1ef94a9f), and the
retained wmt_launcher (SHA-256
70b5224af4276eef4a27a405919e5a147b24739569b3a24f5ee1cb8d3cd9a2a7).
