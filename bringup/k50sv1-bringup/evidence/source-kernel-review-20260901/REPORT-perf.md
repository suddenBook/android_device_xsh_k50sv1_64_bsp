# k50sv1_64_bsp: source-built 3.18.119 vs vendor prebuilt kernel - lag / heat / drain root-cause report

Date: 2026-09-01 (device uptime ~47-82 min during measurement). Read-only session; the only
state changes made on the device were input key events (`input keyevent KEYCODE_WAKEUP/82/HOME`)
to light the panel for the screen-on tests and `KEYCODE_SLEEP` to restore it; `mWakefulness=Asleep`
was verified restored after each test.

Raw samples (this directory):

| file | content |
|---|---|
| idle_samples.txt, idle_timeline.txt, top_samples.txt | 30 x 2 s idle samples (screen OFF) + parsed timeline, IRQ/wakeup-source deltas, top |
| batch2.txt | clean 20 s idle (/proc/stat, /proc/interrupts, softirqs), top -H, cpuidle/spm debug nodes, HICA settings, vcorefs, init.rc greps |
| quiet_hps.txt | 60 s fully quiet window (screen off, no sampling): stat/dmesg/HPS/uevent deltas, ged nodes |
| static_dump.txt | /proc/hps, /proc/ppm, /proc/cpufreq, /proc/eem, /proc/gpufreq, /proc/driver/thermal/*, cpuidle, thermal sysfs, mmc, thermal_manager files, getprop, meminfo |
| opp_eem.txt | both clusters' OPP/voltage tables, EEM status, rq-stats heavy-task |
| load_test.txt | screen-OFF single-thread / 4-thread load timelines + first dd attempt |
| load_test_screen_on.txt, hica_probe.txt, hica_probe2.txt | screen-on load probes (keyguard shown / dismissed) |
| screen_on_idle.txt | 60 s screen-on (launcher) idle observation |
| perfd_probe.txt | perfmgr nodes, which binaries touch PPM nodes, powerscntbl.xml, PPM dmesg |
| battery_dd.txt | power_supply state, battery dmesg, eMMC dd runs, IRQ spot check |
| dmesg_idle_start.txt, dmesg_idle_end.txt | full dmesg before/after the idle window |
| source_config_relevant.txt, stock_nm.txt, stock_strings.txt, source_symnames.txt, stock_text.txt, source_text.txt | config and symbol material |
| dmesg_early_vs_prebuilt.diff, pb_tmpl.txt, src_tmpl.txt | normalized boot-log diffs (prebuilt vs source early boot) |
| kdis.py | capstone helper for the stock ELF (its `.kernel` section is really loaded at 0xffffffc000080000, not the 0x82000 the section header claims) |

## 1. Idle window (screen OFF): 30 samples over 104 s, a clean 20 s window, and a fully quiet 60 s window

Timeline (idle_timeline.txt): online mask oscillated 0 / 0-1 / 0-3; LL cluster at 1001 MHz
(interactive, scaling_min_freq=598000 from init); L cluster (cpu4-7) never online; loadavg
9.5-10.2 (the known nine-D-state-threads artefact, same as prebuilt E-027/HANDOFF); PPM state
LL_ONLY with PPM_POLICY_LCM_OFF activated (screen off - correct); Tcpu 37.8-45.5 C, Tpmic
35.5-37.8 C, Tbat 30.7 C; GPU 520000 kHz / 1.0 V (identical to prebuilt evidence, see 4.7);
PPM thermal limit inactive (limited power = 0, current power 323 mW).

CPU busy during the sampler window was 32-80 % of the online CPUs and IRQ rates were IPI0
21190/s, musb-hdrc 3539/s, arch_timer 2106/s. These are artefacts of the sampler itself
(cat/grep/dmesg processes + adb USB traffic) and of Play Store background installs
(com.android.vending at nice 10 dominated top). Proof - the fully quiet 60 s window
(quiet_hps.txt, screen off, nothing running):

    /proc/stat delta 60 s: user 18  nice 5  sys 19  idle 5955 jiffies -> 0.7 % busy (2 CPUs online)
    dmesg lines in window: 0   [HPS] END in window: 0   uevent WARNs in window: 0
    IRQ spot check (5 s): arch_timer 35/s, IPI0 ~5/s, musb 1/s

No interrupt storm and nothing spinning at idle; the source kernel is as idle as the prebuilt
(E-027: 97 % idle). wakeup_sources: only USB.lock held (cable attached). cpuidle: only rgidle
(WFI) is ever entered; dpidle/SODI/SODI3 are blocked by INFRA2 CG bit 1
(dpidle_block_mask[INFRA2]=0x2, 51604 blocks) - the same block mask the prebuilt shows in its
10-hour log (soidle_block_mask: 0,0,0x00000002,... in evidence/audit-20260831T130440Z/01-dmesg.txt).
MCDI is off in both kernels (4.6).

## 2. Load response

Screen OFF (load_test.txt): 1 thread x 20 s -> stays LL_ONLY, cpu0-2 at 1001 MHz, L cluster never
online (correct: ppm_trans_rule_LL_ONLY_to_L_ONLY() returns false while
ppm_lcmoff_is_policy_activated(); LCM_OFF caps cluster 1 at 0 cores). 4 threads -> 4LL_L within
1.3 s, all 8 online, cpu4 at 1508000, HPS toggles cores 5-7 every second (online 0-7 <-> 0-4);
Tcpu 40 -> 52.6 C in 20 s; back to LL_ONLY 1 s after the load ends.

Screen ON, keyguard dismissed (hica_probe2.txt, screen_on_idle.txt): the porter's daemon
k50sv1_perfd writes perfserv_perf_idx=5616 (max index) as soon as the backlight is lit and 0 when
it goes dark (dmesg: "@ppm_perfserv_perf_idx_proc_write: get perf_idx = 5616" right after
"@ppm_lcmoff_switch: onoff = 1"). Result: state 4L_LL, all 8 cores online, LL 1001 MHz and L
1508 MHz with min = max for the whole screen-on time - 58 s at the launcher with 2.7 % CPU busy.
A 20 s single-thread loop therefore runs with the SoC already at maximum; Tcpu 40 -> 47.5 C.
This is identical on the prebuilt (E-032; the prebuilt 10-hour dmesg shows the same k50sv1_perfd
transitions), so it is not a kernel regression, but it is what makes the phone hot and then
throttled whenever it is used (section 5).

HICA settings (batch2.txt) are the MTK defaults: LL_ONLY->L_ONLY needs LL at max freq for 8
samples or loading > 380 for 4 samples, mode_mask 6; /proc/ppm/mode = Performance is the
compile-time default in both trees (mt_ppm_main.c:53 .cur_mode = PPM_MODE_PERFORMANCE).

## 3. Storage

/dev/block/mmcblk0p28 (system), HS400 200 MHz 8-bit (/sys/kernel/debug/mmc0/ios), scheduler
deadline, read_ahead_kb 128, nr_requests 256:

    dd bs=4M count=64 skip=200 : 268435456 bytes, 1.10 s, 232 MB/s (uncached)
    dd bs=4M count=64 skip=300 : 268435456 bytes, 1.26 s, 203 MB/s (uncached)
    dd bs=4M count=64 skip=200 : 268435456 bytes, 0.26 s, 987 MB/s (page cache)

Both boot logs contain the identical 74 msdc0/autok lines (same HS400 tuning path); the msdc1
CMD<55>/CMD<8>/CMD<1> Error<-110> lines are the empty SD slot being probed and appear in the
prebuilt boot log too (18 in the 2026-08-23 stock boot). Storage is not a factor.

## 4. Kernel-side comparison (stock ELF / prebuilt logs vs Nokia-tree source build)

Method: text-symbol set diff (stock 46449 T/t symbols, source 48087; the only source-only
symbols in power/thermal/idle/cpufreq/hps/ppm/msdc/gpu are the *_exit functions), strings diff,
normalized dmesg diff (dmesg_early_vs_prebuilt.diff; template diff pb_tmpl.txt/src_tmpl.txt),
runtime table dumps, and capstone disassembly of the stock ELF where a data default had to be read.

4.1 cpufreq/EEM: _mt_cpufreq_get_cpu_level present in both; runtime OPP tables equal (LL
1001/910/819/689/598/494/338/156, L 1508/1430/1352/1196/1027/871/663/286 MHz). EEM voltages: LL
106875,104375,101250,97500,95000,91875,86875,80000 (identical to prebuilt evidence soc.txt); L
101875,100625,98750,95625,91875,88750,85000,80000 vs prebuilt 102500,100625,99375,95625,92500,
89375,85000,80000 (within EEM per-boot jitter). "eem_init02 called by [eem_init01]" in both;
/proc/eem/EEM_DET_* enabled and converged; enable_cpuhvfs=1 and [CPUHVFS] in both. No difference.

4.2 HPS: identical init prints (hps_ctxt.is_hmp: 0, cpumasks 0-3/4-7) and identical runtime knobs
(up 95 / down 85, up_times 3 / down_times 1, rush_boost 1 @98, num_base_perf_serv "1 0",
num_limit_thermal "4 4"). Hotplug rate: 0 events in the quiet 60 s window; the 653 [HPS] END in
the first-boot continuous log (249 s) match the prebuilt's own boot rate (119 in 40 s). Earlier
"33-67/min" figures were inflated by the sampler and Play Store installs.

4.3 PPM: same 11 policies/priorities, same 120-entry power table (max 2371 mW), same HICA rule
code (mt_ppm_power_state.c:315), same default mode. Transitions: source 16 in 12.7 min (with
sampler) vs prebuilt 6 in 13.3 min (with audit scripts) - same order.

4.4 Thermal: tscpu_init -> tscpu_bind from swapper at 0.53 s in BOTH logs, and thermal_manager
(pid 589 prebuilt / 580 source) unbinds+rebinds at 13.6-13.7 s in BOTH; the vendor policy from
/vendor/etc/.tp/* is applied identically: tzcpu trips 108000 sysrst / 61000 cpu_adaptive_0 /
58000 cpu_adaptive_1; clatm_setting cpu_adaptive_00 first_step 2500, theta 15/20, m cpu 600,
M cpu 3000, gpu 550/1600; clatm ratios all 1. The ATM throttles the same way on both: stock boot
"set_adaptive_cpu_power_limit 614 T=62500 ... 68300"; source "1107-1907 mW at 61-66 C",
"1707 mW at T=71400". The 3000 mW "M cpu" ceiling is above the whole-SoC max (2371 mW) and never
limits; only the adaptive limits above 58/61 C bite.

4.5 vcorefs/DDR: identical OPP table (OPP0 1.0 V/1796 MHz, OPP1 0.9 V/1300 MHz), same SPM PCM
firmware strings (pcm_dvfs_v0.1_160210_02, pcm_dvfs_v0.1_170802_01 in both ELFs), same [VcoreFS]
boot prints (curr 1000000 uV / 1664000 kHz at boot in both). At runtime [KIR_GPU] opp: 0 holds
HPM; the prebuilt shows the same gpufreq state (4.7).

4.6 cpuidle/SODI/MCDI: idle_switch[] read from the stock ELF .data (via mcidle_state_write ->
"str w2,[idle_switch+0xc]" at 0xffffffc00110bec4) = {1,1,1,0,0,1} = dpidle, soidle3, soidle on,
mcidle OFF, slidle off, rgidle on - byte-identical to the source (spm_v2/mt_idle_mt6755.c:52;
CONFIG_CPU_ISOLATION is not a Kconfig symbol in this tree so the #ifdef is always false). Same
"Power/swap DP: No enter --- SODI3: No enter --- SODI: No enter" in both. No difference.

4.7 GPU: Mali Midgard r29p0-01dev0 in both; same 3-OPP table (676/520/351 MHz, 1.0/1.0/0.9 V);
prebuilt evidence gpufreq_var_dump shows the same "g_cur_gpu_freq = 520000, g_cur_gpu_OPPidx = 2,
_mt_gpufreq_get_cur_freq = 351000, volt_enable_state = 0" as the source. ged DVFS nodes present.

4.8 MSDC/autok: identical boot lines, HS400 200 MHz in both.

4.9 clkbuf/DCM: final clk_buf_pmic_wrap_init values identical (0x4dfd/0x8aaa); the only DCM
register that differs is MCUCFG_CCI_CLK_CTRL 0x157 (stock) vs 0x117 (source) - bit 6, not the DCM
enable (bit 8, mt_dcm.c:670), so CCI DCM is on in both.

4.10 Scheduler: HMP/CMP symbols (hmp_force_up_migration, hmp_select_task_rq_fair, hmp_idle_pull,
...) present in both; htask_threshold=650 heavy-task tracking active. 4.11 mtk_wdt: same
symbols, mtk_watchdog IRQ registered; nothing found.

4.12 add_uevent_var WARNING: SOURCE ONLY (0 in every prebuilt log). Backtrace: add_uevent_var+0x110
<- power_supply_uevent+0x194 <- kobject_uevent_env <- power_supply_changed_work (also from
battery_probe/battery_init_work_callback at boot). Cause: the battery power supply in
drivers/power/mediatek/battery_common_fg_20.c declares 31 properties (battery_props[], incl. FIH
additions POWER_SUPPLY_PROP_bat_id / bat_id_volt at :369/:390); power_supply_uevent() adds
POWER_SUPPLY_NAME + one env var per property on top of ACTION/DEVPATH/SUBSYSTEM/SEQNUM, exceeding
UEVENT_NUM_ENVP 32 (include/linux/kobject.h:32). Every battery uevent fails with a full stack dump
(78 in a 760 s window, 238 in the earlier window) and is never delivered. The prebuilt exposes 12
attributes on /sys/class/power_supply/battery (evidence live-20260822 power_thermal.txt).

4.13 Battery/charging: SOURCE ONLY: "[BATTERY]Battery is invalid !!" + "BAD Battery status...
Charging Stop !!" every 10 s from bat_routine_thr, from the first cycle at 3.7 s after boot.
mt_battery_CheckBateryIsValid() (battery_common_fg_20.c:2559-2568, called from
mt_battery_CheckBatteryStatus() at :2674 before the temperature check) sets CHR_ERROR whenever
battery_main.bat_id == -1. bat_id comes from fgauge_get_profile_id() (battery_meter_fg_20.c:545-591),
which matches g_bat_id_volt against g_battery_id_voltage[] (TOTAL_BATTERY_NUMBER 2,
BAT_ID_POS_NEG_VOLTAGE_ERR_RANGE 150000, mt_battery_meter_table_multi_profile.h:39-40), and
g_bat_id_volt is only ever set from a "bat_id_volt=" kernel command-line parameter
(__setup("bat_id_volt=",...), battery_meter_fg_20.c:531-536) that this phone's LK never passes
(cmdline identical in both boot logs, no bat_id_volt=). Boot log: bat_id_volt(0), bat_id(-1),
"Battery id (-1)". The string "Battery is invalid" does not exist in the stock ELF
(stock_strings.txt has only the generic "BAD Battery status... Charging Stop !!"), i.e. this is
FIH/Nokia code the K50 vendor kernel never had. Measured now with USB attached: status=Discharging,
current_now=-78200 uA, usb/online=1, ChargerVoltage=5024 mV, psc5415 REG1=0x74 (CE bit set =
charging disabled). Prebuilt evidence: status Full, current_now +146400 uA, boot log "Pre-CC mode
charge"/"CC mode charge". The phone NEVER charges on the source kernel. (FIH_CHARGE_PSE is defined
at mt_charging.h:131; its PSE table is in 0.1 C units - {600,2000,POWER_OFF,...} - consistent
with the driver's "T 292" readings, so the temperature check passes once the ID check is fixed.)

4.14 Not reproduced: "PM: Some devices failed to suspend", "suspend warning: SYS_MD1/SYS_CONN is
on!!!", "[UART1][PinC]switch_uart_gpio pinctrl_lockup fail err:-19" are not present in any capture
available to me (the 1 MB log had wrapped); with the cable attached USB.lock keeps the system
awake so no suspend can be attempted. switch_uart_gpio() is
drivers/misc/mediatek/uart/mt6735/platform_uart.c:2291; -19 (ENODEV) means the DT pinctrl state
for the UART1 sleep/lockup mode is missing, so UART1 pins are not switched to GPIO before sleep
(minor leakage when unplugged; not measurable here).

## 5. Ranked kernel-side causes

1. Charging is disabled by FIH battery-ID validation (drain). Evidence 4.13. Plugged in, the
   battery still discharges (-78 mA at idle); unplugged, every session starts from whatever
   charge is left. Confidence: high.
2. Battery uevent overflow storm. Evidence 4.12. One WARNING + ~35-line backtrace per battery
   uevent; the 1 MB dmesg wraps in ~13 min; logd showed 27 % CPU while a logcat was attached;
   healthd/BatteryService never receive POWER_SUPPLY uevents (they survive on polling).
   Confidence: high. Not a heat source by itself, but a measurable regression.
3. Heat -> ATM throttling -> laggy UI is driven by the screen-on max pin, which is the same on both
   kernels. k50sv1_perfd (device/xsh/k50sv1_64_bsp/perfd/k50sv1_perfd.c: "hold the SoC at
   maximum while the panel is lit") pins PERF_SERV at idx 5616 -> 8 cores at 1001/1508 MHz
   (min = max) whenever the backlight is on. Under real use the SoC reaches the vendor trips:
   dmesg shows Tj up to 71.4 C and 43 set_adaptive_cpu_power_limit events (budgets 1107-1907 mW,
   roughly LL 598 MHz + L 1027 MHz) in a 13-minute window nine minutes before this session,
   while the prebuilt 10-hour log shows 0 such events in its 13-minute window. Kernel thermal
   tables, ATM parameters, OPP/voltage tables, idle states, DVFS firmware and GPU state are
   identical (4.1-4.11), so the kernel does not throttle differently; the source kernel spends
   more time hot because of (1) (system running from the pack while "charging" adds I2R heat in
   pack/PMIC; Tpmic rose 1.5 C over the 58 s screen-on idle) and because usage since the flash
   (setup, installs) was heavier. Confidence that the perfd pin is the amplifier: high; that it
   is a kernel regression: low (userspace design).
4. Nothing else kernel-side differs measurably: cpufreq/EEM, HPS thresholds and rate, PPM
   policies/HICA, thermal trips/ATM, vcorefs table and SPM firmware, cpuidle switches, GPU
   driver/table/state, MSDC HS400, DCM/clkbuf final values, HMP scheduler, idle CPU load (0.7 %),
   IRQ rates at rest. slub_debug=OFZPU is on the cmdline of both, but CONFIG_SLUB_DEBUG is not
   set in the source build so it is inert.

Measurement artefacts (do not chase): IPI0 21k/s, musb 3.5k/s, 30-80 % "idle" busy,
33-67 hotplug/min - all vanished in the quiet window (0 dmesg lines, 0.7 % busy, arch_timer
35/s). loadavg ~10 is the known D-state-thread artefact.

## 6. Exact source locations that differ from stock behaviour

| what | file:line (Nokia tree) | stock evidence |
|---|---|---|
| invalid-battery charging stop | drivers/power/mediatek/battery_common_fg_20.c:2559-2568 (mt_battery_CheckBateryIsValid), call at :2674 | "Battery is invalid" absent from k50-stock-vmlinux.elf; stock charges ("CC mode charge") |
| battery-ID from cmdline | drivers/power/mediatek/battery_meter_fg_20.c:531-536 (__setup("bat_id_volt=")), :545-591 (fgauge_get_profile_id), :572 (fih_hwid) | cmdline identical, no bat_id_volt= |
| multi-profile enable | drivers/misc/mediatek/include/mt-plat/mt6755/include/mach/mt_battery_meter.h:173 (MTK_MULTI_BAT_PROFILE_SUPPORT); mt_battery_meter_table_multi_profile.h:37-40 | - |
| 31 power-supply properties | battery_common_fg_20.c battery_props[] (31 entries; bat_id/bat_id_volt at :369/:390) vs include/linux/kobject.h:32 UEVENT_NUM_ENVP 32 | stock sysfs shows 12 attributes; 0 add_uevent_var warnings in any stock log |
| UART1 pin switch | drivers/misc/mediatek/uart/mt6735/platform_uart.c:2291 (switch_uart_gpio) | not in stock logs (unverified) |
| identical (verified) | base/power/mt6755/mt_cpufreq.c tables; ppm_v1/src/mach/mt6755/mt_ppm_power_state.c:315 HICA rules; ppm_v1/src/mt_ppm_main.c:53 mode; spm_v2/mt_idle_mt6755.c:52 idle_switch; thermal/mt6755/src/mtk_ts_cpu.c bind path; mt6755/mt_gpufreq.c:1772-1782 KIR_GPU; mt6755/mt_dcm.c:670; hps defaults | same symbols, same runtime values, same boot prints |

## 7. Recommended fixes (source changes)

1. battery_meter_fg_20.c / battery_common_fg_20.c: make the FIH battery-ID check a no-op when no ID
   voltage was supplied - in fgauge_get_profile_id() return id = 0 (profile 0) when
   g_bat_id_volt == 0, and/or make mt_battery_CheckBateryIsValid() return PMU_STATUS_OK unless
   bat_id_volt= was given (or #undef MTK_MULTI_BAT_PROFILE_SUPPORT in mt_battery_meter.h:173 so
   fgauge_get_profile_id() degenerates to g_fg_battery_id = 0 and battery_main.bat_id stays 0).
   Verify: status=Charging, positive current_now, "CC mode charge" in dmesg, psc5415 REG1 CE clear.
2. Fix the uevent overflow: trim battery_props[] to the standard set (drop the FIH extras; stock
   exposes 12) or raise UEVENT_NUM_ENVP to 64 in include/linux/kobject.h (UEVENT_BUFFER_SIZE 2 kB
   still fits 33 short vars). Verify: no "add_uevent_var: too many keys" after boot.
3. (Userspace, but it is the heat amplifier) reconsider k50sv1_perfd's permanent
   perfserv_perf_idx=5616 pin: a screen-on floor (e.g. cluster mins ~598/871 MHz) or the 5 s
   LAUNCH/INTERACTION hints already in powerscntbl.xml keep responsiveness without parking the
   SoC at the ATM trip points (58/61 C; budgets ~1.1-1.9 W above 62 C are reached within seconds
   of real load when 8 cores are pinned at the top OPP).
4. Low priority: provide the UART1 pinctrl sleep/lockup state in the DT (or guard the call) so
   switch_uart_gpio() stops failing with -ENODEV; re-check "SYS_MD1/SYS_CONN is on" only when a
   suspend can actually be attempted (cable detached).
5. No change is warranted in cpufreq, hps, ppm, thermal, cpuidle/SODI/MCDI, vcorefs, gpufreq,
   msdc or mtk_wdt - verified identical to the stock kernel in code, tables and runtime behaviour.
