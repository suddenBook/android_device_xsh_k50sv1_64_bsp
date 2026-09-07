# K50 32-bit native graphics probe

By default, this standalone test APK creates a Java `SurfaceView`, acquires it through
`ANativeWindow_fromSurface`, and calls `ANativeWindow_lock` and
`ANativeWindow_unlockAndPost` for 24 CPU-filled RGBA8888 buffers. It draws eight
red frames, eight green frames, then eight frames of an 8 × 8 red/cyan checkerboard.
Frames are separated by 100 ms. The final checkerboard remains until the activity
finishes at approximately five seconds. An independent thread kills this probe
process after 5.5 seconds, including when native drawing or activity teardown stalls.

After the last post, Java requests a 64 × 64 `PixelCopy` from the SurfaceView and
checks four tile-center samples. It logs the samples and results, then recycles
the bitmap. An optional EGL/GLES2 mode is described below. The APK has no Android
permissions, reads no user files, uses no
network, and writes no application files. Android still creates normal package
and application bookkeeping during installation and launch.

The [current review](../../../evidence/E-210.md) records validated images. Match each result
to its installed image, APK hash and process ID. Allow display wake and keyguard
dismissal to settle before launch: starting during wake caused an initial Surface
replacement and a correctly reported `SURFACE_LOST` failure. The Java SurfaceHolder
and native producer both request RGBA8888.

## Artifact and local build

- APK: `out/k50-graphics-probe-armeabi-v7a.apk`
- Package: `local.k50.graphicsprobe`
- Activity: `local.k50.graphicsprobe/.GraphicsProbeActivity`
- Minimum SDK: 26; target SDK: 29; compile SDK: 36.
- Only native payload: `lib/armeabi-v7a/libgraphicsprobe.so`.
- JNI: ELF32, little-endian ARM; direct dependencies are `libandroid.so`,
  `liblog.so`, `libEGL.so`, `libGLESv2.so`, and `libc.so`. The EGL/GLES libraries
  are Android's public loaders; the runtime identity log identifies the selected renderer.
- Baseline APK SHA-256: `99add0e36481a8af32fca38806cb2fd236a8e15d190e7ac6d715d670bb7ce153`.
  A rebuild with a new local signing key has a different APK hash.

From this directory:

```sh
python3 build.py
```

The script uses the existing `/home/desmond/Android/Sdk`, Build Tools 36.1.0,
NDK 30.0.15729638 (r30 beta2), and JDK 17. Override the installed tool locations
with `--sdk`, `--build-tools`, `--ndk`, or `--platform` if necessary. It performs
no downloads and no Android platform build. All generated files stay in this
fixture directory. Native compilation uses the API 26 ARMv7 target and warnings
as errors; Java targets Java 8 bytecode and D8 produces the API 26 DEX.

`out/build.log` contains the final successful build commands and output.
`out/provenance.json` records compiler versions, commands, source hashes, JNI
hash, APK hash, and the explicit `runtime_tested: false` status.
`out/native-elf.txt` and `out/apk-verification.txt` retain the ELF, package,
launch component, ABI, signature, and SDK inspection results. APK v2 verification
and `zipalign` verification passed. `out/SHA256SUMS` is the APK checksum file.

The generated test-only RSA signing key is `signing/test-only.p12`; its password
is in `signing/password.txt`. Both are mode 0600 inside a mode 0700 directory.
The build reuses that pair for subsequent local installs. Keep the signing
directory private; it is not needed on the device or for checking the APK.

## Device execution

Run from this directory. These commands explicitly select the owner-operated K50;
never omit the serial when another handset is connected.

```sh
adb -s 0123456789ABCDEF install -r out/k50-graphics-probe-armeabi-v7a.apk
adb -s 0123456789ABCDEF shell input keyevent KEYCODE_WAKEUP
adb -s 0123456789ABCDEF shell wm dismiss-keyguard
sleep 2
```

Start log capture in one terminal, without clearing existing device logs:

```sh
adb -s 0123456789ABCDEF logcat -v threadtime -s K50GraphicsProbe:I AndroidRuntime:E > out/device-log.txt
```

Then launch from another terminal after ensuring the screen is visible and unlocked:

```sh
adb -s 0123456789ABCDEF shell am start -W -n local.k50.graphicsprobe/.GraphicsProbeActivity
```

If an installed copy uses a different local test signing key, uninstall only
`local.k50.graphicsprobe` before installing this APK. Wait for the previous
invocation's watchdog exit before starting another mode.

Stop log capture after the `WATCHDOG_EXIT` line. Match the `START` PID and log
timestamps to distinguish this invocation from any older lines. The log filter
includes error messages under both tags. Keep a full device log separately when
diagnosing graphics services, allocator/mapper failures, or SurfaceFlinger issues.

