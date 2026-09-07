# K50 stock vs source kernel: subsystem-level symbol/code map

Date: 2026-09-01. Read-only analysis; no phone access, no tree modification.

Inputs
- Stock: /home/desmond/Downloads/k50sv1_64_bsp/work/.capture-staging/k50-stock-vmlinux-base80000.elf
  (47,056 recovered kallsyms entries: 25,145 T / 21,744 t / 166 W / 1 A -> text symbols only, CONFIG_KALLSYMS_ALL=n).
  NOTE: k50-stock-vmlinux.elf maps the blob at 0xffffffc000082000 but the blob starts with the arm64 Image header
  (magic ARM\x64, text_offset 0x80000), so symbol addresses only line up with the bytes in the -base80000 variant
  (blob at 0xffffffc000080000). Names/addresses are identical in both; byte-level reads must use base80000.
- Source: .../out/target/product/k50sv1_64_bsp/obj/KERNEL_OBJ/{vmlinux,System.map,.config};
  tree HEAD 8915ee352bf2 "ASoC: mt6750: restore K50 external speaker audgpio".
- Both: "Linux version 3.18.119 (nobody@android-build) (gcc version 4.9.x 20150123 (prerelease))" -> same toolchain,
  function sizes/instruction streams directly comparable.
- Stock build path strings: /ssd/gl/mtk6750_Q/kernel-3.18/... (vendor tree "mtk6750_Q"). No ALPS./MOLY. string in either.

## 1. Symbol-set comparison (text symbols; .isra/.part/.constprop/.cold stripped)

| set | count |
|---|---|
| stock text symbols raw / normalized | 46,449 / 46,198 |
| source text symbols raw / normalized | 48,087 / 47,851 |
| common | 45,109 |
| stock-only | 1,089 (only_stock.txt) |
| source-only raw | 2,742 (only_source.txt) |
| source-only after removing kallsyms-invisible noise | 593 (only_source_filtered.txt) |

Noise removed from source-only: 645 __event_* tracepoint pointers, 1,112 linker/section markers (__initcall_*, __ksymtab_*,
*_parents clk init-data, ...) and 382 .exit.text functions (*_fini, *_exit, cleanup_*; only_source_exitfuncs.txt) -
kallsyms never lists .exit.text or init data. Of the 593 left, 72 are k50_*/FIH_*/fih_* drivers, ~100 are FIH "fih_info"
procfs show/open fns (imei/sim/hwid/skuid/poweroncause/...), the rest init-data symbols typed t by System.map.

### 1b. Instruction-level comparison of the 45,109 shared functions (codecmp.py)
Bodies compared with relocation-dependent fields masked (ADRP/ADR, B/BL imm26, ADD/SUB imm12, LDR/STR imm12, LDR-literal).
Result: 44,570 of 45,109 shared functions are instruction-identical; 539 differ (268 differ in size).

