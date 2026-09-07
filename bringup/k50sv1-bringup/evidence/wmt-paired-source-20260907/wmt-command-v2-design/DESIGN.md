# WMT command v2: paired transaction contract

This design is based on kernel `372a643505f6b0aab0b3adbd150ecb9d9291d8d9`.
`inputs/manifest.json` binds the copied sources and E-201/launcher contract.
The accepted UAPI is `wmt-command-v2-kernel-work/include/uapi/linux/mtk_wmt_cmd.h`,
SHA256 `4ea77989d01fa91b6cf2377aea59f679f02b3c9714b3052fa3ac014a2eec5c13`.
The sibling `wmt_command_v2.h` is an earlier standalone layout draft. The kernel
UAPI is the canonical byte-for-byte header for the paired launcher.

## Wire and session API

Each read or write transfers one complete record. All multibyte fields are
little-endian. The 32-byte header has magic `0x32544d57` at offset 0, u16 version
2 at 4, u16 kind at 6, aligned u64 session ID at 8, aligned u64 transaction ID
at 16, u32 payload length at 24, and s32 result at 28. There are no pointers,
`long`, `size_t`, packed structs or architecture-dependent enum fields.

Kind 1 is a request containing the original command bytes, without NUL, length
1..255. Kind 2 is a status reply with no payload. Kind 3 is a normal patch list;
kind 4 is a ROM list. Lists contain u32 count, u32 reserved=0, then exactly count
264-byte records: u32 sequence/type, four opaque address bytes, and a nonempty
NUL-terminated name[256]. No trailing bytes or second frame are accepted.

`srh_patch` success requires kind 3, result 0, count 1..10, and exactly one record
for every sequence 1..count. Record order is irrelevant. Duplicates, holes and
out-of-range sequences fail. `srh_rom_patch` success requires kind 4, result 0,
count 0..5, and unique types 0..4. Zero records explicitly means optional absence;
type 4 (WMT) remains representable. A negative result uses kind 2 and no payload
for every command. Other commands use kind 2 for success too. A success-only
status reply cannot complete a metadata search. Maximum read/write records are
287/2680 bytes. Invalid replies do not complete a request; the sender can submit
a corrected frame or an explicit negative result before its deadline.

`WMT_IOCTL_CMD2_SESSION = _IOWR(0xa0,64,struct wmt_cmd2_session) = 0xc020a040`
has the same native and compat number. Its 32-byte layout is version/action at
0/4, aligned u64 session at 8, read/write maxima at 16/20, flags/reserved at
24/28. Input maxima, flags and reserved must be zero. BIND action=1 uses input
session=0 and returns the session and maxima. Repeating BIND on the same bound
file is idempotent. Another file receives `-EBUSY`. UNBIND action=2 must echo
the current session or gets `-ESTALE`; it cancels the owned request and wakes
pollers. Failed input/output copies leave the binding unchanged.

One file description owns command service. Ordinary opens remain usable for
control ioctls. `dup` and inherited descriptors share that file description.
Distinct opens do not. Allocate session IDs from a boot-lifetime monotonic
counter in the existing built-in adapter, which survives module reload. Refuse
overflow instead of reuse. Transactions increment within a session and also
refuse overflow. IDs are routing identity, not authentication credentials;
the file identity must match even if another file knows both numbers.

## Broker state and I/O rules

Keep one pending producer, as today: idle -> queued -> delivered -> terminal ->
idle. The producer alone retires the terminal request. A second producer before
retirement gets `-EBUSY`. The immutable request identity belongs to this record;
it is never inferred from the most recently read command when writing a reply.

A request can queue before a launcher binds. BIND attaches that still-live
queued request to its new session. A terminal request is never reattached.
Publishing to an existing owner assigns its next transaction ID immediately.
The timeout is six seconds from publication, measured by an absolute kernel
deadline. Copy/validation delays do not reset it.

`read` is an atomic mailbox operation used with `poll`: zero count returns zero;
no queued command returns `-EAGAIN`; an unbound file gets `-ENOTCONN`; short
capacity gets `-EMSGSIZE`. A failed copy returns `-EFAULT` and leaves delivery
uncommitted. A successful copy is rechecked against the deadline before delivery
is committed. Only one reader can receive that request. A second reader sharing
the owner file gets `-EAGAIN` until a later request. The buffer contents must be
ignored after any negative return, including a post-copy timeout.

`write` first bounds count, copies the entire record once, and validates that
private copy. There is no header/body double fetch. Allocation and metadata
validation occur before the broker mutex. At acceptance, recheck current owner,
session, transaction, delivered state, terminal state, expected reply kind and
deadline. Any stale identity or terminal request is rejected. A copy fault or
malformed packet has no metadata or completion effects. A successful write
returns the whole record length; partial successful writes are not supported.
The launcher retains the exact token from the read in its handler context and
reuses that token on a copy-fault retry. It must never substitute a current token
into an old reply or retry a stale reply as a new transaction.

Reset cancellation, owner UNBIND/release, timeout and reply acceptance all
serialize under the same broker mutex. The first terminal decision wins. Closing
an unrelated control-only open cannot cancel another file's command. VFS calls
release only after the final file reference, including in-flight syscalls, is
gone; explicit UNBIND permits prompt shutdown while a power ioctl is still
running on that file. A paired launcher may also use a separate control open for
its power thread. Module ownership already exists on the cdev.

