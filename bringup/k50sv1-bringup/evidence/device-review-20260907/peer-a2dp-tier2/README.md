# Tier-2 A2DP peer evidence — 2026-09-07

Stereo AAC transport and private decoded capture are verified on the running
Tier-2 image. The unchanged **±3 Hz frequency check fails**; this is a partial
result, not an overall audio-quality pass. The phone negotiated AAC at 44.1 kHz
stereo; the host captured synthetic 997 Hz left / 1499 Hz right tones as 48 kHz
16-bit PCM through a private null-sink monitor.

| Valid trial | Private route checks | Captured peaks, L / R | ±3 Hz |
|---|---:|---:|---|
| Cold start | 41 | 1001.7102 / 1506.4521 Hz | Fail |
| 15 s warmup using repeated silent streams | 41 | 1001.9677 / 1506.3691 Hz | Fail |
| One player: 20 s silence, then 8 s tones | 106 | 999.2137 / 1502.2633 Hz | Fail |

The single-player route was verified 0.920 s after launch, before the silent
lead ended, and monitored through the tone. HFP/SCO remained inactive. All
listed route checks passed. An earlier attempt whose silent stream expired
failed its route guard; a separately sequenced player launch was stopped, and
that attempt is excluded from the transport evidence.

The observed drift is consistent with PipeWire 1.6.8's
[±0.5% Bluetooth buffer correction limit](https://github.com/PipeWire/pipewire/blob/1.6.8/spa/plugins/bluez5/decode-buffer.h).
The single-player control reduced the shift but did not isolate receiver
compensation from phone delivery timing. Profiling captured 2,891 cycles but
no Bluetooth correction coefficient. The source and private driver had zero
xruns; one recorder xrun occurred during the silent lead. No clock setting or
tolerance was changed. Planned recorder SIGINT returned 1 while finalizing
valid WAV files; this exit code alone is not an audio failure.

Cleanup completed: the test bond was removed at both ends, phone Bluetooth
restored off and media volume restored to 5, test files removed, and the owned
null sink unloaded. No host playback/capture streams remained; host defaults
and HDMI volume/mute were unchanged. [Structured results](result.json) retain
measurements and capture hashes; raw device identifiers, PCM and traces are
not published here.