| subsystem | common | identical | differing |
|---|---|---|---|
| cpufreq mt_cpufreq* | 30 | 30 | 0 |
| hotplug hps_* | 90 | 90 | 0 |
| ppm_* | 235 | 235 | 0 |
| thermal (tscpu_*, mtkts*, _cl_*, mtk_cooler*) | 323 | 321 | 2 (mtktsbattery_get_temp, mtk_thermal_get_gpu_info) |
| SPM (spm_*, __spm_*, slp_*, vcorefs*) | 219 | 218 | 1 (slp_suspend_ops_enter: FIH gpio-dump hook) |
| idle (dpidle*, soidle*, mcdi*) | 67 | 67 | 0 |
| sched/HMP | 108 | 108 | 0 |
| ccci | 393 | 391 | 2 (port_rpc_recv_match, ccci_ft_inf_show) |
| ccmni | 19 | 13 | 6 (rx_callback, start_xmit, open, init, md_state_callback, napi_poll) |
| xfrm/esp/ah | 381 | 381 | 0 |
| netfilter (nf_*, xt_*, ipt_*, ip6t_*) | 348 | 348 | 0 |
| audio AudDrv/AFE/mt6353 codec | 333 | 330 | 3 (mtk_mt6331_codec_dev_probe/remove, static open) |
| audio speaker path (Ext_Speaker_*, AudDrv_GPIO_*) | 18 | 17 | 1 (Ext_Speaker_Amp_Set) |
| accdet | 251 | 242 | 9 |
| kpd | 25 | 25 | 0 |
| pmic mt6353/pmic_/upmu_ | 5514 | 5512 | 2 (upmu_is_chr_det, pmic_throttling_dlpt_init) |
| gpu ged/gpufreq | 297 | 291 | 6 |
| msdc | 151 | 151 | 0 |
| musb/usb | 89 | 88 | 1 (musb_gadget_enable) |
| wdt | 21 | 21 | 0 |
| clk/dcm/eem/devinfo/rtc/auxadc/vibrator/leds/wmt/emi | all | all | 0 |
| ION | 186 | 162 | 24 |
| m4u | 141 | 134 | 7 |
| cmdq | 495 | 489 | 6 |
| disp/lcm/dsi | 510 | 491 | 19 |
| gpio/pinctrl | 97 | 87 | 10 |
| camera hw (kdCISModulePowerOn, mtkcam_gpio_*, Get_Cam_Regulator) | 83 | 80 | 3 |
| lens MAINAF (AF_*, MAINAF_i2C_init) | 13 | 2 | 11 |
| charger/battery (psc5415_*, BAT_*, battery_*, bmr_*, charging_*) | 173 | 96 | 77 |
| typec wusb3801_* shared names | 3 | 0 | 3 |

Lists: common_differing.txt (539), common_identical.txt (44,570), size_delta_common.txt.
Caveat: masked fields hide data-table contents and constants passed via ADD/LDR immediates; MOVZ/CMP immediates and control flow compared exactly.

## 2. Stock-only clusters (1,089 symbols)

