Reviewed the initial `main.c` (SHA-256
`8e3183760c80208b42d475b17f1fe7d3367151f9c7bd7f7a6c6d87583dfa5623`),
the committed protocol files, and shared UAPI header
`4ea77989d01fa91b6cf2377aea59f679f02b3c9714b3052fa3ac014a2eec5c13`.
This report records the initial snapshot; root owns the subsequent service fixes.

**Critical — firmware-log enable prevents disable and shutdown (confidence 100).**
`main.c:181` requires the existing worker to finish before a changed property can
be applied, and `main.c:426` joins that worker during teardown. The paired kernel
at `372a643505f6b0aab0b3adbd150ecb9d9291d8d9`, `linux/wmt_dev.c:1501`, calls
`wmt_dbg_fwinfor_from_emi(0, 1, 0)` after a successful enable. Its
`linux/wmt_dbg.c:608` implementation enters a loop with `isBreak` initialized true
and never changed, sleeping uninterruptibly for 100 ms per iteration. The worker
therefore remains in ioctl: a `yes` → `no` property change issues no disable, and
the shutdown join cannot finish. Command UNBIND does not stop this legacy ioctl.

The characterization calls the exact service helper with a held enable backend.
After changing the property to `no`, it observes one enable, zero disables,
`finished=false`, and cached value `yes`. The explicit test-only release lets the
host test clean up; no equivalent exit exists in the retained collector.

Fix the pairing coherently: make the ioctl collector perform one bounded drain
pass; let the service worker repeat passes while its stop flag is clear; stop and
join that worker before the final disable. Sending disable before join alone has
a start race: the worker may enter enable after disable was sent. Keep the proc
collector streaming only while enabled and not interrupted, and unwind its lock
and buffer on every exit. Withdraw launcher readiness when command ownership is
withdrawn, before potentially waiting for workers.

**Critical — read-side transaction expiry terminates a usable session
(confidence 98).** `main.c:326` retries `EINTR` and `EAGAIN` but returns all other
read errors. The paired broker's `wmt_lib_read_cmd` contract also returns
`ETIMEDOUT` when the deadline expires during the locked `copy_to_user`; delivery
is not committed and the bound session remains usable. The copied bytes must be
ignored, but the service currently exits its command loop and unbinds. This
unnecessarily aborts subsequent command handling and can disrupt a power retry.

The exact service loop characterization contrasts `EAGAIN` (loop survives, next
poll reached) with `ETIMEDOUT` (returns `-110` after the first poll). Add
`ETIMEDOUT` to the read retry branch. The broker confirms that its other read
errors are `ENOTCONN`, `EMSGSIZE`, and `EFAULT`; those should remain failures.
Cancellation/reset before read yields `EAGAIN`. No `ECANCELED`, `ENOENT`, or
`ESTALE` read return needs to be invented. The broker is being finalized in its
separate worktree; this contract was confirmed with its author, and the frozen
source binding can be added when available.

No additional material findings were found in this scope. The review checked
MT6755 and its `0x0326` prefix alias, current `-p`/`-o 1` startup, readiness and
chip gates, scalar HIF `0x23`/kill-clear/power arguments, independent power work,
session validation and unbind ordering, complete framed requests and metadata
replies, write-side expiry, accepted-metadata property timing, the 109-byte dump
copy with a 110-byte initialized source buffer, and both original command names.
`update_patch_version` receives an explicit unsupported status and is not claimed
as an original command. The protocol preserves session and transaction identity,
uses exact little-endian sizes, and validates normal completeness and ROM bounds.

The three characterization cases passed ASan/UBSan with leak detection and empty
stderr. They demonstrate the two service defects; they are not a passing service
acceptance suite or a hardware test. Production files and root's main tests were
not edited. Source snapshots, compile arguments, logs, and hashes are retained
beside this report.
