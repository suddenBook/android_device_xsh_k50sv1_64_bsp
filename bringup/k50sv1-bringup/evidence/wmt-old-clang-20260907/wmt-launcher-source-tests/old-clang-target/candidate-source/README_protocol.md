# Paired WMT command framing

`include/linux/mtk_wmt_cmd.h` is an exact copy of the paired kernel's
`include/uapi/linux/mtk_wmt_cmd.h`, SHA-256
`4ea77989d01fa91b6cf2377aea59f679f02b3c9714b3052fa3ac014a2eec5c13`.
The build/review checks must compare these files before enabling the pair.
There is no untagged response fallback.

The 32-byte little-endian frame has a nonzero session and transaction identity.
The codec accepts one complete command and produces either a tagged status or a
complete normal/ROM metadata list. It validates lengths, unique indices and
basenames before writing any output; metadata name padding is explicitly zeroed.
Lists preserve opaque address bytes. Successful normal lists have all sequences
1 through count. ROM types 0 through 4 remain independently optional, including
the WMT sentinel; an empty ROM list is representable.

The codec alone cannot decide whether a transaction is still current. The kernel
must recheck owner, session, transaction, cancellation and deadline, then publish
all metadata with successful completion. The service publishes version properties
only after an accepted reply; those properties do not prove firmware download.

Compile `protocol.c` and `test_protocol.c` with `-Iinclude`, ASan/UBSan and
`-Wall -Wextra -Werror`. Eighteen groups use an independent literal wire request,
nonsymmetric 64-bit identities, the real MT6755 metadata values, malformed frames,
short outputs, invalid names, complete/duplicate/missing normal sequences and
optional/maximum ROM lists. The trial's `protocol-second/result.json` binds the
passing run. `protocol-first` retains a test-fixture failure caused by copying
only 25 bytes of a 26-byte filename; fixing the fixture did not change the codec.
Native/compat target compilation and the full service/kernel transaction tests
remain separate evidence.