| cluster | ~count | representative symbols | relevance |
|---|---|---|---|
| Accelerometer: mir3da_* (56), msa_* (58, MSA300 driver), NSA_* calibration (5), proc/subsys_{mir3da,msa300}dir_info_* (6) | 125 | mir3da_probe, mir3da_module_detect, mir3da_direction_remap, mir3da_temp_calibrate, msa_probe, msa_module_detect, msa_cycle_read_xyz, NSA_NTO_auto_calibrate, NSA_calibrate | Accelerometer: HIGH. Stock ships two drivers (4b); source only k50_mir3da_* (28). |
| ALS/PS framework + STK3x3x + AAL: als_*, ps_*, alsps_*, stk3x3x_*, stk_ps_*, AAL_*, light_*, proximity_* | 141 | alsps_init, alsps_driver_add, stk3x3x_i2c_probe, stk3x3x_read_ps, ps_report_interrupt_data, AAL_unlocked_ioctl | Not in regression list; whole light/proximity sensor absent in source (CUSTOM_KERNEL_ALSPS off). |
| Touch: ILITEK (ili_*, ilitek_*, MP-test mp_*, parser_*, *_test), Focaltech fts_* (ft8006sp/ft8006u upgrade, ESD, gesture, sysfs), Silead GSL (gsl_*, Gesture*, Point*, KeyMap) | 378 | ilitek_plat_probe, ili_fw_upgrade, fts_ts_probe, fts_fwupg_upgrade, fts_esdcheck_init, gsl_alg_id_main, tpd_local_init, tpd_suspend/resume | Touch works in source with a smaller ft8057 driver (63 fts_/tpd_ fns). |
| Camera lens/AF/OIS: 20 *AF_* drivers x {Ioctl,Release,SetI2Cclient}_{Main,Main2,Sub} + SUBAF_i2C_init + LC898122/212 OIS helpers (Ini*, Tne*, RamWrite32A_*, I2C_OIS_*, Gyr*, Srv*, Stb*), s4EEPROM_ReadReg* | ~220 | AD5820AF_*, AK7371AF_*, BU6424AF_*, BU6429AF_*, BU63165/63169AF_*, DW9714/9718/9718S/9719T/9814AF_*, FM50AF_*, LC898122/212/212XD/212XDAF_F/212XD_TVC700/214/217AF_*, WV511AAF_*, SUBAF_i2C_init, setVCMPos, setOISMode | Camera: MEDIUM. Source keeps only DW9761AF in MAINAF and has no SUBAF driver (stock DTS has camera_sub_af@1c). |
| Image sensors: 8 extra *_SensorInit + static helpers (sensor_init, preview_setting, capture_setting, read_cmos_sensor, write_cmos_sensor_8/16, set_mirror_flip, set_gain, return_sensor_id, get_otp_*, otp_*, wb_gain_set, IMX135MIPI_set_Video_IHDR) | ~45 | SP2508MIPISensorInit, GC5025MAINMIPI_RAW_SensorInit, GC5025MIPI_RAW_SensorInit, OV5670_MIPI_RAW_SensorInit, GC2355_MIPI_RAW_SensorInit, S5K5E2YA_MIPI_RAW_SensorInit, GC2235_RAW_SensorInit, IMX135_MIPI_RAW_SensorInit, IMX278_MIPI_RAW_SensorInit | Front camera: HIGH (4a). |
| Fingerprint Silead silfp_* (SPI + REE) | 38 | silfp_probe, silfp_ree_ioctl, silfp_netlink_send, silfp_fb_callback | absent in source (CONFIG_SILEAD_FP dropped). |
| NFC MT6605 mt6605_*, mt_nfc_*, ccci inform_nfc_vsim_change | 14 | mt6605_probe, mt6605_dev_unlocked_ioctl, mt_nfc_pinctrl_select | absent in source (CONFIG_MTK_NFC off). inform_nfc_vsim_change = ccci<->NFC vSIM hook. |
| Type-C WUSB3801 stock implementation + sysfs f*_show/store | 13 + 14 | wusb3801_i2c_init, wusb3801_interrupt, wusb3801_work_handler, wusb3801_set_dfp_power, fmode_show/store, fhostcur_show/store, fregdump_show | source has a rewritten driver (16 fns); shared probe/remove/shutdown bodies differ. |
| USB-C analog headphone: bct4321_switch, typec_headphone_irq_handler | 2 | - | headset via USB-C (BCT4321 switch); not the loudspeaker. |
| Hall hall_* | 8 | hall_eint_handler, hall_setup_eint, hall_unlocked_ioctl | replaced by k50_hall_* in source. |
| Keypad gpiokey_* (+proc) | 7 | gpiokey_init_pre, gpiokey_probe, proc_gpiokey_info_write | Keypad: check. Stock GPIO-key driver (DT gpiokey_eint) with no source counterpart; MTK kpd_* core identical (25 fns). |
| LCM/bias glue: _lcm_gpio_*, lcmbias_gpio_init, tps65132_init, tps65132_write_bytes_kernel, set_bias_enn/enp_gpio, set_lcd_1_8v_gpio, set_tpldo_gpio, _tpldogpio_*, lcm_ata_check, lcm_info_proc_create, get_lcm_info_fun | 18 | - | display works in source (k50_lcm_bias_*, lcm_enp/enn_setting, tps65132_driver_init). |
| ION extras: ion_cache_flush_all, ion_cache_sync_flush, ion_dma_map_area_va, ion_dma_unmap_area_va, ion_dma_op, compat_get_ion_custom_data | 6 | - | plus 24 shared ION fns differ; may matter for camera/GPU buffers. |
| Charger extras: psc5415_user_space_probe, show/store_psc5415_access, charging_parameter_to_value, charging_value_to_parameter, bmt_find_closest_level | 6 | - | see section 5. |
| Vendor sysfs/proc: syscust_* (8), hdf_proc_*/hdf_ram_proc_* (6), get_emmc_life_a/b + ufs_life_proc_* (4), subsys_*/proc_*_info (lcm, silfp) | ~22 | syscust_init, syscust_logo_index | vendor userspace may read these. |
| accdet: Accdet_PMIC_IMM_GetOneChannelValue | 1 | - | source uses accdet_hrtimer*; 9 shared accdet fns differ. |
| unprefixed helpers i2c_read, i2c_smbus_read/_block/write, core_i2c_write, RD_I2C, WR_I2C, msdelay, squareRoot, quicksort, compare_s32 | 11 | - | static helpers of touch/accel/OIS drivers. |
| erratum 843419 veneers e843419@* | 9 (source 6) | - | noise. |

