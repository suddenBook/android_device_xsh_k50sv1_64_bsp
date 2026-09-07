# Delayed assertion payload audit

Reviewed frozen kernel `54bdf406ee9963e3b926d8f19fc2bb4c1a3975eb`. No kernel or build inputs were changed.

The generic delay API has a reproducible shared-payload ownership error. Its producer locks publication, but the worker reads the same fields without that lock and passes the shared keyword buffer through the synchronous assertion/control path. The kernel clears the work PENDING bit before invoking its callback (`kernel/workqueue.c:2047-2054`), so publication can overlap a running callback and enqueue another execution. Serialization of callbacks does not serialize publication with payload consumption.

`fixture.c` copies whole production bodies for the producer, worker, assertion function, control handler, host assertion-info setters, and keyword setter. Hardware calls and workqueue scheduling are controlled host adapters. One callback runs at a time. Cases 0 and 1 use distinct generic inputs A=(0,111,first-assert), B=(3,222,second-assert):

- Case 0 pauses B inside snprintf, after its scalar writes but before its keyword write. A's already queued callback records (3,222,first-assert).
- Case 1 pauses A inside the hardware assertion call, after its scalars were passed by value. B overwrites the shared keyword and queues another execution. A resumes and records (0,111,second-assert).

Both exit 1 because the recorded tuple matches neither complete request. The ASan/UBSan build emits no sanitizer diagnostic; these are deterministic semantic-coherence failures. Cases 2 and 3 repeat the same schedules with the actual caller constants and record the unchanged tuple (4,46,DEVAPC Violation).

## Device reachability

The only production call sites are the DEVAPC callbacks in `platform/mt6768.c:1403` and `platform/mt6785.c:1536`; both use those identical constants. The delay API is not exported. k50sv1 defconfigs select `CONFIG_MTK_PLATFORM="mt6755"`, and `common/Makefile:191` links only `platform/$(MTK_PLATFORM).o`; the product object-command snapshot also lists mt6755.o, not mt6768.o or mt6785.o. There is no demonstrated route to this API in the current k50sv1 build16 configuration. This generic defect is not a blocker for that frozen build.

## Minimum future fix boundary

Snapshot type, reason and all ASSERT_KEYWORD_LENGTH keyword bytes into worker-owned local storage while holding g_wmt_assert_work_lock. Release the spinlock before invoking wmt_lib_trigger_assert_keyword, which can sleep. This preserves existing pending-work coalescing while preventing mixed tuples and mutation of the active keyword. Keep the existing lifecycle publication gate and cancel_work_sync ordering. No allocation or per-request queue is required for this ownership fix.

Regression coverage should force (1) replacement during queued work pickup, allowing the fixed worker to wait for the producer lock, (2) a second publication after the active callback has entered the assertion/control path, and (3) pre-init/post-close rejection plus publication/cancellation overlap. Same-constant controls distinguish generic API behavior from present call sites. This audit implemented no production fix.

See result.json for compiler command, source/fixture hashes and exact case output.
