# Bounded WMT thermal read

`run.py` finds the thermal zone whose `type` is `mtktswmt` and reads its `temp`
attribute at most three times. It checks the handset incremental and WMT module
hash against an existing `buildN-expected-installed.json`, binds the boot ID and
taint before and after, and records kernel log intervals. It uses only device
reads; no controls, radio state, or modules are changed.

Each temperature command prints its shell PID and then uses `exec cat`, so an
existing `wmt_dev_tm_temp_query` printk bearing that PID can be attributed to the
sysfs read. No tracing or debug controls are enabled. A successful temperature
read without such a record remains inconclusive for direct callback execution.
`PASS` describes the bounded reads and identity checks; inspect
`callback_execution_evidence` and each sample's `same_pid_callback_lines` for the
separate callback evidence.

From the trial directory, reuse with a fresh output directory and the matching
completed-build manifest:

```sh
python3 wmt-thermal-read-probe/run.py --build 17 --expected-manifest build17-expected-installed.json --kernel-repo wmt-platform-batch-kernel-work --output runtime/build17-thermal-read --expected-boot-id ACTUAL_BUILD17_BOOT_ID
```

The repository need only contain the manifest's `kernel_revision`; source
excerpts are read using `git show` at that revision. `--expected-boot-id` is
optional: without it, the first observed boot ID is pinned for the entire run.
The default serial is `0123456789ABCDEF`, and `ADB_LIBUSB=1` is set for each ADB
command. `--reads` accepts only 1, 2, or 3. Output contains raw read results,
command records, kernel intervals, source excerpts, the input manifest, and
artifact hashes.

The build16 run used incremental `eng.desmon.20260907.005031` and boot
`899b42cd-f9fe-47ec-b28a-78bbd9753f20`. Discovery selected `thermal_zone4` with
type `mtktswmt`; all three reads returned 37000 millidegrees. At kernel times
1540.510847 and 1542.259641, the captured `cat` PIDs 9182 and 9193 emitted
`wmt_dev_tm_temp_query:[Thermal] current_temp = 0x25`. This directly demonstrates
the callback's fresh-read branch for two samples. PID 9204's third sample had no
corresponding record; caching is consistent with the source, but that sample
does not prove either cache selection or callback execution.

Boot ID stayed fixed, taint stayed zero, and the live WMT module's installed
hash stayed `3eb7bc7be865bea69a5772abba568d42f53cca8e0c5684b2cbdefe5f36a0867c`.
The three captured intervals contained no recognized kernel fault signatures.
See `runtime/build16-thermal-read/result.json` for the complete binding.

The WMT thermal zone invokes four sensor wrappers and returns a selected sensor;
its returned value alone is not evidence of the WMT sensor reading. These
observations establish the real handset call path during ordinary reads. They
do not test callback draining, concurrent teardown, or module unloading.