Nothing from cpufreq/hps/ppm/thermal/spm/idle/ccci/ccmni/xfrm/netfilter/gpu/pmic/msdc/usb/wdt/sched is stock-only.

## 3. Source-only clusters (593 real symbols)

| cluster | count | representative symbols | note |
|---|---|---|---|
| Reconstructed board drivers k50_* | 36 | k50_mir3da_* (28), k50_hall_* (5), k50_lcm_bias_* (3), k50_ft8057_set_hall_state, k50_lookup_state | previous session. |
| FIH/Nokia hooks FIH_*, fih_* | 36 | FIH_gpio_dump_regs2file, fih_is_otg_en, fih_gethwid, fih_read_gsensor_cali, fih_read_ps_thd, fih_imei_setup, fih_info_set_lcm | fih_is_otg_en is wired into upmu_is_chr_det (section 5). |
| FIH fih_info procfs | ~100 | imei_open/show, sim1_show, hwid_info_show, poweroncause_show, rtc_mark_*, cavis_*, cda_user_*, otg_last_flag_*, uicolor_* | harmless. |
| Camera: GC5025_MIPI_RAW_SensorInit, FL_Init, FL_dim_duty, RT4505_init/probe/remove, kd_cam_cal_dev | 7 | - | source flashlight = constant_flashlight + RT4505 (stock: constant_flashlight only). |
| Focaltech FT8057 fts_* (source flavour) + tpd_prepare_suspend, tpd_set_prepare_suspend | 15 | fts_i2c_probe, fts_irq_thread, fts_tpd_local_init | touch. |
| WUSB3801 rewrite | 13 | wusb3801_irq_handler, wusb3801_set_mode_locked, wusb3801_quiesce | typec. |
| Charger: psc5415_enable_otg, psc5415_io_read/write, psc5415_operational_init, charging_enable_otg, fgauge_get_profile_id, meter_to_common_battery_id(_volt) | 8 | - | profile-by-battery-id logic. |
| accdet_hrtimer_init, accdet_hrtimer2_init, accdet_timer_func, accdet_timer2_func | 4 | - | headset-detect timers. |
| audio ext_pa_select_state, setLineOutGainZero, audio_info_* | 4 | - | ext_pa_select_state is called from the source's Ext_Speaker_Amp_Set. |
| netfilter xt_HL (hl_tg6, ttl_tg, ...) | 4 | - | stock lacks HL target; irrelevant to IMS. |
| ION compat __ion_is_user_va, compat_*ion_sys_get_phys_param, compat_put_ion_allocation_data | 4 | - | |
| misc: get_rtc_spare_charge_value, hw_bc11_dcd_release, mt_gpio_dump_regs, mt_spi_remove, ramoops_remove, sw_sync_device_remove, wmt_tm_deinit, timerInit, readReg, read_ef/write_ef | | | |

## 4. Specific checks

