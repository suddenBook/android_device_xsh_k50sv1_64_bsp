# Tier-3 build24 release and runtime acceptance

The complete clean wrapper finished successfully. APK signatures, the two exact
AOSP CTS exceptions, effective Q properties, OTA trust, boot signatures, WFC
exclusion, image contents and source provenance passed. An independent audit
matched all 786 project revisions, three PRESIGNED APKs and fourteen JNI files.

The normal verified flasher wrote boot/recovery/system/vendor and wiped
userdata/metadata/cache. A separate two-file diagnostic userdata fixture used
the final Q tools and contexts and this operation's measured LK writable size.
Its independent fsck passed all ten checks; five inode ownership/mode/label
checks and both extracted file comparisons passed before flashing.

The actual boot is `user`, `release-keys`, Enforcing, `ro.debuggable=0`,
`ro.secure=1`, `ro.adb.secure=1`, and an authenticated UID-2000 shell.
`adb root` was rejected and the subsequent shell remained UID 2000. All three
APKs and fourteen JNI libraries also match when read from the running phone.
The [result](result.json) binds the signed images, source revisions, flash,
fixture and runtime identity.

The OS defaults to ADB off; this userdata fixture deliberately enables it with
the owner's existing public key. An untouched default-off first boot was not
measured. Final `settings put global adb_enabled 0` succeeded. The same physical
USB device remained present as MTP only, with no ADB interface or transport,
through a six-second stable observation. MTP was selected for this observation.
Signing does not establish AVB, hardware attestation or carrier registration.

[Runtime results](runtime.json) cover both cameras and actual Snap photos,
1080p/AAC video, dynamic screen recording, sensors, 32-bit Surface and Mali EGL,
GNSS start/status/stop, HTTPS rendering and Google application UI. The five test
APKs and five media files were removed; screen timeout and charging wake settings
were restored. Bluetooth is OFF and per-subscription mobile data remains OFF.

[AAC peer capture](../peer-a2dp-tier3/README.md) passes the unchanged frequency
criterion; its late controller guard failure remains recorded. A single final
P2P peer attempt found no host-side peer or group and transferred no data; its
fixture cleanup passed. Indoor GNSS reported no position fix. Play certification
remains absent and the old SetupWizard/network compatibility is accepted by the
owner; neither is an open device-repair item.

The final log audit finds no OS/app fatal crash, native fatal signal, ANR or
watchdog kill. Eight nonfatal WTF entries and diagnostic SELinux refusals remain
visible. The early pre-SystemReady uiautomator exception is a separate fixture
failure. [Source main branches](../source/main-adoption.json) retain the exact
tested commits and trees; branch adoption did not change the installed code.
