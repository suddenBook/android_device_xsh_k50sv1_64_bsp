# Source-stack runtime probes

These source fixtures provide repeatable checks of the userspace replacements.
They use the installed Android SDK/NDK and do not join
the product build or ship on the image. Generated binaries and signing material
are ignored by Git.

- `audio/`: one second of silent PCM output through the Q legacy AAudio /
  AudioTrack path, with bounded start/write/stop/close operations.
- `graphics/`: a 32-bit native Surface producer, 24 frames, and a checked
  PixelCopy readback. Wake and dismiss keyguard before launch, then allow two
  seconds for the display to settle.
- `sensors/`: two bounded accelerometer sampling windows with stop/restart,
  monotonic timestamp and callback-drain checks.
- `p2p/`: local Wi-Fi Direct group creation/removal with no peer connection,
  checked group/connection teardown and private interface/kernel captures.

The [current review](../../evidence/E-210.md) links image-bound runtime results
and fixture hashes. A passing probe does not establish microphone recording, audible
quality, Bluetooth routing, physical panel scanout or all graphics formats.
Capture service and loaded-library evidence with each installed image to prove
which implementation was exercised.
