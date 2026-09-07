# WI-090 / WI-091: bounded read-only thermal review

**No thermal code/config change is required for this build.** The current policy has real providers for all 17 trips on its seven registered MTK zones. Keep the normal policy and modem polling; no measured energy result justifies changing a protection interval. This review supersedes the old constant-poll, old-schema-is-dead, and `.ht120.mtc`-is-currently-active assumptions.

All seven payloads were decoded and byte-exactly re-encoded with `tools/mtk-thermal-conf.py`; input hashes are in `input-manifest.json`. `profiles.tsv` lists every configured zone, active trip/type/cooler, base interval and nonempty slots outside `num_trip`. Read-only captures share boot ID `617ecc06-c2fc-404f-9af7-57a370fc85ce`; no thermal control, service, property or temperature was changed.

## Installed state and providers

`live-paths.txt` reads `/data/vendor/.tp/.settings` as `/vendor/etc/.tp/thermal.conf`; the earlier `live-thermal-state.txt` independently matches its trips and ATM/CTM parameters. All listed trip types are 0 and appear as `active` in sysfs.

Paths below are relative to `lineage-17.1/kernel/xsh/k50sv1_64_bsp/drivers/misc/mediatek/thermal/`. Trip temperatures are m°C. Detailed bindings are in the live capture and `profiles.tsv`.

| Current zone / config | Base ms | Current trip → cooler | Provider |
| --- | ---: | --- | --- |
| mtktscpu / tzcpu | 200 | 108000 → mtktscpu-sysrst; 61000 → cpu_adaptive_0; 58000 → cpu_adaptive_1 | common/thermal_zones/mtk_ts_cpu.c; common/coolers/mtk_cooler_sysrst.c and mtk_cooler_atm.c |
| mtktspmic / tzpmic | 1000 | 145000 → mtktspmic-sysrst | common/thermal_zones/mtk_ts_pmic.c |
| mtktsbattery / tzbattery | 1000 | 60000 → mtktsbattery-sysrst | common/thermal_zones/mtk_ts_battery.c; temperature via read_tbat_value |
| mtktspa / tzpa | 2000 | 120000 → mtk-cl-kshutdown01 | common/thermal_zones/mtk_ts_pa.c reads modem RF temperature populated through mtk_ts_pa_thput.c; mtk_cooler_kshutdown.c |
| mtktswmt / tzwmt | 5000 | 120000 → mtktswmt-sysrst | common/thermal_zones/mtk_ts_wmt.c; WMT temperature callback |
| mtktsAP / tzbts | 1000 | 100000 → mtktsAP-sysrst; 90000 → mtk-cl-kshutdown00; 52000 → mtk-cl-cam00 | common/thermal_zones/mtk_ts_bts.c, AUXADC channel 0; common/coolers/mtk_cooler_sysrst.c, mtk_cooler_kshutdown.c, mtk_cooler_cam.c |
| mtktsbtsmdpa / tzbtspa | 1000 | 120000 → kshutdown02; 95000 → mdoff; 85000 → noIMS; 78000/76000/74000/72000 → mutt03/02/01/00 (all mtk-cl- prefixed) | common/thermal_zones/mtk_ts_btsmdpa.c, AUXADC channel 1; mtk_cooler_kshutdown.c and common/coolers/mtk_cooler_mutt.c |

The eighth sysfs zone, `battery`, has no configured trips here. It is not another `.tp` policy zone. The MUTT/mdoff trips use the local AUXADC thermistor, whereas the daemon-fed `mtktspa` zone uses modem RF temperature. Removing MUTT bindings would not remove the daemon's unconditional query loop.

The numbers above are **base intervals**, not unconditional polling periods. Battery/PMIC/PA/BTS/BTSMDPA use base × 5 at 20–40°C and base × 10 below 20°C; WMT has the same factors. CPU uses `mt6755/src/mtk_tc.c` factors (base below 30°C down to 20°C; twice base below 20°C), and fast polling above the configured threshold. The captured `tzcpu_fastpoll` is `trip 50000 factor 4`: at the captured 60.5°C the driver's calculated delay is 50 ms. Battery at 33°C calculates 5000 ms. Core polling does not check the drivers' `kernelmode` flag (`drivers/thermal/thermal_core.c:497`), so sysfs `mode=disabled` alone is not evidence that these protection paths are off.

## Inert fields and alternate profiles

- All seven contain `tz6311`, but `CONFIG_MTK_PMIC_CHIP_MT6353=y` excludes `mtk_ts_6311buck.o`; the live node and `/proc/mtktz/mtktsbuck` are absent. The buck reset cooler itself exists. These are harmless unmatched configuration pairs, not an absent live protection path. Trimming them could remove loader warnings but has no demonstrated runtime benefit and is unnecessary for this build.
- `thermal.off.conf` additionally references absent `tzabb` / `mtktsabb-sysrst`. Other configured cooler names exist. The `mtkts1..4` monitor nodes missing in the normal capture are not dead providers: the existing `tzts1..4` control writers register those zones when explicitly configured (`mtk_ts1.c:425`, same family for 2–4).
- The normal policy and its 00/01/02 variants have `tzbtspa num_trip=7`; the following `abcct_lcmoff` and `abcct` slots are inactive. Both coolers exist, but increasing `num_trip` would introduce untested charging controls. Leave the count as supplied.
- `.ht120.mtc` disables the ordinary CPU adaptive trips and changes battery reset to 120°C; `thermal.off.conf` also changes several limits. They are alternate diagnostic payloads, not evidence for the normal operating policy, and were not loaded in this review.

## Selector and 10-second modem query

`thermal_manager` Thumb `main` at 0x1044 loads `/vendor/lib/libmtcloader.so`: no arguments calls `loadmtc("/vendor/etc/.tp/thermal.conf")`, one argument calls `loadmtc(argv[1])`, two arguments call `change_policy(argv[1], atoi(argv[2]))`. Both library ABIs export V1/V2 readers; the AArch64 `loadmtc` at 0x204c–0x2158 explicitly dispatches V1 or V2 from the decoded prefix. Therefore the flat off file is supported in principle; absence of `Sec_*` alone cannot prove it dead. The named `change_policy` table contains thermal_sp/vr/vrsp and thermal_policy_00..19. No automatic off/ht120 selector was found in the bounded thermal binaries/rc review; explicit-path loading remains available. No startup evidence selects either one.

The `thermal` process is a single main thread; `thermal_repeater` is its log tag. AArch64 `main` initializes a `timeval {5,0}` from file offset 0xc50, uses it in `select` at 0x2a84, then calls fixed `sleep(5)` at 0x2ae0 on timeout before querying `THERMAL,0,-1` again. This explains the approximately 10-second RIL cadence. The only property read in this main is `ro.vendor.mtk_ps1_rat`; no normal interval property/config input feeds this loop. Kernel `mdm_timeout` exists and was **2** in the capture, but its `signal_period` field only records/displays the old interface; `mtk_mdm_enable/disable` in `mtk_ts_pa_thput.c` do no work and the daemon does not read it. Changing it cannot adjust this 5+5-second loop.

Keep the current loop pending actual unplugged energy and RF-temperature freshness measurements. A future change needs a source-owned daemon/explicit guarded implementation and protection validation; removing coolers or writing `mdm_timeout` is not a verified fix. This bounded review found no thermal defect that should delay the present integration build.