Only the owner sees command readiness in `poll`; a delivered request is writable
for its owner. Unbind/shutdown wake pollers and report the disconnected state.
No legacy untagged write is accepted. Old SET_PATCH_NUM/INFO/ROM_INFO ioctls are
rejected in native and compat entry paths, including on control-only opens and
before BIND. Checking only the current owner's protocol mode would leave a
metadata bypass through another open.

## Metadata ownership and lock order

Normal patch replies are validated and allocated as a complete array indexed by
sequence. Commit replaces the complete cached array under its cache mutex and
publishes count/readiness together before command success is signalled. There
is no partially published count or editable per-record ioctl. The array is
immutable between accepted searches. Readers already copy name/address under
the cache mutex; `wmt_lib_get_patch_info()` is only a readiness marker, not a
borrowed record. The selected MT6755 producer waits for the search before using
count and records, and its download loop runs on that producer before it can
start a later search. A rejected or cancelled search leaves the prior committed
cache intact; it cannot manufacture a ready cache.

ROM replies preallocate all supplied records, then publish only previously empty
type slots together under the ROM mutex. This preserves the current first-valid
record policy across successful cached retries. Existing types retain their
records. No allocation or validation can fail partway through publication.
Missing types still map to the existing optional return value 1. Omitting the
WMT record preserves the current behavior that a later getter may search again;
the protocol does not invent an empty WMT sentinel or remove `srh_rom_patch`.

Lock order is broker mutex -> one metadata cache mutex. Cache getters/free never
acquire the broker mutex, and no path waits for a command while holding a cache
mutex. The session allocator's short spinlock cannot wait or call module code.
Metadata allocation and full reply copying occur before the broker mutex.
At commit, recheck the deadline after acquiring the cache mutex and before the
terminal decision. Complete the embedded command completion while still holding
the broker mutex, after publication. Completing it later outside the mutex could
signal a new request after the producer retires and reinitializes the completion.

Shutdown first closes command admission and cancels its pending producer, then
joins/drains workers. Free normal and ROM caches only after the consuming worker
has returned, before clearing `gDevWmt`. Move the early normal-cache free in
`WMT_exit` to this drained cleanup phase. Pending response-copy allocations belong
to their syscall and are discarded if its final acceptance check fails.

## Source evidence and counter-histories

The pinned `core/wmt_lib.c:667-744,831-862` and `linux/wmt_dev.c:1003-1058`
establish that old replies have no identity, reads merely set delivered, and
cancel/timeout make the shared broker reusable. E-201's five directed late or
duplicate reply histories remain required failing baseline controls.

The metadata problem also exists independently of the untagged reply:

1. A reads `srh_patch`, sets count 2 and slot 1, then expires. B queues another
   search because readiness is still false. A's handler can finish slot 2 before
   reading B. It publishes A's cache; B's count ioctl now returns `-EBUSY`.
   This ordering is possible with the original serial launcher main loop.
2. A publishes every normal record, but its reply fails or times out. The next
   MT6755 startup sees count and readiness and can skip search entirely. Tagged
   acknowledgement alone would not undo this premature publication.
3. With multiple readers/clients, an old slot write after B's records can replace
   one record of B's cached set. `wmt_dev_set_patch_info` permits slot replacement.
4. ROM's first-record rule prevents overwriting a populated type, but A's late
   record can still fill an empty type. A late WMT record changes whether the
   next getter searches at all. A partial failed search survives until deinit.

These follow from `linux/wmt_dev.c:634-735`, `core/wmt_lib.c:2819-2878`,
`core/wmt_ctrl.c:536-624`, and `core/wmt_ic_soc.c:1235-1269,1294-1300`.
Normal metadata is freed only in outer exit; ROM metadata only in library deinit.
Kernel-half tests must exercise these paths with extracted source and prove
atomic publication, not count every malformed-packet case as a distinct old bug.

Required additional histories include cross-open replies with guessed current
tokens; duplicate A after B is read on the same file; unbind/rebind and stale
UNBIND; read/write/session copy faults; undersized/oversized/trailing frames;
metadata missing/duplicate/out-of-range records; allocation failure at every
allocation; timeout or cancellation during copy/validation; two readers sharing
one owner; no-match ROM, cached-ROM retries, and cleanup after accepted metadata.

## Preserved controls and scope

Startup's independent power thread must continue while main services commands.
Chip queries, HIF setup, launcher-kill state and ordinary control ioctls retain
their roles. Vendor/active-version ioctls are separate administrative inputs,
not outputs of the original patch/ROM handlers. They can legitimately cause
`update_patch_version`; that command is not intrinsically unreachable on MT6755.
The original launcher lacks its handler. A paired target handler must return a
tagged negative result when unsupported, never silent success. Any future use of
administrative setters as command outputs would require its own tagged contract.

This ABI protects command acceptance and kernel metadata ownership. It does not
roll back arbitrary external handler effects such as UART configuration or an
already-issued Android property write. The paired launcher should avoid publishing
command-derived success after a stale reply is rejected. The current target uses
BTIF; UART-only commands are not exercised by this MT6755 startup. ROM format and
property decoding remain root-owned launcher work; the agreed list preserves its
0..4 types and optional no-match result.
