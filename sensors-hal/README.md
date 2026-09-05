# Legacy sensors to Sensors 2.0

The 64-bit `android.hardware.sensors@2.0-service` implements the real Sensors 2.0
FMQ interface over the existing `sensors.mt6755` board filter. The filter still
loads `sensors.mt6755.stock.so`; the accelerometer list, legacy activation,
batching, flush, event payload conversion and optional direct-report operations
come from that backend. The device manifest remains Sensors 2.0.

Source provenance:

- AOSP Multi-HAL 2.0, `android-r-preview-1`, commit
  [`d1fa5833826a1878e42acc26f902bd3cacc63330`](https://android.googlesource.com/platform/hardware/interfaces/+/d1fa5833826a1878e42acc26f902bd3cacc63330/sensors/2.0/multihal/).
  This revision precedes the Sensors 2.1 dependency. The `multihal/` sources
  preserve its Apache 2.0 license notices.
- LineageOS legacy adapter, commit
  [`805d25348106e8cc6f378c0b153789f3cf8da667`](https://github.com/LineageOS/android_hardware_lineage_interfaces/tree/805d25348106e8cc6f378c0b153789f3cf8da667/sensors).
- Event and sensor conversion uses the current tree's
  `android.hardware.sensors@1.0-convert`. All build dependencies exist on Q;
  `libhidltransport` is linked explicitly for its pre-R transport split.

The single sub-HAL is wired into the service directly, so it needs no additional
shared-library loader or `hals.conf`. Its installed executable name, service UID,
groups, wake-lock capability and manifest instance stay the same.

The legacy device and poll worker have process lifetime. `poll()` has no generic
cancellation API: closing or freeing the backend while it is blocked would be
unsafe. The worker starts once, only after a valid callback is published.
Framework reinitialization changes the callback under the same mutex used for
event delivery; a session generation discards a poll batch begun before the
restart. Activation timestamps discard earlier samples, using the interface's
`elapsedRealtimeNano()` timebase. The active kernel accelerometer also timestamps
with `get_monotonic_boottime()` in `sensors-1.0/accelerometer/accel.c`.

The adapter checks device pointers and the required legacy 1.3 operations, retains
failed deactivations for retry, resets active requests and direct channels on
initialize, bounds returned event counts, and backs off empty/error polling.
Events for sensors excluded by the board filter are discarded.

The imported preview Multi-HAL also needs these corrections:

- Validate both FMQs and the callback before starting workers, serialize
  initialization, join old workers before replacing their queues, and keep each
  FMQ's producer/consumer direction intact during shutdown.
- Transfer `ScopedWakelock` ownership on moves, release references after workers
  stop, and use elapsed boot time for wake-lock expiry.
- Count wake events separately for an immediate write and its queued remainder;
  release references for dropped overflow or failed write chunks.
- Read debug state under its matching locks and use Q's `unique_fd` API.

Run `python3 sensors-hal/tests/test_bridge.py` from the device tree for host
ASan/UBSan regressions. The test compiles extracted production function bodies
against scripted HAL/FMQ boundaries: initialization and callback replacement,
failed disable retry, unknown/stale events, invalid poll counts and error backoff,
wake-lock moves/reset/overflow, invalid queues, sub-HAL failure and concurrent
FMQ initialization. This is not an Android build or a hardware test. The unified
build and phone verification must still confirm loading, one real accelerometer,
event delivery and rotation on the device.
