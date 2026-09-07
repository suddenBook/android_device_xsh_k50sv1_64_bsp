# Tier-3 startup evidence

No startup blocker or OS/app crash was observed in the reviewed capture. Artifact identity, user-build properties and APK verification are recorded in E-210. [Structured results](result.json) retain the exact exclusion list and evidence hashes.

The runtime window was **2026-09-07 16:10:53–16:15:53 UTC** (300.000155 seconds). Host log-byte boundaries avoid the device's earlier timezone changes. Process snapshots were taken at 0, 150 and 300 seconds.

| Retained process | PID in all three snapshots |
|---|---:|
| WFO HAL / IMSA HAL | 381 / 374 |
| MAL, including RDS logs / MediaTek IMS | 398 / 2326 |
| volte_stack / volte_ua / volte_imcb | 3921 / 3923 / 3924 |
| system_server / com.android.phone | 852 / 1871 |

The final source contract excludes **29 vendor files and 2 init files**. Its five executables—`charon`, `epdg_wod`, `starter`, `stroke`, and `wfca`—were absent from all three process snapshots. The runtime window contains **0 observed legacy socket retries** and no exact legacy binary/socket mentions. WFO, IMSA, IMS, MAL/RDS and the VoLTE components remain. Build24's merged framework WFC-availability resource is false; all three framework availability overrides read 0. Vendor IMS/WFC-build properties were not visible to the UID-2000 reader, so no runtime value is inferred from their source defaults.

The window contains **5 MAL readiness warnings**, clustered over 2.566 seconds during Wi-Fi-state updates in PID 398 / TID 629, with adjacent SIM 1 context. They are separate from removed-daemon retries. WFC remains off; the adjacent SIM 0 profile shows VoLTE on. No fixed periodic retry loop is established. There were no observed MAL `rat error!!`, VoLTE socket-retry errors or WFO provisioning-config errors in this window.

The window contains **54 raw AVC records representing 32 unique audit events**. Of these, 31 are shell property-read denials; one is a system_server kernel-log read denial adjacent to `wifi-jni: no kernel logs`.

The earlier startup prefix contains one fatal exception from the coordinator's UiAutomation dump before SystemReady (PID 1104). It is classified as a diagnostic fixture failure. The runtime window contains no observed Java/native crash or ANR records, and neither DropBox endpoint lists a crash, ANR or watchdog entry. Six earlier nonfatal WTF records remain documented: TrustManager (1), SystemUI broadcasts (2), and phone SystemConfig access (3).

These are bounded observations. Logcat suppression can hide repetitions, and three matching PID snapshots do not constitute continuous process tracing. This audit does not establish IMS registration, call acceptance or absence of future crashes.
