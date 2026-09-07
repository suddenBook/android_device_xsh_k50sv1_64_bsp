# Tier-3 A2DP peer evidence — 2026-09-07

The captured stereo frequencies **pass the unchanged ±3 Hz criterion**:
997.01515294 Hz left and 1499.12037906 Hz right, against 997/1499 Hz. The raw
controller result remains **FAIL**, with `valid_for_route_claim=false`, after its
route guard reported the phone stream absent/replaced/moved. This is a partial
result; the original controller outcome has not been relabeled.

The Enforcing Tier-3 phone negotiated AAC at 44.1 kHz stereo. One source contained
45 s silence and 8 s tones, captured through a private sink monitor at 48 kHz.
All 207 saved route samples passed, including exclusive phone/sink and
monitor/recorder links; all 14 HFP/SCO/call checks passed. The last passing route
sample was 56.38626283 s after the controller origin. The first failed time and
failing graph were not saved, so that value is **not the first absence time**.

Phone logs show decoder EOS and exactly 2,544,000 AudioTrack frames delivered,
the complete 53 s source, before A2DP suspension and controller force-stop.
This supports ordinary playback completion as the late guard-failure trigger;
a MediaPlayer completion callback was not logged. The recorder's valid WAV has
2,728,448 frames. Absolute launch/first-frame timestamps were not saved, so
relative route times cannot be precisely aligned with phone wall time. Private
sink, recorder and Bluetooth input reported zero xruns; phone versus receiver
timing causation remains unisolated.

All cleanup checks passed: both bonds and test files were removed, the private
sink and agent exited, and host defaults/volumes/mutes/modules were preserved.
Phone media volume returned to 5. Bluetooth ended OFF as explicitly requested
to match the preflash owner state; this differs from the test's initial ON state.

[Structured results](result.json) retain measurements, hashes and timing limits.
No additional test or threshold change was made; raw identifiers and PCM remain
private.
