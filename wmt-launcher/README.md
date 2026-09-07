# MT6755 launcher source candidate

This directory currently contains the patch-header decoder and metadata-set
assembly for the E-201 paired launcher/kernel repair. No executable or product
module is enabled yet. Command transport, startup, properties, filesystem I/O
and the complete replacement still need implementation and validation.

The contract comes from the retained launcher ELF, paired source kernel and
existing MT6755 firmware headers. Its detailed addresses and input hashes are
recorded in the bring-up work repository's E-201 evidence. The decoder preserves
the original low-eight-bit firmware match, 15-byte published build version,
sequence/address interpretation and 264-byte metadata layout. It rejects
malformed counts, invalid sequences and duplicate/inconsistent metadata sets.

`test_patch.c` invokes the actual decoder using the two original
`ROMv2_lm_patch_1_0_hdr.bin` and `ROMv2_lm_patch_1_1_hdr.bin` files, in that order.
Seventeen test groups cover these headers and reversed sequence order, firmware
byte distinctions, all short-header sizes, malformed count/sequence values,
duplicate and incomplete sets, metadata bounds and build-version extraction.
Compile `patch.c` and `test_patch.c` together with ASan/UBSan, then pass the two
firmware paths. The first hash-bound result is retained in the trial directory
at `wmt-launcher-source-tests/patch-first/result.json`.

These tests cover pure decoding and set assembly. They do not establish command
identity, metadata commit lifetime, original executable equivalence or handset
behavior.
