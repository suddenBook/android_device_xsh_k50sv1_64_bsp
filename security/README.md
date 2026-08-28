# Revoked development keyset — private keys must stay external

The private keyset introduced by device commit `93f06a4` was committed and
published. It is permanently compromised: deleting current files or rewriting
one clone cannot restore secrecy. Those certificates must never authenticate a
new Tier 3 build, application update, OTA, boot image, APEX, or another device.

No private release key is allowed in this directory. The ignore rules are a
backstop, not a storage mechanism. Tier 3 requires
`K50SV1_RELEASE_KEYS_DIR` to name a rotated key directory outside this
workspace and outside any Git checkout. The build wrapper validates ownership,
permissions, private/public pairing, uniqueness, and non-collision with AOSP
development certificates before taking an immutable private snapshot.

Expected external layout:

```text
releasekey.pk8
releasekey.x509.pem
platform.pk8
platform.x509.pem
shared.pk8
shared.x509.pem
media.pk8
media.x509.pem
networkstack.pk8
networkstack.x509.pem
bootsignature.pk8
bootsignature.x509.pem
apex-map.tsv                 # required only if archive APEX modules exist
apex/<module>.pem            # distinct payload key per archive APEX module
```

The `bootsignature` name is deliberate. Releasetools exposes legacy argument
names containing “verity”, but this product does not enable or enforce
dm-verity or AVB. The signature is cryptographically verified by the host
pipeline; with the current unlocked/orange bootloader it is compatibility
metadata, not a hardware root of trust.

The truthful Tier 3 posture is a release-signed Android `user` build for
private daily use, enforcing SELinux, with authenticated non-root ADB excluded
from the default USB configuration. It is not a verified-boot,
rollback-protected, encrypted, tamper-resistant, current-security, or
OTA-validated release.
