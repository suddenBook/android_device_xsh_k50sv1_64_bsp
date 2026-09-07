This review binds the MT6755/BTIF launcher contract to the vendor ELF
`70b5224af4276eef4a27a405919e5a147b24739569b3a24f5ee1cb8d3cd9a2a7`,
paired kernel `54bdf406ee9963e3b926d8f19fc2bb4c1a3975eb`, and local MIT
OpenMTTools reference `ef35f769d211a2942a6783410b58bd824dd363f9`.
The reference is not a drop-in replacement: it rejects 0x6755, lacks the current
`-o 1` option and Android properties, powers on using different ioctl semantics,
and compares both firmware-version bytes instead of the original low-byte rule.

`contract.json` records each conclusion with ELF addresses, kernel/reference
line numbers, and existing build16 log line numbers. `extracted.json` binds all
inputs and evidence files by SHA-256. `extract.py` independently reads ELF load
segments and compressed mini-debug symbols, decodes the relevant switch entries,
parses the two real firmware headers, and extracts existing source/log evidence.
Run it with `python3 extract.py` from this directory; it writes only here.

| Current MT6755 behavior | Evidence |
| --- | --- |
| Wait for `vendor.connsys.driver.ready=yes`; open `/dev/stpwmt`; obtain chip 0x6755 | Main 0x4294–0x4478 |
| BTIF mode 3, FM mode 2; mode ioctl scalar 0x23, then launcher-kill clear | Main 0x45b8–0x45d0, 0x4d08–0x4d3c |
| `-o 1` sends power ioctl scalar 2 with retries from a separate thread | 0x46f4–0x4700, 0x5ba8–0x5ca4 |
| Select `ROMv2_lm_patch`; match only firmware low byte | 0x329c–0x32d8, 0x3398, 0x3530–0x353c |
| 28-byte header; count and sequence in offset-24 byte; basename passed to kernel | 0x3540–0x3628; `WMT_PATCH_INFO` |
| File `_1_0`: sequence 2/address `00000600`; `_1_1`: sequence 1/address `00000af0`; total 2 | Hash-bound real headers and build16 log |
| Publish patch version `20200629194517a` asynchronously, before firmware validation and metadata registration | 0x3458–0x349c, 0x5878–0x5a70 |

`formeta.ready` is also scheduled before the power thread starts. Neither it nor
`patch.version` proves completed download. The captured log establishes actual
MT6755 selection, metadata, response and property values, not a replacement's
equivalence. Optional firmware-log/dynamic-dump properties are absent in that
startup and do not block it.

The original implements `srh_rom_patch`, although this MT6755 platform and local
firmware set do not show its use. The source also produces
`update_patch_version`, which neither launcher command table implements. Its
`need_update` condition is not chip-gated: another userspace client could populate
the vendor table and set an active version through ioctls 37/40. It is outside the
demonstrated startup path, not impossible on MT6755.

Raw instruction excerpts, not r2's optimized-switch CFG annotations, underpin
the address claims. The vendor executable was never run; no ADB/device action or
production write occurred. No launcher implementation was created.
