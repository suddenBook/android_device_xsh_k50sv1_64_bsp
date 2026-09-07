# MT6755 firmware discovery

`firmware.c` reads candidates from the supplied directory and returns complete,
bounded metadata for the paired MT6755 launcher. It does not send ioctls, write
properties, open the WMT device, or download firmware. Both public functions
replace their output only on success; a negative errno preserves every output
byte. Results are local to the call and require no global initialization.

`wmt_firmware_search()` selects the `ROMv2_lm_patch` basename prefix and uses the
existing `patch.c` decoder. The firmware comparison uses only header byte 23 and
the query's low byte. Header byte 24 carries count in the high nibble and sequence
in the low nibble; address bytes are `{0, header[25], header[26], header[27]}`.
All sequences from 1 through the declared count, at most 10, must be present once.
Records and 15-byte, NUL-terminated build versions are indexed by sequence minus
one. Filename suffixes and directory iteration order do not determine sequence.
No accepted patches returns `-ENOENT`; an incomplete set returns `-ENODATA`.

`wmt_rom_search()` selects the `soc1_0_ram` basename prefix. Firmware matching
again uses byte 23. A matching file must provide all 32 header bytes, have
`header[27] & 0xf0` nonzero, and provide a type in byte 31 from 0 through 4.
The address is `{0, header[25], header[26], header[27]}`; byte 24 does not carry a
ROM count or sequence. Records are indexed directly by type, with `seen` marking
presence and `count` counting populated entries. Every type is independently
optional, including WMT type 4. No accepted ROM files returns an empty successful
set. Both record structures retain the 264-byte kernel ABI with a 256-byte
NUL-terminated basename at offset 8.

A `ram_wifi` basename supplies the first 15 file bytes as `wifi_version`.
A `ram_bt` basename is read in full, up to and including 1 MiB, to extract
`bt_version`. The parser finds `BABEFACEBABEFACE`, then a later
`DEADBEEFDEADBEEF`, allowing binary bytes during marker discovery. Within that
interval, text recognition stops at the first NUL. A `t-neptune` substring starts
the version, which ends at the closing marker and is truncated to 91 bytes and
then at its first LF or NUL. If `t-neptune` is absent but `= debug` is present,
the original fallback is the first fourteen bytes of the file. It is not the
text following `= debug`.

Version text is optional: no markers or no recognized text leaves
`has_bt_version` false. A single marker or a start marker without a following
end marker returns `-EBADMSG`. If two accepted types use the same Wi-Fi or BT
version role, their extracted strings must agree; differing values return
`-EINVAL`, avoiding a property value chosen by directory order. Publication and
its timing are the caller's responsibility.

Matching candidates must open as regular files. Symlinks to regular files are
accepted and retain their directory-entry basename. Broken symlinks, directory
entries, FIFOs, short reads, duplicate records, malformed metadata, and syscall
failures abort the search. `O_NONBLOCK` prevents a FIFO from hanging discovery.
Interrupted reads are retried; partial reads are assembled; file and directory
handles are closed on every path. The first failure is preserved through cleanup.
BT allocation failure returns `-ENOMEM`, an oversized BT file returns `-EFBIG`,
and growth beyond its initial `fstat` size returns `-ESTALE`. The caller must keep
firmware files stable through the kernel's later loading of the returned names;
this helper does not provide a filesystem snapshot.

The valid-input interpretation is bound to the retained original ELF,
SHA-256 `70b5224af4276eef4a27a405919e5a147b24739569b3a24f5ee1cb8d3cd9a2a7`.
The offline disassembly has SHA-256
`f958dc534768d1a6a687c2ab4d25d4b6bbaf52738e883cb5917803173321aba6`.

| Original ELF virtual addresses | Interpretation used here |
| --- | --- |
| `0x38cc`–`0x39e8`, `0x3d24`–`0x3d48` | MT6755 ROM prefix construction and basename-prefix comparison |
| `0x4120`–`0x4144`, `0x4198`–`0x41bc` | Firmware field at offset 22, compared by its low byte |
| `0x3a88`–`0x3abc` | Eight metadata bytes at offset 24; high nibble of byte 27 and type byte 31 |
| `0x3af8`–`0x3b54` | Type, address with byte zero cleared, basename, ROM metadata ioctl layout |
| `0x4060`–`0x40d0` | `ram_wifi`, first 16 bytes with byte 15 cleared |
| `0x3ddc`–`0x3eec` | `ram_bt`, whole-file read, positive size through 1 MiB |
| `0x3efc`–`0x3f88`, `0x3bac`–`0x3c68` | Ordered markers, `t-neptune`, fourteen-byte fallback, 91-byte/LF bounds |

The helper deliberately rejects malformed inputs that the original sometimes
logs and continues past. The original also accepts type 5 at `0x3ab8`; the paired
kernel supports only types 0–4. Version strings are returned only for accepted
firmware metadata, whereas the original can publish before firmware matching.
These are explicit error-handling and publication changes, not claims of
byte-for-byte executable equivalence.

The host test uses the actual 28-byte headers from the retained normal files:

| Firmware basename | Whole-file SHA-256 | Expected sequence/address |
| --- | --- | --- |
| `ROMv2_lm_patch_1_0_hdr.bin` | `7a58e99fdcab239f133be92da999f8733878617191bb1f5caa1096d91ad8e1a2` | 2 / `00000600` |
| `ROMv2_lm_patch_1_1_hdr.bin` | `cb7ba98c5c73705eb03a6ec11b78a3b1cce6069132b1f267d50079f2b1b594fd` | 1 / `00000af0` |

All ROM fixtures are synthetic; no retained `soc1_0_ram` firmware is available.
Sixty host test groups exercise the real normal headers, full sequence and type
bounds, optional ROM collection, every short-header length, version parsing,
basename limits, malformed filesystem entries, partial/interrupted reads, and
injected open/stat/read/readdir/close/closedir/allocation/seek failures. Every
injected-failure and malformed-candidate check verifies that its preexisting
output is unchanged.
The tests call the unchanged production functions; linker wrappers are confined
to the host test executable.

The trial runner `wmt-launcher-source-tests/firmware-run.py` snapshots and hashes
the five compiled source/header files, checks both retained firmware hashes,
and builds with Clang, `-Wall -Wextra -Werror`, ASan, UBSan, and leak detection.
It writes exact compile/run arguments, logs, source and binary hashes, and all
case results. From the trial root, run:

```sh
python3 wmt-launcher-source-tests/firmware-run.py \
  --source wmt-launcher-device-work/wmt-launcher \
  --output wmt-launcher-source-tests/firmware-new-address \
  --reference wmt-launcher-contract-20260907/reference-review/extracted.json
```

These checks establish host discovery behavior and its failure paths. Integration
must additionally validate command identity, metadata commit and reply handling,
property publication, Android compilation, and handset behavior.
