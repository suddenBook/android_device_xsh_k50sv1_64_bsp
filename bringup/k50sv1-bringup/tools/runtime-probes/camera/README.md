# Camera preview stream probe

Build with `python3 build.py`, install the generated test APK on the explicitly
selected handset and grant its sole requested permission, `CAMERA`. Wake and
unlock the display before starting
`local.k50.cameraprobe/.CameraProbeActivity`. Read log tag `K50CameraProbe`.

The activity opens each advertised camera in turn, requests NV21 preview at
640×480 when supported, otherwise the smallest advertised size, and runs each
preview for 2.2 seconds. A real visible TextureView consumes the camera's graphics
buffers; three callback buffers independently receive preview frames. Each
camera must produce at least ten correctly sized callbacks with increasing
callback timestamps and at least five TextureView updates. The activity releases
each camera and exits; a 15-second UI-thread watchdog and the external operator's
timeout bound a normal run. A blocked vendor call can also block that UI-thread
watchdog, so the operator must force-stop this test package after a timeout.

The probe stores no image or audio and requests no storage, microphone, location
or network permission. Logs contain camera IDs, dimensions and counts. Callback
timestamps measure delivery at the app, not exposure timing. Passing proves
preview buffer delivery; it does not establish image quality, autofocus,
photograph/JPEG correctness, recording or exact frame cadence.

For a JPEG dimensions check, add `--ez jpeg true` to `am start`. Optional
`--es picture_size_0 3264x2448` and `--es picture_size_1 2560x1920` select
advertised sizes; otherwise each camera uses its HAL default. The probe checks
the accepted parameter and JPEG header dimensions after each preview, then
discards the bytes without saving pixels. `JPEG_RESULT` reports each comparison.
This exercises the actual camera API independently of Snap's size-preference
filtering; it does not assess image geometry or quality.

`out/` and the local test-only signing key/password pair are ignored by Git.
Keep the exact APK for comparisons; rebuilding changes test signing inputs.