### 4a. Image sensor drivers (kdSensorList extracted from both binaries: kd_sensorlist.txt)
Stock (10 entries @0xffffffc00112e240): 0x0135 imx135_mipi_raw, 0x0145 imx145_mipi_raw, 0x2508 sp2508_mipi_raw,
0x5670 ov5670_mipi_raw, 0x2355 gc2355_mipi_raw, 0x5026 gc5025main_mipi_raw, 0x5025 gc5025_mipi_raw, 0x0278 imx278_mipi_raw,
0x5e20 s5k5e2ya_mipi_raw, 0x2235 gc2235_mipi_raw.
Source (2 entries): 0x0145 imx145_mipi_raw (IMX145_MIPI_RAW_SensorInit), 0x5025 gc5025_mipi_raw (GC5025_MIPI_RAW_SensorInit).
Stock overlay DTS (stock-overlay.dts:402-403):
- cam0_enable_sensor = "imx145_mipi_raw imx135_mipi_raw gc5025main_mipi_raw imx278_mipi_raw" (rear)
- cam1_enable_sensor = "sp2508_mipi_raw ov5670_mipi_raw gc5025_mipi_raw gc2355_mipi_raw s5k5e2ya_mipi_raw gc2235_mipi_raw" (front)
Rear working under source => fitted rear = IMX145. Front is one of SP2508/OV5670/GC5025(0x5025)/GC2355/S5K5E2YA/GC2235;
source carries only the GC5025 front candidate. Tree: s5k5e2ya_mipi_raw and imx135_mipi_raw dirs exist but are not built;
sp2508, ov5670, gc2355, gc2235, gc5025main, imx278 dirs do not exist. Source kd_camera_hw.c handles only
SENSOR_DRVNAME_GC5025_MIPI_RAW and SENSOR_DRVNAME_IMX145_MIPI_RAW; stock kdCISModulePowerOn (228 vs 215 insns) selects the
sequence by strstr over the sensor-name table. Vendor HAL blobs (libcameracustom.so, libcam.halsensor.so) contain all
10 names. Stock also has SUBAF_i2C_init (sub-camera AF, DTS camera_sub_af@1c); source has none.

### 4b. Accelerometer
Stock: two drivers, both instantiated from the stock overlay DTS on the same bus (stock-overlay.dts:1136-1148):
- gsensor_mir3da@26: compatible "mediatek,gsensor_mir3da", direction=<4>, reg=<0x26>, status okay;
  mir3da_probe immediates: I2C 0x26 (fallback 0x27), WHO_AM_I 0x13, 5 retries.
- gsensor_msa@62: compatible "mediatek,gsensor_msa", direction=<7>, reg=<0x62>, status okay;
  msa_probe immediates: I2C 0x62, WHO_AM_I 0x13, 3 retries (MSA300 driver, path
  .../sensors-1.0/accelerometer/msa300/msa_cust.c; stock defconfig CONFIG_MTK_MSA300=y, no MIR3DA option).
Both share NSA_* calibration (NSA_calibrate, NSA_NTO_auto_calibrate, NSA_NTO_calibrate, NSA_get_reg_data, NSA_interrupt_ops),
*_temp_calibrate, *_direction_remap, /proc/{mir3da,msa300}dir_info.
Source: only k50_mir3da_* (28 fns) at 0x26/0x27, WHO_AM_I 0x13, direction 4 (k50_mir3da.h); no MSA300 path, no NSA_* or
temp calibration. If the fitted part is MSA300@0x62 (direction 7) the source never talks to it. Generic acc_* framework
62/63 fns, identical.

### 4c. Thermal zones / coolers
Identical name sets. mtkts* zones: cpu, battery, battery2, pa, pmic, wmt, AP, abb, btsmdpa, buck, pcb1, pcb2, skin, tdpa,
xtal, bts (ts1..ts4). mtk-cl-* coolers (15 each): adp-fps, backlight, bcct/bcct00-02, cam, cam-urgent, fps, kshutdown,
mdoff, mutt, noIMS, shutdown, vrt. cpu_adaptive_ 4/4, clatm 2/2, tzcpu 6/6. Symbols: tscpu_* 85/86, mtk_cooler* 16/28
(extra = .exit), _cl_* 22/22, mtk_thermal* 30/31. Code: 321/323 identical; differing: mtktsbattery_get_temp (stock
read_tbat_value()*1000, source *100 - consistent with the source battery meter reporting 0.1 C units) and
mtk_thermal_get_gpu_info (constant/relocation only). BTS/PA/PMIC NTC tables byte-identical (ntc_tables.txt). Battery-meter
NTC: stock one 17-point table (-20..60 C, 71180..3000, 10000@25 C); source a 96-point 0.1 C-step table (-4.0..91.0 C).

### 4d. cpufreq OPP tables and segment selection
Both contain the identical 8x8 {khz,volt,volt_org} block (stock @0xffffffc001108b50, source @0xffffffc001061a98), byte-identical:
- L: {2145000,1911000,1664000,1196000,1027000,871000,663000,286000}, {1950000,1755000,1573000,...}, {1807000,1651000,1495000,...},
  {1508000,1430000,1352000,1196000,1027000,871000,663000,286000}
