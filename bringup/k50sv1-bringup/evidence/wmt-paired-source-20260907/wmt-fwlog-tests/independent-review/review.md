# Independent firmware-log review

**PASS: no actionable findings.** Reviewed frozen commit
`75f4664c480ccbf64b764406776e8a3d88a3325b`, based on
`372a643505f6b0aab0b3adbd150ecb9d9291d8d9`. The production change is confined
to `wmt_dbg.c`; this review made no production changes.

## Ring and copy behavior

The selected MT6755 source places the trace region at EMI offset `0x400` and
the next dump region at `0x8400`, leaving a 32 KiB trace area
(`platform/include/mt6755.h:135`). Its control definitions place the producer
index at `0x24` and debug mode at `0x40`
(`platform/include/mtk_wcn_consys_hw.h:146`). The new accesses match these
source definitions. The mapping wrapper returns the same base plus offset used
by the retained EMI-copy helper.

The collector rejects producer indices at or above 32768 before modifying its
cursor. Each trace copy is limited to the actual `sizeof(gEmiBuf)` (8 KiB or
32 KiB), and wrap uses the retained streaming endpoint of 32767. Each invocation
with ioctl arguments drains only its single producer-index snapshot, including
both segments when wrapping. It does not chase a moving producer. Manual reads
are capped at 4 KiB and consistently use the same exclusive endpoint; they do
not modify the streaming cursor. These are source-level ring assumptions, not
a claim that device firmware output was independently observed.

The existing printer receives a valid zeroed 384-byte line buffer, bounds its
line index, terminates fragments, and clears the buffer between fragments.
`osal_memcpy_fromio()` maps to the kernel's actual `memcpy_fromio()`.

## Locking, errors, and callers

The cursor, `gEmiBuf`, and shared `buf_emi` print pointer are used under the same
mutex. Every acquired-lock exit clears `buf_emi` before unlocking. Each call
frees its own allocation after the loop, so another caller may install its own
print buffer after the mutex is released without the earlier caller freeing
that new buffer. Allocation failure and interrupted lock acquisition never
publish a shared pointer or leave a held lock.

The collector returns allocation, missing-mapping, invalid-index, and signal
errors. Disable is checked before each trace chunk and ends the collector
successfully. Completed chunks advance the cursor before an interrupted call
returns, allowing subsequent calls to resume. The proc stream releases the
mutex before its interruptible 100 ms sleep and obtains mappings again on the
next pass. The current copy/print pass remains bounded by the ring size;
100 ms is a polling interval, not a real-time shutdown guarantee.

The actual ioctl dispatcher supplies `(0, 1, 0)`. The proc command table maps
`0x19` to the same collector and forwards the command ID as `par1`, so the
nonzero streaming selector is reached by the real proc path. Proc writes retain
their existing count-return convention. The separate paired command-V2 commit
`857d2d0b238231ad931e342c6950c458dae99063` propagates the collector's return value
from the ioctl. That propagation and the repeated launcher worker are required
companions to this collector change.

## Evidence

- Verified all 156 files in the author's artifact manifest, both frozen
  manifest hashes, all changed source hashes, and every extracted function
  against the appropriate candidate or baseline revision.
- Verified the retained 26-case ASan/UBSan run for each buffer size and the
  three TSan cases. The six baseline controls fail their intended contract
  checks and are not candidate failures. These suites were not rerun.
- Ran four additional ASan/UBSan cases using the unchanged extracted collector
  and host adapters: signal during a partial wrap tail, disable between wrap
  segments, invalid index after prior progress, and a manual wrapped read after
  prior progress. **4/4 passed**, including a subsequent successful drain and
  checks for zero held locks, zero live allocations, and a cleared print pointer.
- Verified the retained ARM64 GCC 4.9 `-Werror` command, configuration, source,
  and object hashes. The object is ELF64 little-endian AArch64. This review did
  not repeat the target compilation.

The additional tests and source extraction are bound by `extra-results.json`.
`verify_review.py` records the final review in `result.json`, including an empty
findings list. Host tests use MMIO, signal, allocation, and mutex adapters;
actual firmware behavior, full integration, and handset execution remain
separate evidence. This review did not access ADB or the phone.
