# Verified hardware and measurement limits

This is the physical baseline. [HANDOFF](HANDOFF.md) owns the latest installed
image and [workitems](../workitems.md) owns unfinished work. Stock labels,
feature declarations and unbound I2C clients do not establish fitted hardware.

| Area | Verified facts | Evidence |
| --- | --- | --- |
| SoC and CPU | MT6755 BSP/ABI; silicon hwcode `0x0326`, hw_ver `0xcb00`, code_func `0x0001`. Eight Cortex-A53 CPUs use the MT6750-class bin: big 1508/1430/1352/1196/1027/871/663/286 MHz; little 1001/910/819/689/598/494/338/156 MHz. Turbo is off. | [Identity](../evidence/live-20260822T202825+0200/identity.txt), [OPPs and silicon](../evidence/live-20260822T202825+0200/soc.txt) |
| GPU | Mali-T860, Midgard r29p0, OpenGL ES 3.2; 676/520/351 MHz. These measured OPPs define this board's operating range. | [GPU and display](../evidence/live-20260822T202825+0200/display_touch_input.txt), [OPPs](../evidence/live-20260822T202825+0200/soc.txt) |
| Memory | 4 GiB LPDDR3 package configuration. Stock rounded MemTotal to exactly 4 GiB while its allocator managed 3,925,620 KiB; use the actual running allocator when budgeting memory. | [Memory/storage capture](../evidence/live-20260822T202825+0200/memory_storage.txt) |
| Storage | Micron `S0J9F8`, eMMC 5.1: EXT_CSD revision `0x8`. Raw user area is 62,537,072,640 bytes. Captured life buckets are `0x01/0x01`, pre-EOL normal; they do not measure remaining endurance. Stock forged `/data` statfs capacity above its partition capacity. | [Memory/storage capture](../evidence/live-20260822T202825+0200/memory_storage.txt) |
| Display/touch | 720×1560 at 60 Hz, physical density 320 dpi; FT8057, five-touch controller, operational I2C address `0x38`. The selected panel is `ft8057s_inx_hdplus1560`. Touch needs no rotation transform. | [Display and input](../evidence/live-20260822T202825+0200/display_touch_input.txt), [I2C](../evidence/live-20260822T202825+0200/i2c.txt) |
| Cameras | Rear driver identifies `imx145_mipi_raw`, sensor ID `0x145`, 8 MP class, flash, orientation 90°. Front is GC5025, 5 MP class, no flash, orientation 270°. Both use HAL1; Camera2 exposes LEGACY compatibility. The rear driver name is not independent verification of the retail sensor part. | [Camera baseline](../evidence/live-20260822T202825+0200/camera_sensors_biometrics.txt), [later preview delivery](../evidence/source-runtime-20260905/build9-camera-preview.json) |
| Motion sensors | MIR3DA accelerometer is populated and emits samples. Light, proximity, compass, gyroscope, pressure and step-counter declarations have no verified hardware; the product's sensor filter exposes only the accelerometer. | [Active sensor probe](../evidence/active-sensor-probe-20260822.txt), [I2C](../evidence/live-20260822T202825+0200/i2c.txt), [source bridge runtime](../evidence/source-runtime-20260905/build8-sensors-log.txt) |
| Hall/stylus | Hall is populated. Insertion/removal emits momentary `KEY_WAKEUP`, not `KEY_SLEEP`. The stylus is passive capacitive, without pressure, hover, button or Bluetooth functions. | [Hall transitions](../evidence/active-hall-probe-20260822.txt) |
| Audio and ports | One bottom speaker, separate earpiece and two physically confirmed microphone apertures. USB-C carries analog headset audio; ACCDET is a real path despite the absence of a 3.5 mm jack. Owner confirmed headset microphone/buttons and sound. OTG storage enumerated and passed read-only media checks. | [Headset routing](../evidence/E-088-usbc-headset.txt), [kernel-review artifacts](../evidence/kernel-review-20260905/) |
| Other physical features | Power/volume keys, ERM vibrator, dual SIM plus separate microSD position. No fingerprint sensor, NFC, IR, wireless charging or RGB notification LED. Decorative rear openings are not additional cameras. The owner's microSD slot was empty during the baseline. | Owner inspection recorded in the reviewed baseline; [input capture](../evidence/live-20260822T202825+0200/display_touch_input.txt) |