- LL: {1248000,1079000,910000,689000,598000,494000,338000,156000}, {1144000,1014000,871000,...}, {1001000,910000,819000,689000,598000,494000,338000,156000} x2
- volts (all): 115000,111250,107500,100000,96875,93750,90000,80000.
_mt_cpufreq_get_cpu_level, get_devinfo_with_index, _mt_cpufreq_set, all 30 mt_cpufreq fns, hps_* (90), ppm_* (235), idle (67),
eem_*/PTP (65), dcm_* (40), clk_* (158), devinfo/efuse (107), sched/HMP (108) instruction-identical.
pmic_throttling_dlpt_init differs in one constant (100 -> 92).
=> No kernel-code basis for a cpufreq/hotplug/thermal regression; look at DTS, userspace thermal/perf config, FIH additions.

### 4e. SPM / suspend
Present in both (1/1): spm_go_to_sleep, spm_go_to_sleep_dpidle, spm_go_to_sodi, spm_go_to_sodi3, spm_go_to_dpidle, spm_mcdi_init,
spm_module_init, spm_sodi_init, spm_set_sleep_wakesrc, spm_output_sleep_option, slp_suspend_ops_enter/prepare/valid,
slp_module_init, mt_idle_init, mt_cpu_dormant, cpu_suspend, __cpu_suspend_enter. (spm_suspend, spm_suspend_init, spm_sleep_init,
spm_dpidle_init, spm_vcorefs_init, mt_cpuidle_init exist in neither.) spm_*/__spm_*/slp_*: 168/169 symbols, 218/219 identical;
only slp_suspend_ops_enter differs (+10 insns: FIH mt_gpio_dump_regs hook, CONFIG_FIH_DUMP_GPIO2FILE=y); pm_suspend gains two
FIH_gpio_dump_regs2file calls.

### 4f. ccci / ccmni
Same architecture: ECCCI with ccci_fsm_* , ccci_aed_v1/v2, ccci,modem_info_v1/v2 DT parsing, "CCCI Image header version ... RMPU
Only support after v4", MTK_ECCCI_C2K, ccci_get_platform_version, masp_ccci_version_info. Counts stock/source: ccci_* 153/153,
port_* 74/74, md_* 160/163 (extra = RAID md_setup_*), cldma 48/54 (exit fns), c2k 9/9, ccmni* 19/19. Ports in both: ccci_ims,
ccci_imsa, ccci_imsdc, ccci_imsem, ccci_ipc*, ccci_aud, ccci_lb_it, ccci_md_log, ccci_ioctl. Config identical: MD1_SUPPORT=10,
MD3_SUPPORT=0, ECCCI_C2K=y, INET_ESP/INET6_ESP/XFRM_USER=y. Code: 391/393 ccci identical; differing port_rpc_recv_match (source
adds RPC op 0x400f handling gated on md state 1/2/6) and ccci_ft_inf_show. ccmni: 6/19 differ - ccmni_rx_callback (stock 171
insns incl. stack canary vs 102), ccmni_md_state_callback (stock napi_gro_flush under spin_lock_bh; source mod_timer +
__pm_wakeup_event), ccmni_init, ccmni_open, ccmni_start_xmit (log line numbers), ccmni_napi_poll. xfrm (381) and netfilter (348)
all identical; nothing xfrm/netfilter is stock-only. get_md_adc_val (modem RPC ADC read) differs: source special-cases channel 13.

### 4g. Release identification
No ALPS.*, MOLY.*, LR* or MT6755_* release string in either binary. Only identifiers: stock build path
/ssd/gl/mtk6750_Q/kernel-3.18/ (stock dated Thu Dec 25 16:31:40 CST 2025), CONFIG_MTK_PLATFORM="mt6755",
CONFIG_ARCH_MTK_PROJECT="k50sv1_64_bsp". With 44,570/45,109 shared functions instruction-identical (every MTK platform
subsystem), stock and the Nokia-derived tree are the same MTK release generation; differences are confined to board/vendor drivers.

