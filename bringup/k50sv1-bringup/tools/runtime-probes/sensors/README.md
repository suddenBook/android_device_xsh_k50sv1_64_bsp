# Bounded accelerometer runtime probe

Run build.py with an installed Android SDK. It produces out/k50-sensor-probe.apk
and a source/APK hash record. The generated signing key is test-only, remains
private under signing/, and is never included in the product.

Install on the explicitly selected handset and launch
local.k50.sensorprobe/.SensorProbeActivity after waking and dismissing keyguard.
Read the K50SensorProbe log tag. Each run requests 20 ms and 100 ms sampling in
two two-second windows, with a 400 ms unregistered interval after each.
The process exits after at most seven seconds.

PASS requires exactly one framework accelerometer, at least five events per
window, finite nonzero data, increasing timestamps and no callbacks during
the unregistered windows. Only counts and aggregate vector magnitudes are
logged. No permission, network connection or sample recording is used.

This checks framework/HAL/driver sampling and restart on the installed bundle.
It does not measure orientation calibration accuracy, power consumption,
real-time scheduling guarantees or long-term suspend behavior. Preserve the
same APK and its hash for before/after comparisons, then uninstall the probe.
