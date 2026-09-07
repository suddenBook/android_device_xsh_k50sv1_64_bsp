# Source providers and remaining vendor contracts

Source connectivity and native-provider adoption is complete through build19.
The [adoption receipt](../evidence/wmt-paired-runtime-20260907/canonical-adoption.json),
[23 selected native outputs](../evidence/wmt-paired-runtime-20260907/build19-native-providers.json)
and [30-file installed readback](../evidence/wmt-paired-runtime-20260907/runtime/build19-normal-reboot-readback/result.json)
bind that baseline. [HANDOFF](HANDOFF.md) owns subsequent source and installed
identities; a new source commit alone is not an installed result.

| Source provider | Retained hardware implementation | Measured boundary |
| --- | --- | --- |
| Five WMT/WLAN/BT/GPS modules, WMT loader and launcher | RF firmware, ROM patches, board calibration and userspace hardware HALs | Loading, Wi-Fi traffic/cycles, BT discovery, GNSS request/status/stop, local P2P group and ADIE read. No BT listening, GNSS fix, P2P peer transfer or complete module-unload acceptance. |
| Graphics allocator/mapper/composer adapters | MediaTek gralloc/composer and GPU libraries | Display, 32-bit buffer client, screen recording and camera preview delivery; this does not measure photograph quality or shutter latency. |
| Audio service and Bluetooth audio/provider/session set | MediaTek audio/controller implementations and board tuning | Service/PCM startup. AAudio consumed silent playback frames with no xruns; microphone capture and audible Bluetooth routing need separate evidence. |
| Tinycompress | Existing audio consumers; source-kernel sound UAPI | Both ABI layouts/symbols and source-output installation match. The measured product has no compressed ALSA endpoint, so PCM does not prove compressed-ioctl behavior. |
| WLAN calibration loader | Original WIFI calibration and two-byte trailer convention | Complete transfer/readiness and radio reconnection, with unchanged calibration hashes. |
| TinyXML | Existing RIL callers and non-STL ABI | ELF closure and installed source provider. |
| Software Gatekeeper | Existing software handle/scrypt format | Enroll, reject wrong credentials, verify, change, clear and ordinary reboot persistence. This provides no TEE or hardware-held authentication key. |
| Sensors 2.0 bridge and board filter | Legacy MediaTek sensor backend | One accelerometer, finite increasing samples, stop/restart and no callbacks in stopped windows. Exact cadence and calibration are unmeasured. |

The kernel and v2 source launcher are a coupled installation: session and
transaction identifiers bind requests/replies, and legacy metadata setters
cannot provide an untagged fallback. The original launcher ELF remains in
vendor storage only as a factory reference; it is not a pending source
replacement or a selected product provider. Host fixtures establish delayed,
duplicate and malformed reply handling. Build19 separately proves installed
bytes, patch consumption and controlled service restarts; cold userspace
session attribution remains inconclusive.
[Protocol/source evidence](../evidence/wmt-paired-source-20260907/source-validation.json),
[installed runtime](../evidence/wmt-paired-runtime-20260907/runtime.json).

The frozen [build19 ledger](../evidence/wmt-paired-runtime-20260907/build19-adoption-ledger.json)
accounts for the original 506 entries as 476 retained payloads and 30 source
replacements, including the retained-but-unselected launcher reference. Of
those 476 product files, 474 match the original bytes; the processed ImsService
APK and WFO jar match their measured installed predecessor. The older
[per-file assessment](../evidence/vendor-source-inventory-20260905/per-file-adoption.tsv)
is useful for source leads, but its launcher status and revision counts precede
this adoption.

Remaining candidates need actual ABI/behavior comparison: IMS IPsec library
(SR06), MTK power HIDL schemas (SR08), Wi-Fi HAL service (SR10), supplicant and
hostapd commands (SR11), BT transport lifecycle (SR12), USB 1.1 (SR14),
lights/memtrack/thermal reporting (SR15–17), WOD/strongSwan integration (SR18)
and MP3 decoder selection (SR19). Available source is a starting point, not a
compatibility result. Firmware, camera/GPU/codec algorithms, modem code and
board calibration remain explicit dependencies.

For a provider change, regenerate the complete vendor extraction and remove
all replaced install paths for every shipped ABI. Use clean Android output,
check actual Soong/Kbuild providers and ELF/module closure, then verify the
staged images and installed hashes before affected-path tests. Keep failures
and unmeasured behavior distinct. Do not broaden the runtime claim from an
unrelated manual test or a successful compile.