The owner measured the punch-hole bounding box on a 1:1 calibration target as
x=330..388, y=12..70 pixels, including its black ring. The cutout is expressed
in pixels, not density-scaled units. Product density and the owner's optional
256-dpi Display Size setting are distinct. Current cutout/status-bar resources
live in the [device overlay](../../../lineage-17.1/device/xsh/k50sv1_64_bsp/overlay/frameworks/base/core/res/res/values/).

The layout is physical non-A/B with separate boot and recovery, boot header v2,
VINTF target level 2, VNDK 29 and first API 26. Partition sizes are:

| Partition | Bytes |
| --- | ---: |
| boot / recovery / odmdtbo, each | 16,777,216 |
| metadata | 33,554,432 |
| vendor | 2,147,483,648 |
| system | 4,294,967,296 |
| cache | 452,984,832 |
| userdata | 55,373,184,512 |

These are [GPT/block-device capacities](../evidence/live-20260822T202825+0200/partitions_mounts.txt),
not image lengths or stock `df` values. Current `/data` is unencrypted F2FS,
`/cache` is ext4 and metadata is unused; see [storage decision](f2fs-feasibility.md).
The owner's unencrypted-data decision is settled. [Scope](../scope.md) defines
allowed flash targets and mandatory userdata/metadata/cache erases.

The cell itself is printed **3.8 V / 12.16 Wh = 3200 mAh nominal**, read by the
owner after removal on 2026-09-04. The back-panel 4000 mAh label is superseded.
Both the kernel nominal full scale and framework battery capacity use 3200.
Donor OCV/ZCV, resistance and temperature/high-current curve shape remain
uncalibrated for this cell; aged usable capacity remains unmeasured.

The selected HAFG20 driver reports `charge_full = Q_MAX_POS_25 × 1000` and
`charge_counter = UI_SOC × Q_MAX_POS_25 × 10`. One percent is therefore
32000 uAh; this counter and BatteryStats are not independent current readings.
`FG_SW_CoulombCounter` reads the hardware-derived CAR accumulator, requires
signed decoding of its unsigned text and can be reset by the gauge daemon.
Use reset-aware windows or external measurement for energy claims. Suspend
counts and awake fractions alone do not establish battery-current savings.

Charging presets are existing board behavior, not calibrated physical current
limits: the fitted sense resistor/chip variant is uncharacterized. Retain the
driver's error handling and explicit preset mapping. On the build19 baseline,
reading `/proc/mtk_battery_cmd/current_cmd` itself stops charging; collectors
exclude it. A pending source correction does not change that installed behavior.

Camera calibration is no longer a pending rear-capture task. In the recorded
front path, GC5025 OTP reads reported empty defect-pixel/chip-version records;
the rear probe/open/preview/capture path did not read CAM_CAL/EEPROM and its
driver has no OTP reader. Both captured images using compiled defaults. This
does not prove a physically absent rear EEPROM or a camera quality ceiling.
The previous dark/soft result changed with the camera API/fps/JPEG path. The
owner's current **4–6 second shutter delay** and picture quality require the
ongoing measured app/HAL investigation; no new repair is declared installed here.

The intermittent GPIO104 keypad column fault remains without a demonstrated
root cause. Current keypad suspend/recovery is kernel-owned; the former init
`kpd_call_state=2` workaround is not the current design. Completed key, touch,
Hall, headset and OTG checks should not be requested again as generic bring-up
tests. Useful remaining physical measurements are the two microphones' actual
roles, battery calibration and owner perception of haptics. The recorded ERM
hand test found 60 ms clear, 40 ms marginal and ≤30 ms weak; framework effect
mapping must be checked before changing a resource.

The audio loudness switch and six `persist.vendor.sys.pq.*` settings have
identified blob readers and shipped parameter files; that establishes a control
path, not better sound or display quality. Their owner-present A/B assessment
remains separate from source correctness and the camera delay investigation.
No new audible or visible benefit is claimed.

The current `thermal.conf` has seven MTK zones and 17 active trips, all with
registered providers and coolers. Intervals are temperature-dependent: CPU has
fast polling, and other zones slow at low temperature. The modem daemon uses
a fixed 5 s select plus 5 s sleep loop; `mdm_timeout` does not control it.
MUTT uses the local AUXADC1 thermistor, while the queried modem RF temperature
feeds the separate PA protection. Keep current protection until actual energy
and temperature-freshness measurements justify a change. See the
[decoded and live review](../evidence/device-review-20260907/thermal/findings.md).
