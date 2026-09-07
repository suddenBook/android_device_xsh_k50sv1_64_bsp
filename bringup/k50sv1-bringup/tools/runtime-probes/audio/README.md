# Silent AAudio output probe

`aaudio-silence-probe` is an Android API 29 ARM64 dynamically linked PIE. It
requests a 48000 Hz, stereo, PCM I16, shared output stream and writes exactly
one second of zero samples at the negotiated sample rate, including the initial
nonblocking prefill. It then requests stop, waits for the drain and closes the
stream. It does not record audio or change volume, routing or system settings.

The requested performance mode is `NONE`. This tree's Q
`frameworks/av/media/libaaudio/src/core/AudioStreamBuilder.cpp` disables MMAP
unless low latency was requested, so the probe exercises the legacy
AudioTrack/AudioFlinger output path. Device dumpsys/logcat evidence is still
needed to confirm the actual HAL and output route.

The output includes every AAudio control result, the negotiated sample rate,
format, channels, sharing/performance modes, direction, device ID, burst/buffer
sizes, state names, accepted/written/read frame counts, underruns and elapsed
time. `frames_read` counts output frames consumed by the playback stream; this
program opens no recording stream. A different format, channel count or sharing mode is rejected before any
sample data is written. An accepted sample rate different from 48000 is reported
and used to calculate the one-second frame count.

Timeouts are 100 ms per blocking write, one second to start, five seconds for
the write loop and two seconds to stop. A ten-second process watchdog also
bounds an open/close or Binder stall. Normal success, API failure and caught
SIGINT/SIGTERM all use the same stop/close/builder-delete cleanup path. If the
watchdog fires, its signal-safe handler reports the timeout and exits; process
death releases the file descriptors and Binder client resources.

| Exit code | Meaning |
| --- | --- |
| `0` | One second of zero frames accepted, stream stopped and resources closed |
| `1` | AAudio, negotiated-format, state or per-operation timeout failure |
| `2` | Local clock/signal setup failure |
| `124` | Ten-second watchdog expired |
| `130` / `143` | Caught SIGINT / SIGTERM; cleanup attempted |

`PASS` establishes the output API lifecycle. All samples are silent, so it does
not establish audible speaker/headphone quality or Bluetooth playback.

## Build and host verification

```sh
bash build.sh
sha256sum -c SHA256SUMS
```

The build script records the exact command, compiler version, source/build/binary
hashes and ELF report. It defaults to installed NDK
`30.0.15729638` (`r30-beta2`) and accepts `ANDROID_NDK_ROOT` as an override. The
compiler target is `aarch64-linux-android29`; no static libc is linked.

Host validation passed with warnings treated as errors. ELF inspection confirms
`/system/bin/linker64`, AArch64 PIE, and only `libaaudio.so`, `libdl.so` and
`libc.so` runtime dependencies. All 32 imported AAudio symbols are exported by
the local Q `libaaudio.map.txt`.

Built binary SHA-256:

`93c421ad8c4bdc87d86b74b060980c4824f8846df92e90f7877661da657324f3`

## Device execution

The [current review](../../../evidence/E-210.md) records 48000 accepted and
consumed frames, zero xruns, and successful start/stop/close. This establishes
the output stream lifecycle only. Run from this directory:

```sh
adb -s 0123456789ABCDEF push aaudio-silence-probe /data/local/tmp/aaudio-silence-probe
adb -s 0123456789ABCDEF shell chmod 0755 /data/local/tmp/aaudio-silence-probe
adb -s 0123456789ABCDEF shell /data/local/tmp/aaudio-silence-probe
```

Keep the process exit status together with its stdout/stderr and compare audio
service state before and after the run. A Bluetooth route still needs its
separate headset fixture test.