An optional display capture should be taken while the checkerboard is visible,
normally around three seconds after the `START` line and before five seconds:

```sh
adb -s 0123456789ABCDEF exec-out screencap -p > out/device-display.png
```

Remove the fixture when finished:

```sh
adb -s 0123456789ABCDEF uninstall local.k50.graphicsprobe
```

## Reading a result

A complete passing invocation has all of the following under `K50GraphicsProbe`:

1. `START ... java_is64bit=false` and
   `NATIVE_START pointer_bits=32 compiled_abi=armeabi-v7a api=26 expected_frames=24`.
2. `BUFFER` lines for frames 0–23 with the actual positive width, height, stride,
   `format=1` (RGBA8888), and `pointer_bits=32`; each has a matching `POST ... result=0`.
3. `NATIVE_SUMMARY result=PASS posted=24 expected=24 errors=0 pointer_bits=32`.
4. `PIXELCOPY result=PASS code=0` with samples matching ARGB
   `ffe02020,ff20c0e0,ff20c0e0,ffe02020` within 12 levels per channel.
5. `SUMMARY result=PASS native_rc=0 pixelcopy=PASS java_is64bit=false ... reason=deadline`,
   followed by `WATCHDOG_EXIT` at about 5.5 seconds.

`ERROR operation=... code=...` preserves native return codes. A failed or timed-out
readback is reported separately from native rendering, allowing a native posting
success to remain visible in a failing overall summary. `native_rc=-2147483648`
means the JNI call has not returned or never started by the summary deadline.
An early lost surface, early activity destruction, missing summary, pixel mismatch,
or missing native completion is not a passing invocation. No retry hides a failure.

The default mode probes a 32-bit Surface producer's CPU allocation/mapping/posting path and
checks consumer-visible pixel values. SurfaceView presentation also exercises the
normal compositor path on the installed system. PixelCopy reads the Surface and
does not prove physical panel scanout or identify which vendor HAL implementation
handled the request. Combine it with the parent task's service/process/library
evidence to attribute the result to the replacement 32-bit wrappers and 64-bit
composer. It does not cover explicit EGL/Vulkan rendering, camera/video formats,
protected buffers, every graphics usage flag, or long-duration stability.

## Optional EGL/GLES2 mode

Use the same APK, lifecycle and log capture, adding one boolean launch extra:

```sh
adb -s 0123456789ABCDEF shell am start -W -n local.k50.graphicsprobe/.GraphicsProbeActivity --ez egl true
```

This creates an EGL window surface and requests an OpenGL ES 2 context in the
32-bit JNI worker. A vertex buffer and GLSL ES 1.00 shaders draw the same 24 red,
green and checkerboard frames using `glDrawArrays`, followed by `eglSwapBuffers`.
The CPU `ANativeWindow_lock` producer is not called in this mode.

At the end of each eight-frame phase, four tile centers are checked with
`glReadPixels(GL_RGBA, GL_UNSIGNED_BYTE)`. The shader and readback coordinates
account for GL's bottom-left origin so the checkerboard has the same top-left
red tile as the CPU pattern. Readback precedes the swap because later color-buffer
contents need not be preserved; see [Khronos EGL Technical Note 1](https://registry.khronos.org/EGL/specs/EGLTechNote0001.html).
EGL mode uses this GL readback instead of Java PixelCopy, then releases its GL/EGL
objects and native window. Its readback verifies rendering, not compositor or
physical-panel output. The five-second summary and 5.5-second process watchdog
remain active, including during blocked driver calls or teardown.

A passing EGL invocation must include:

1. `START ... java_is64bit=false ... mode=egl` and `NATIVE_START ... pointer_bits=32 ... mode=egl`.
2. `EGL_IDENTITY` plus `GL_IDENTITY` containing the actual vendor, renderer,
   GL/GLSL versions and requested client version. Confirm the ARM/Mali identity
   when using the result to assess the K50 Mali path; a software renderer is not that evidence.
3. `EGL_POST` for all 24 frames, and `GL_READBACK ... result=PASS` at frames 7, 15 and 23.
   Each readback has four `GL_PIXEL` sample/expected values with tolerance 12.
4. `NATIVE_SUMMARY result=PASS ... mode=egl gl_readbacks=3`, then
   `SUMMARY result=PASS native_rc=0 pixelcopy=NOT_REQUESTED ... mode=egl gl_readpixels=PASS`.
5. `WATCHDOG_EXIT`, with no API, shader, pixel or cleanup error in this invocation.

Failures retain the EGL/GL error code, shader/link diagnostic or mismatched pixel
values in the log. The JNI result fails if rendering, readback or resource cleanup
fails. No EGL-to-CPU fallback occurs. This mode is an external diagnostic for
the selected user-space GLES driver and kernel graphics path; APK build/ELF/signature
checks alone do not establish a device runtime pass or isolate a GED change.