## 5. Notable semantic diffs in shared functions (fndiff_*.txt)
- Ext_Speaker_Amp_Set (92 -> 124 insns): source inserts ext_pa_select_state(...) + printk on enable and a second pinctrl state on
  disable; Ext_Speaker_Amp_Change, Ext_Speaker_Amp_Switch, AudDrv_GPIO_EXTAMP_Select (pinctrl extamp-pullhigh/pulllow with
  __const_udelay pulse loop) and the other speaker fns are identical. Stock has no AW87318 code/strings (CONFIG_AUDIO_AW87318 does
  not exist in stock config; source Kconfig has it =n). Stock DTS audgpio pinctrl names: extamp-pullhigh/pulllow,
  extamp2-pullhigh/pulllow, rcvspk-pullhigh/pulllow.
- accdet: 9 fns differ - accdet_work_callback (552 -> 506 insns), accdet_eint_work_callback (303 -> 335), accdet_get_dts_data,
  accdet_eint_func, accdet_mod_init, mt_accdet_probe/remove/unlocked_ioctl, mt_accdet_pm_restore_noirq.
- upmu_is_chr_det: source calls fih_is_otg_en (inverted test) instead of mt_usb_is_device.
- pmic_throttling_dlpt_init: 100 -> 92. tsbat_sysrst_set_cur_state: 30 -> 300.
- charger/battery: 77 fns differ; psc5415_set_* are 36-byte wrappers in stock vs 324-byte inline I2C in source; BattVoltToTemp
  183 -> 68 insns, BattThermistorConverTemp, force_get_tbat, BAT_thread, mt_battery_GetBatteryData, bmr_* differ.
- camera hw: Get_Cam_Regulator (222 -> 123), mtkcam_gpio_set (329 -> 249), kdCISModulePowerOn, mtkcam_gpio_init, hwpoweron.
- lens: AF_Ioctl 2844 -> 816 bytes, AF_i2c_probe 1836 -> 500 (one VCM instead of 20).
- get_hall_status reimplemented with a mutex; musb_gadget_enable, mt_get_md_gpio trivial; suspend_enter only printk line numbers.

## 6. Ranking against the reported regressions
1. Front camera - stock 10 sensor drivers (6 front candidates); source one (GC5025 0x5025), 2-sensor kd_camera_hw.c, no SUBAF.
2. Accelerometer - stock probes MIR3DA@0x26 (dir 4) and MSA300@0x62 (dir 7) with NSA_* calibration; source only MIR3DA@0x26.
3. Speaker - no missing code; only Ext_Speaker_Amp_Set modified (+ext_pa_select_state), plus accdet diffs and DTS pinctrl.
4. Performance/heat - cpufreq/OPP, hps, ppm, thermal, idle, sched, EEM, DCM byte/instruction identical; only mtktsbattery_get_temp
   scaling, battery NTC table/units, pmic_throttling_dlpt_init constant and FIH gpio-dump suspend hooks differ.
5. VoLTE/VoWiFi - ccci ports, xfrm/ESP, netfilter identical; only ccmni NAPI/timer handling and RPC op 0x400f differ.
6. Keypad - kpd_* identical; stock-only gpiokey_* driver (7 fns, DT gpiokey_eint) has no source counterpart.

## Files (this directory)
only_stock.txt (1,089), only_source.txt (2,742 raw), only_source_filtered.txt (593), only_source_exitfuncs.txt (382),
common.txt (45,109), common_identical.txt (44,570), common_differing.txt (539), size_delta_common.txt,
stock_text_norm.txt, source_text_norm.txt, stock_text_raw.txt, source_text_raw.txt, stock_nm_all.txt, stock_base80000_nm_all.txt,
stock_strings.txt, source_strings.txt, prefix_table.txt, codecmp_summary.txt, size_summary.txt, opp_tables.txt, ntc_tables.txt,
kd_sensorlist.txt, fndiff_audio_thermal_spm.txt, fndiff_spm_ccmni.txt, fndiff_cam_pmic_usb.txt,
scripts: mkdiff.py prefix_table.py sizecmp.py codecmp.py opp.py ntc.py sensorlist2.py fndiff.py fndiff2.py dis.py
