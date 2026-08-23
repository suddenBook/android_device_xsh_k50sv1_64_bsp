# Private release keys (intentionally versioned)

The device owner explicitly authorized committing these unencrypted private
keys to Git and GitHub for convenience in a private, single-device ROM
workflow. Their presence in a repository means they are permanently treated as
publicly disclosed/compromised, regardless of repository visibility.

These keys are valid only for this `k50sv1_64_bsp` personal build lineage. Do
not reuse them for another device, application, ROM, production deployment, or
security boundary. Anyone who obtains the repository can produce packages that
verify as this build lineage. Replacing a key later may require a clean flash
and loss of compatibility with apps or data signed under the old key.

Tier 3 uses the files as follows:

- `releasekey`: default application and OTA/recovery verification key after
  target-files post-signing; also the outer container key if an installed APEX
  is an unflattened `.apex` archive
- `platform`, `shared`, `media`, `networkstack`: Android package certificate
  identities mapped from the corresponding development keys
- `verity`: legacy Android `BootSignature` for `boot.img` and `recovery.img`;
  this device does not enable dm-verity or AVB for system/vendor
- `apex.pem`: shared RSA-4096 payload key for any installed unflattened APEX

Android Q currently defaults this legacy product to flattened APEX directories,
which contain neither an outer APEX archive signature nor a payload AVB object
to replace. The Tier 3 wrapper detects the target-files layout and therefore
keeps `apex.pem` reserved unless a future product configuration actually emits
`SYSTEM/apex/*.apex` archives; it never changes the product to updatable APEX
merely to exercise this key.

The `.pk8` files are unencrypted PKCS#8 private keys. Git does not preserve the
local `0600` read/write mode, so file permissions after a clone are not a
security control. The certificate pairs use RSA-2048 and are valid from
2026-08-22 through 2054-01-07; `apex.pem` uses RSA-4096. Restore conservative
local permissions after a clone if desired:

```bash
chmod 700 security
chmod 600 security/*.pk8 security/apex.pem
```

Certificate SHA-256 fingerprints:

```text
releasekey   F4:8B:C0:2F:BC:79:BF:A6:44:13:E2:9E:11:3F:2D:EB:7D:8A:31:EC:C1:E0:0F:1D:86:11:CB:C0:6C:3E:21:40
platform     84:92:18:78:54:B0:51:48:35:AE:97:DA:C7:25:9A:DF:62:82:E5:DC:EF:38:BB:72:64:F9:20:25:4A:AF:6E:D3
shared       CC:CE:23:37:BC:80:4F:6C:F9:90:0B:31:1F:45:BC:4D:7E:B5:1B:5A:4C:D0:A7:B9:3C:B4:53:C5:31:39:4D:03
media        33:42:0D:95:54:7F:3B:57:87:F0:AF:08:F0:AA:11:28:7A:CC:91:DE:4C:0C:E5:25:94:15:8B:7D:8F:B9:62:0B
networkstack 1A:8E:5A:42:9C:9B:83:76:37:6F:E0:FC:26:08:69:5D:E5:E2:B9:D0:30:F9:53:63:74:FA:1A:AB:8E:3A:25:15
verity       1C:E4:6E:32:8A:F4:F4:07:EF:12:89:30:EB:93:7B:BF:A7:2E:09:2E:DA:6A:0B:00:2D:6B:4A:AB:EF:40:D9:96
```

The SHA-256 digest of the DER-encoded public key derived from `apex.pem` is:

```text
e6b000d8b0fb0ee5e9c8d03c791c57f0096e5cf3c923582fc43c149a84d47d92
```
