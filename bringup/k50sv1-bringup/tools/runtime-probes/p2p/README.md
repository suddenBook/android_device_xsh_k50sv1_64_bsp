# Local Wi-Fi Direct group probe

This bounded Android Q probe creates one autonomous group on the selected
handset, observes the group-owner state with zero clients, removes it, and
checks that group and connection state both clear. It refuses an existing
group and never requests a peer connection. Network names, addresses and
credentials are not logged. It uses the normal WifiP2pManager framework API.

Run build.py with the installed SDK, install out/k50-p2p-probe.apk, grant the
probe's location permission, enable location and Wi-Fi, then launch
local.k50.p2pprobe/.P2pProbeActivity. Read the K50P2pProbe log tag and capture
kernel messages and interface state during formation/removal. On Q, the app's
foreground location AppOp must permit the request. Restore any test settings
and uninstall the APK afterward. Preserve the same APK for baseline and final
image comparisons.

The activity schedules cleanup at 25 seconds and failure at 30 seconds.
FAIL or cleanup_pending=true requires
inspection and, if needed, a controlled Wi-Fi cycle; it is not a clean teardown
pass. This does not establish peer interoperability, traffic throughput or
unplugged suspend behavior. Generated APKs and private test-only signing keys
are ignored and never shipped in the OS.
