# k50sv1_64_bsp (MT6755, Linux 3.18.119, alps-mp-q0.mp1-V9.122.1) — public source research

Date: 2026-09-01. Scope: find public source that makes the LineageOS 17.1 source kernel functionally equal to the
stock kernel. Nothing under `/home/desmond/Downloads/k50sv1_64_bsp` was modified; the pristine Nokia clone there
(`lineage-17.1/kernel/xsh/mt6755`, branch `k50sv1-3.18.119`, 8 modified files) was only *read* for diffing.

Working material (all under this directory):
* `repos/mtk-watch_kernel-3.18_q0/` — shallow clone of `mtk-watch/android_kernel-3.18` @ `t-alps-q0.mp1-V9.122.1` (HEAD `9581a836f6fb5e7b62290ea5ff0f9a5350c83c1b`, "Add MediaTek changes", 2020-07-28)
* `repos/vgdn_k55v1_64_3.18.119/` — shallow clone of `Vgdn1942/android_kernel_mt6755_3.18.119` (ODM tree, Blackview BV6000-class, k55v1_64_bsp)
* `q0_k50sv1_64_bsp_reference.config` — `make ARCH=arm64 k50sv1_64_bsp_defconfig` output of the q0 tree
* `nokia_vs_q0_files.txt` — exact per-file diff list Nokia-vs-q0 (core subsystems)
* `dts_q0/` — q0 `k50sv1_64_bsp.dts`, `k50sv1_64_bsp_defconfig`, `kd_sensorlist.c`
* `q0_k50sv1_ProjectConfig.mk` — reference project config from `mtk-watch/android_device_mediateksample`
* `gh_code_search*.log`, `repo_meta*.log`, `repo_search.log`, `odm_repo_search.log`, `grep_fitted_drivers.log`, `page_*.html`

---------------------------------------------------------------------------------------------------------------

## 0. Executive summary (ranked)

1. **The exact stock release line is on GitHub.** `ro.vendor.mediatek.version.release=alps-mp-q0.mp1-V9.122.1` is
   mirrored verbatim as the `mtk-watch` organisation (manifest default revision `refs/heads/t-alps-q0.mp1-V9.122.1`,
   AOSP base `android-10.0.0_r2`):
   * https://github.com/mtk-watch/manifest (default.xml)
   * https://github.com/mtk-watch/android_kernel-3.18 — 3.18.119, platforms mt6735/mt6735m/mt6755/mt6757,
     `arch/arm64/configs/{k37mv1_64_bsp,k37tv1_64_bsp,k50sv1_64_bsp,k50v1_64_bsp}[_debug]_defconfig`,
     `arch/arm64/boot/dts/k50sv1_64_bsp.dts`, `drivers/misc/mediatek/dws/mt6755/k50sv1_64_bsp.dws`, `tools/dct/DrvGen.py`
   * https://github.com/mtk-watch/android_device_mediatek — `mt6755/` (init.mt6755.rc, init.sensor_1_0.rc, thermal.*.conf, throttle.sh, sepolicy, kernel-headers, ueventd)
   * https://github.com/mtk-watch/android_device_mediateksample — `k50sv1_64_bsp/` (ProjectConfig.mk, BoardConfig.mk, mtk-kpd.kl, thermal confs, audio_param, recovery.fstab)
   * `mtk-watch/android_vendor_mediatek` is **empty**, and `OpenWatchProject/android_vendor_mediatek` is **DMCA-blocked** (https://github.com/github/dmca/blob/master/2022/11/2022-11-10-mediatek.md) — no proprietary vendor tree exists publicly.
   Byte-identical kernel mirrors (git tree SHAs equal for every subsystem checked): `OpenWatchProject/android_kernel-3.18` (branch `android-10`), `memediatek/kernel-3.18` (branch `q`); `488315-archive/android_kernel_mediatek_3.18` (branch `mp1-v9.2`, Jan 2020) differs only in `drivers/misc/mediatek/video`.
2. **Correction on the Nokia base:** Nokia 3.1 V4.200 is *not* an Android-O tree. Its vendor build.prop reads
   `ro.vendor.mediatek.version.release=alps-mp-q0.mp1-V9.2_foxconn.fih.ec2.q0mp1.k61v1.64.bsp_P44`, `branch=alps-mp-q0.mp1`
   (https://github.com/xdaGari/tadiphone-buildprop-archive/blob/main/nokia/es2/Essential2_00WW-user-10-QP1A.190711.020-00WW_4_200-release-keys/vendor.build.prop);
   V3.25B (Android 9) was `alps-mp-p0.mp1-V5.20`. A full `diff -rq` of the local pristine Nokia clone against the q0 V9.122.1
   tree confirms it: `base/power/mt6755` 0 files differ, `ccci_util` 0, `power/mt6755` 0, `usb_c` 0, `keyboard/mediatek` 0,
   `eccci` 1 (port_rpc.c, 28 lines), `ccmni` 1 (ccmni.h, 2 lines), `base/power` 4 (spm_v2 only), `thermal` 3, `pmic` 4,
   `sensors-1.0` 20 (+7 HMD-only dirs: bmc156_acc, bmi160_acc, bmg160, bmi160_gyro, bmc156_mag, ltr559_mtk, stk3x1x-new),
   `imgsensor` 2, `drivers/power/mediatek` 7, `sound/soc/mediatek` 3, `video` 15, `accdet` 3 — see `nokia_vs_q0_files.txt`.
   `sensors-1.0/accelerometer/accel.c` and `drivers/input/keyboard/mediatek/kpd.c` are identical.
   => Switching to `mtk-watch/android_kernel-3.18` (or overlaying the ~100 listed files) removes only HMD deltas; the
   framework code the coordinator asked about (sensors-1.0, ccci/ccmni, base/power, imgsensor core) is already q0-class.
3. **Stock-vs-reference config delta** (stock IKCFG vs `make k50sv1_64_bsp_defconfig` of q0): stock adds
   `CONFIG_MTK_PSC5415_SUPPORT`, `CONFIG_USB_CC_WUSB3801X`, `CONFIG_MTK_GPIO_HALL`, `CONFIG_MTK_MSA300`, `CONFIG_MTK_STK3X3X`,
   `CONFIG_OS_SYSCUST`, `CONFIG_SILEAD_FP`, `CONFIG_TOUCHSCREEN_MTK_GSLX680`, `CONFIG_TOUCHSCREEN_HIMAX_*`/`IC_HX83102E`,
   `CONFIG_ACCDET_EINT` (ref: `ACCDET_EINT_IRQ`), `MTK_MD1_SUPPORT=10`/`MD3_SUPPORT=0`/`C2K_LTE_MODE=0` (ref 12/2/2),
   `CUSTOM_KERNEL_IMGSENSOR="imx145_mipi_raw sp2508_mipi_raw ov5670_mipi_raw imx135_mipi_raw gc2355_mipi_raw gc5025main_mipi_raw gc5025_mipi_raw imx278_mipi_raw s5k5e2ya_mipi_raw gc2235_mipi_raw"`,
   `CUSTOM_KERNEL_LCM="ft8057s_inx_hdplus1560 ilip6h87_dsi_vdo_hdplus1560 ft8057s_ivo_hdplus1560"`, `LCM 720x1560`, `FRAME_WARN=1600`;
   stock drops gyroscope/magnetometer/AKM8963/BMP280/BQ25896/CM36558/MPU6515/GT1151/GTP_*. None of the ODM-only symbols
   (`OS_SYSCUST`, `MTK_PSC5415_SUPPORT`, `gc5025main_mipi_raw`, `ilip6h87`, `ft8057s_inx_hdplus1560`) has a single hit in
   GitHub code search — **the ODM's own tree is not public**; the fitted-part drivers must come from donors (section 4).
4. Best donors per fitted part are listed in section 4; the strongest are: `dhirajms/kernel-mediatek` (3.18.79, sensors-1.0 `mir3da`
   with the exact 0x26->0x27 address fallback), `HMD-OSS-Archive/android_kernel_nokia_c100` (`drivers/misc/mediatek/typec/wusb3801x/`
   with the exact `USB_CC_WUSB3801X` Kconfig symbol), `Vgdn1942/android_kernel_mt6755_3.18.119` (mt6755 `gc5025_mipi_raw`, `ov5670_mipi_raw`+OTP),
   the q0 tree itself for ov5670/gc2355/imx278/s5k5e2ya/imx135 and for a BQ24158/FAN5405-class 3.18 charger driver (PSC5415 register-compatible),
   `LineageOS/android_kernel_xiaomi_earth` (`touchscreen/mediatek/ft8057`, `FTS_CHIP_TYPE _FT8057 = 0x80570828`).

---------------------------------------------------------------------------------------------------------------

## 1. Complete MT6755/MT6750/MT6737-class 3.18.x kernel trees (verified)

Tree-SHA matrix (`gh api repos/<r>/contents/<parent>` sha, first 8 hex) — identical SHA = byte-identical subtree:

| subtree | mtk-watch q0 V9.122.1 | OpenWatch android-10 | memediatek q | 488315 mp1-v9.2 | rokib/nyancrimew q0 (Dec-2019) | MediaTek-Pie p0-V5.237 | nokia-mt6750 lineage-17.1 | Vgdn1942 |
|---|---|---|---|---|---|---|---|---|
| drivers/misc/mediatek/sensors-1.0 | a7abe742 | = | = | = | = | = | 99ba445a | aed1fd56 |
| drivers/misc/mediatek/base | 338ea5ba | = | = | = | 96fd0910 | f61b2e1c | 4b46398b | 8f264f9e |
| drivers/misc/mediatek/eccci | 303567d6 | = | = | = | = | 469ac1a7 | e7c39bf1 | 469ac1a7 |
| drivers/misc/mediatek/ccmni | 693c9c02 | = | = | = | = | = | eb4894c7 | 27120717 |
| drivers/misc/mediatek/ccci_util | 012af100 | = | = | = | = | 05b44a9e | = | aa01504b |
| drivers/misc/mediatek/imgsensor | 5ffda40d | = | = | = | c0e69998 | 2b84b850 | f90e30c9 | f6a42786 |
| drivers/misc/mediatek/thermal | e1c3eded | = | = | = | = | fe9b58cc | 6360d8c9 | e87145ca |
| drivers/misc/mediatek/power | a45c0f82 | = | = | = | = | e5e5cf66 | = | 2379ebe9 |
| drivers/misc/mediatek/usb_c | f120652d | = | = | = | = | = | = | 070f33d0 |
| drivers/misc/mediatek/video | a0f34e8c | = | = | 3ec6e712 | 3ec6e712 | 70ed25b5 | 7f1b7d2b | 1e1fc7a8 |
| sound/soc/mediatek | caa4dd2a | = | = | = | ec42eb56 | 73eeac85 | 550eef2f | 73eeac85 |
| drivers/input/keyboard/mediatek | 76360a57 | = | = | = | = | 027b0315 | = | 016c107a |
| arch/arm64/boot/dts | 3a712a09 | = | = | = | e128c99c | c6be7b18 | 8129a8fe | 93ffb558 |

Candidate list with evidence:

| repo | branch / release | kernel | platforms & projects | fitted drivers present | verdict |
|---|---|---|---|---|---|
| https://github.com/mtk-watch/android_kernel-3.18 | `t-alps-q0.mp1-V9.122.1` (commit 9581a836, 2020-07-28) | 3.18.119 | mt6735/mt6735m/mt6755/mt6757; k37mv1_64_bsp, k37tv1_64_bsp, k50sv1_64_bsp, k50v1_64_bsp (defconfig+dts+dws) | s5k5e2ya (mt6755), imx135 (mt6755), ov5670 (mt6735m), gc2355 (mt6735/mt6735m), imx278 (mt6735), extamp (sound/soc/mediatek/mt6755/AudDrv_Gpio.c), mtk-kpd, constant_flashlight, mt6605 nfc, focaltech ft6336s + unified_driver_4/FT8707; **no** mir3da/gc5025/sp2508/imx145/dw9761/ft8057/psc5415/wusb3801/aw87318/hall/stk3x3x/msa300 | **primary base** (exact stock release) |
| https://github.com/OpenWatchProject/android_kernel-3.18 | `android-10` (same commit content) | 3.18.119 | same | same | identical mirror (org readme: BLOCKS OpenWatch, MTK watches) |
| https://github.com/memediatek/kernel-3.18 | `q` ("BSP Changes" 2021-04-15) | 3.18.119 | same | same | identical mirror |
| https://github.com/488315-archive/android_kernel_mediatek_3.18 | `mp1-v9.2` (2020-01-27) | 3.18.119 | same | same | q0.mp1-V9.2 (video older) |
| https://github.com/rokibhasansagar/t-alps-release-q0-kernel-3.18 , https://github.com/nyancrimew/mtk-t-alps-release-q0-kernel-3.18 | master (2019-12-19), also `mp1-v9.2` | 3.18.119 | same | same | early q0 drop (base/imgsensor/video/sound/dts older) |
| https://github.com/iscle/android_kernel_autochips_ac8227l | `ac8227l` (q0 "Add MediaTek changes" + mt8127 mix) | 3.18.119 | same + mt8127 | | q0 derivative, not needed |
| https://github.com/MediaTek-Pie/kernel-3.18 | "Import from t-alps-p0-mp1-V5.237" (2021-07-21) | 3.18.119 | mt6755 only; k50sv1_64_bsp, k50v1_64_bsp | as q0 minus mt6735 dirs | P release; sensors-1.0/lens/lcm/usb_c/ccmni identical to q0, rest older |
| https://github.com/nokia-mt6750/android_kernel_nokia_mt6755 | `lineage-17.1`, `lineage-18.1` (commit 07a1047c "Import Nokia V4.200 kernel source" 2021-12-01) | 3.18.119 | + CO2 (Nokia 5.1), ES2 in yesimxev fork; k50sv1_64_bsp cfg/dts present | + focaltech_touch_ft8613/ft8719, hx83103, nt36672, bmc156/bmi160, rt5081a | q0.mp1-V9.2 + HMD deltas (see section 2) |
| https://github.com/yesimxev/android_kernel_nokia_es2 (V3.180/V3.25B/V4.200), https://github.com/bigrammy/android_kernel_nokia_3.1 , https://github.com/mikoxyz/android_kernel_nokia_essential2 , https://github.com/0xthe13/android_kernel_nokia_es2 , https://github.com/bigrammy/android_kernel_nokia_5.1 | HMD drops | 3.18.119 | k50sv1_64_bsp present in all | | official HMD drops (https://www.hmd.com/en_int/opensource lists Nokia3.1_V3.25B.tar.bz2) |
| https://github.com/Vgdn1942/android_kernel_mt6755_3.18.119 (+ https://github.com/Vgdn1942/android_device_mediatek_k55v1_64_bsp ProjectConfig.mk: alps-mp-p0.mp1) | master (2019-05-21) | 3.18.119 | mt6755; k55v1_64_bsp, `bv6000.dts` (Blackview BV6000), "agold" ODM files | **gc5025_mipi_raw**, **ov5670_mipi_raw + ov5670_otp.c**, s5k5e2ya, imx135, hi553, s5k3l8, ov13850…; `drivers/misc/mediatek/hall/hall.c`; silead gsl6163 FP; lens dw9763af/dw9800af; FT5406_MT, GT1X | P-era ODM tree, camera donor |
| https://github.com/techyminati/alps-3.18 | `t-alps-o1-mp1` (with per-ALPS-ticket commits to 2020-09) | 3.18.x | mt6735/6735m/6753/6755/6757; k37*/k53v1_64_bsp | | O release, older |
| https://github.com/mohancm/mediatek-oreo-kernel , https://github.com/dhirajms/kernel-mediatek (mtk-3.18.79, "alps-8.1"), https://github.com/iykex/mtk_android_kernel-3.18 | O | 3.18.79 | mt6735…mt6757, k53v1_64_bsp | dhirajms: sensors-1.0 **mir3da**, imgsensor mt6735m gc5025 | O reference; mir3da donor |
| https://github.com/cvolo4yzhka/ZTE_Blade_A476_p0_kernel_3.18.119 | p0 (upstream to V3.193) | 3.18.119 | mt6735p | | P reference for mt6735 |
| Sony Xperia XA/XA Ultra: https://github.com/JonnyVR1/android_kernel_sony_tuba , https://github.com/linzhangru/Sony-xa-kernel-tuba , https://github.com/Swapnil133609/mediatek_kernel_sony_tubads , https://github.com/mohancm/android_kernel_sony_ukulele-N | M/N | 3.18.x | mt6755 tuba/ukulele | | older generation, skip |
| Meizu M3 Note: https://github.com/meizuosc/m681 , https://github.com/meizuosc/m681-intl , https://github.com/99degree/android_kernel_m3note | M/N | 3.18.x | mt6755 | m681-intl: legacy `accelerometer/da213/mir3da_*` | older; legacy hwmsen mir3da only |
| Elephone P9000: https://github.com/elephone-dev/P9000-Kernel , https://github.com/Ruben7173/android_kernel_elephone_p9000-1 | M | 3.18 | mt6755 even6755_65u_m | | older, skip |
| Oppo A37m/A59m: https://github.com/affggh/android_kernel_oppo_mt6755 (branch `v3.10.108`), https://github.com/isuck-at-programming-badly/oppo-f1s-kernel-build (2026, DrvGen python replacement) | L | 3.10 | mt6750/mt6755 | | too old |
| Oukitel/Doogee/Umidigi/Vernee/Ulefone (repo search): https://github.com/MediatekAndroidDevelopers/android_kernel_oukitel_k6000_plus (3.18.80, mt6755 **gc5025_mipi_raw**), https://github.com/MediatekAndroidDevelopers/android_kernel_oukitel_u13 (3.18.105 mt6753; **imx145** mt6753/mt6735m), https://github.com/SnowCat6/DOOGEE-kernel-3.18 (3.18.35; **sp2508** mt6735m/mt6580, **gc5025** mt6755), https://github.com/zac6ix/android_kernel_p383 (UMIDIGI C Note 2, 3.18.35), https://github.com/MediatekAndroidDevelopers/android_kernel_vernee_thor_k506 (dw9761af), https://github.com/vlad-ivanov-name/android_kernel_vernee_mars , https://github.com/ulefoneofficial/ulefone-Metal (3.18) | N/O | 3.18.x | mt6753/mt6755/mt6737 | individual drivers only | donors |
| Later ALPS kernels of the same q0 line (4.x, drivers/misc/mediatek shared): https://github.com/HelloVolla/android_kernel_volla_mt6763 (4.4.146, q0/halium; `sensors-1.0/accelerometer/da226` mir3da, `alsps/stk3x3x`, `lcm/*hdplus1560*`, `touchscreen/mediatek/focaltech_touch{,_V3}`, gslX680), https://github.com/nasreirma/android_kernel_common_MT6763 (4.4.95; `sensors-1.0/accelerometer/mir3da` with Kconfig/Makefile, `charger/bq24158.c`), https://github.com/bv9100/android_kernel_blackview_mt6765 (4.9.118; **psc5415a.c/.h + psc5415a.dtsi**, `lens/main/common/dw9761af`, stk3x3x, focaltech_touch_ft8719), https://github.com/deadman96385/android_kernel_alcatel_mt6739 (4.4.95; `drivers/misc/mediatek/aw87318/`, `charger/psc5415a.c`, `bq24157.c`), https://github.com/HMD-OSS-Archive/android_kernel_nokia_c100 (4.19.191; `typec/wusb3801x/`, `psc5415e.c`), https://github.com/LineageOS/android_kernel_xiaomi_earth (4.19.325; `touchscreen/mediatek/ft8057/`) | P/Q/R | 4.4-4.19 | mt6739/6763/6765/6768 | see section 4 | driver donors (API shims needed) |
| Not applicable: https://github.com/MotorolaMobilityLLC/kernel-mtk (branches android-9/10/11… = MT6739/6762/6765 4.4/4.9/4.14, no 3.18); UMIDIGI GitHub org returns 404 (their F2 sources were DMCA'd); https://github.com/Power535/android_kernel_common_MT6763 (Android 10, 4.x) | | | | | |

LK / preloader for the same project (if the bootloader ever needs rebuilding):
* https://github.com/svoboda18/lk — `project/k50sv1_64_bsp.mk` (Android 10/11 legacy LK), `lib/libshowlogo/cust_display.h` has `hdplus1560` entries
* https://github.com/svoboda18/preloader — `custom/k50sv1_64_bsp/`
* https://github.com/TheGammaSqueeze/lk-mt6785 — also carries `project/k50sv1_64_bsp.mk`

4PDA index (https://4pda.to/forum/index.php?showtopic=583114): the "mt6755" spoiler lists only
`ALPS-FPB-M0.MP7-MT6750-OF.P11.PRE_K50V1_64_OM_C2K_P_KERNEL` (post p=47699292, dated 06.03.2016 = Marshmallow-era MT6750
pre-release kernel, hidden attachment) and Elephone P9000; plus "Oreo 8.1 для mt6735/6737/6753/6755/6757 на ядре 3.18" and
`ALPS-MP-N1.MP7-V1_WT6750_66M5_N1` (mt6750 N). All older than q0 — no need to chase them.

## 2. Nokia (current base) vs q0.mp1-V9.122.1 — what exactly differs

Local pristine Nokia clone: `/home/desmond/Downloads/k50sv1_64_bsp/lineage-17.1/kernel/xsh/mt6755` (remote
`nokia-mt6750/android_kernel_nokia_mt6755`, HEAD 416df670 "lineageify", which only touched Documentation). Full list in
`nokia_vs_q0_files.txt`; highlights (line counts = `diff | grep -c '^[<>]'`):

* sensors-1.0: `accelerometer/{Kconfig,Makefile}` (+2, HMD adds bmc156_acc/bmi160_acc), `alsps/alsps.c` (22), `alsps_factory.c` (37),
  `alsps/ltr559/*` (HMD replaced with `ltr559_mtk`), `alsps/stk3x1x/stk3x1x.c` (7), `gyroscope/*` (HMD bmg160/bmi160_gyro),
  `hwmon/include/sensors_io.h` (372), `magnetometer/{mag.c,mag_factory.c,maghub.c,Kconfig,Makefile}` (HMD bmc156_mag). `accel.c` identical.
* base/power: only `spm_v2/{Makefile,mt_sleep.c}` (22) and `include/spm_v2/mt_spm_misc.h`; `base/power/mt6755` (49 files) identical.
* eccci: `port_rpc.c` (28). ccmni: `ccmni.h` (2). ccci_util identical.
* imgsensor: `inc/kd_imgsensor.h` (35), `src/mt6755/kd_sensorlist.h` (24), HMD-only `src/mt6755/camera_project/`.
* charging: `drivers/power/mediatek/battery_common_fg_20.c` (565), `battery_meter_fg_20.c` (103), `switch_charging.c` (48),
  `pmic/mt6353/pmic_chr_type_det.c` (67), `pmic/rt5081a/rt5081a_pmu_charger_gm20.c` (124), `include/mt-plat/mt6755/include/mach/mt_battery_meter_table_multi_profile.h` (5049, HMD battery tables + `_co2.h/_es2.h`), `mt_charging.h` (41).
* audio: `sound/soc/mediatek/{Kconfig,Makefile}`, `mt6750/mt_soc_codec_6353.c` (127); accdet `mt6755/accdet.c` (146).
* display: 15 files under `video/mt6755` (`primary_display.c` 139, `layering_rule.c` 43, `disp_recovery.c` 16 …).
* dts: `mt6755.dts` (89), `rt5081a.dtsi` (28), HMD-only `CO2*.dts`, `hx83103-touch.dtsi`, `nt36672touch.dtsi`.
* kernel core: `printk/printk.c` (84), `auditfilter.c` (74), `power/suspend.c` (20), `trace/trace.c` (17).

Recommendation: either rebase the port onto `mtk-watch/android_kernel-3.18` (exact stock line) and re-apply the
previous session's ODM commits (mir3da, gc5025/imx145, ft8057, psc5415, wusb3801x, dw9761af, hall-switch, extamp), or keep
the Nokia base and copy the q0 versions of the files above (especially the charging/pmic/sensors-1.0/video/accdet
groups, which carry HMD device tuning that does not belong to k50sv1_64_bsp).

## 3. Reference project data for k50sv1_64_bsp (q0)

* `arch/arm64/boot/dts/k50sv1_64_bsp.dts` (891 lines): `&audgpio` with pinctrl `extamp-pullhigh/extamp-pulllow/extamp2-pullhigh/extamp2-pulllow`
  (`aud_pins_extamp_high/low`, `aud_pins_extamp2_high/low`), `&i2c1 { gsensor@68 …; msensor@0f; gyro@69; alsps@51 }`, `&touch` (GT1151 5 points),
  `#include <k50sv1_64_bsp/cust.dtsi>` — `cust.dtsi` is generated by `tools/dct/DrvGen.py` from `drivers/misc/mediatek/dws/mt6755/k50sv1_64_bsp.dws`.
  Diff this against the stock `factory_image_unpacked/dtb/boot_dtb.dts` to isolate every ODM DT change.
* `k50sv1_64_bsp_defconfig` reference: `CONFIG_MTK_PLATFORM="mt6755"`, `MTK_PMIC_CHIP_MT6353`, `CUSTOM_KERNEL_IMGSENSOR="s5k2p8_mipi_raw ov8858_mipi_raw"`,
  `CUSTOM_KERNEL_CAM_CAL_DRV="s5k2p8_eeprom ov8858_eeprom"` (stock kept this string verbatim), `CUSTOM_KERNEL_FLASHLIGHT="constant_flashlight"`,
  `MTK_LENS_{AD5820AF,BU6424AF,BU6429AF,DW9714AF,LC898212AF,LC898214AF}`, `MTK_SENSORS_1_0`, `MTK_COMBO_CHIP_CONSYS_6755`, `MTK_FM_CHIP="MT6625_FM"`,
  `MTK_ECCCI_DRIVER` + `MTK_ECCCI_C2K`, `TOUCHSCREEN_MTK_GT1151`, `MTK_BTCVSD_ALSA`.
* `ProjectConfig.mk` (mediateksample): `CUSTOM_KERNEL_SOUND = amp_6323pmic_spk`, `MTK_AUDIO_SPEAKER_PATH = int_spk_amp`, `CUSTOM_KERNEL_TOUCHPANEL = GT1XX`,
  `CUSTOM_KERNEL_ACCELEROMETER/ALSPS/GYROSCOPE/MAGNETOMETER = yes`, `LINUX_KERNEL_VERSION = kernel-3.18`.
* `device/mediatek/mt6755/init.sensor_1_0.rc`: chmod/chown of `/dev/hwmsensor`, `/dev/msensor`, `/dev/gsensor`, `/dev/m_acc_misc`,
  `/sys/class/sensor/m_acc_misc/{accenablenodata,accactive,accdelay,accbatch,accflush,acccali}` (+ `m_mag_misc/…`).
* `device/mediatek/mt6755/init.mt6755.rc`: `/proc/ppm/policy/userlimit_min_cpu_freq "1 1508000"`, `/proc/ppm/mode`, `/proc/hps/{num_base_perf_serv,num_limit_power_serv,num_limit_ultra_power_saving,down_threshold,up_threshold}`,
  `/sys/devices/system/cpu/cpufreq/hotplug/cpu_num_base`; thermal policies in `thermal.*.6755*.conf`, `throttle.sh`.

## 4. Standalone driver sources for the fitted / stock-compiled parts

| part | best public source(s) | evidence |
|---|---|---|
| MiraMEMS **mir3da** (sensors-1.0, 3.18) | https://github.com/dhirajms/kernel-mediatek/tree/mtk-3.18.79/drivers/misc/mediatek/sensors-1.0/accelerometer/mir3da (Kconfig, Makefile, mir3da_core.c 61 KB, mir3da_core.h, mir3da_cust.c 32 KB, mir3da_cust.h); same layout in https://github.com/iscle/OrangePi_4G-IOT_Android_8.1_BSP/tree/master/kernel-3.18/drivers/misc/mediatek/sensors-1.0/accelerometer/mir3da and https://github.com/flitsmeister/android-os-kernel (4.19) | `mir3da_cust.c`: `MIR3DA_DRV_NAME "mir3da"`, `{.compatible = "mediatek,gsensor"}`, `acc_driver_add(&mir3da_init_info)`, probe forces `client->addr = 0x26` then retries `0x27` (lines 863-915) — exactly the stock DT-0x26/chip-0x27 behaviour; `MODULE_AUTHOR("MiraMEMS <lschen@miramems.com>")` |
| mir3da, other API generations | 4.4 sensors-1.0: https://github.com/nasreirma/android_kernel_common_MT6763 (`sensors-1.0/accelerometer/mir3da`), https://github.com/joe2k01/android_kernel_wiko_p200 , https://github.com/HelloVolla/android_kernel_volla_mt6763 (`da226`), 4.19: https://github.com/Teracube-Inc/kernel_teracube_emernia-4.19 (`da218`); legacy hwmsen (3.18/3.10): https://github.com/meizuosc/m681-intl (`accelerometer/da213`, MT6755), https://github.com/elephone-dev/P8000-Kernel (`da213`), https://github.com/mrmazakblu/Android_Kernel_Blu_Tank_Xtreme_Pro_T0010UU , https://github.com/488315-archive/mt8163-kernel-3.18 , https://github.com/orangepi-xunlong/OrangePi4G-iot_kernel , https://github.com/SoCXin/MT6737 , https://github.com/gentoocat/plane-1538e-kernel-3.18 , https://github.com/parthibx24/ALPS-STUDIO-J8M (`da2xx`) | 108 files matched `mir3da path:drivers/misc/mediatek` |
| MSA300 (stock-compiled, not fitted) | https://github.com/mt8173/kernel-3.18 and https://github.com/Goayandi/android_kernel_mt8176_common — `drivers/misc/mediatek/accelerometer/msa300/` with `CONFIG_MTK_MSA300` (legacy hwmsen, 3.18) | only public hits for the stock symbol |
| STK3X3X ALS/PS (stock-compiled, not fitted) | https://github.com/HelloVolla/android_kernel_volla_mt6763 , https://github.com/bv9100/android_kernel_blackview_mt6765 , https://github.com/flitsmeister/android-os-kernel — `sensors-1.0/alsps/stk3x3x/` (`CONFIG_MTK_STK3X3X`) | |
| GalaxyCore **GC5025** (MTK imgsensor, mt6755, 3.18) | https://github.com/Vgdn1942/android_kernel_mt6755_3.18.119/tree/master/drivers/misc/mediatek/imgsensor/src/mt6755/gc5025_mipi_raw (`gc5025mipi_Sensor.c/.h`, plus `kd_sensorlist.h`/`kd_camera_hw.c` entries), https://github.com/MediatekAndroidDevelopers/android_kernel_oukitel_k6000_plus/tree/o-8.0.0/drivers/misc/mediatek/imgsensor/src/mt6755/gc5025_mipi_raw (3.18.80), https://github.com/SnowCat6/DOOGEE-kernel-3.18 (`src/mt6755/gc5025mipi_raw`) ; mt6735m 3.18 variants: https://github.com/dhirajms/kernel-mediatek , https://github.com/darklord4822/android_kernel_moto_e4 (`camera_project/woods/gc5025_mipi_raw`, official Moto E4), https://github.com/Huawei-mt6737/kernel-source-code-huawei-mt6737 | `filename:gc5025mipi_Sensor.c` = 83 hits; `gc5025main` = 0 hits (stock's `gc5025main_mipi_raw` is an ODM rename with a second SENSOR_ID/DRVNAME — derive from the sub variant) |
| Superpix **SP2508** | 3.18 mt6735m: https://github.com/SnowCat6/DOOGEE-kernel-3.18 (`src/mt6735m/sp2508_mipi_raw`, also mt6580), https://github.com/DoomFlex/Kernel_6737m , https://github.com/TB3-730X/android_kernel_lenovo_mt6735 , https://github.com/samgrande/Reapergodkernel_CP8676_I02 ; 3.10 mt6735/mt6753: https://github.com/PersimmonProject/android_kernel_archos_persimmon_3_10 , https://github.com/satory-ra/Oukitel_K10000_kernel_3.10.65 | `sp2508mipi_Sensor` = 174 hits; q0 tree only has the ID in `imgsensor/inc/kd_imgsensor.h` |
| Sony **IMX145** | https://github.com/MediatekAndroidDevelopers/android_kernel_oukitel_u13 (3.18.105; `src/mt6753/imx145_mipi_raw` and `src/mt6735m/imx145_mipi_raw`), https://github.com/mrmazakblu/Android_Kernel_Blu_Tank_Xtreme_Pro_T0010UU , https://github.com/rezvorck/android_kernel_s450m_4g (3.18.19), https://github.com/darklord4822/android_kernel_smart_surf , https://github.com/MrColdbird/android_kernel_oukitel_k4000pro | `imx145mipi` = 51 hits, none for mt6755 — the local tree's `imx145_mipi_raw` (commit 06f3ec7f) is the only mt6755 port |
| OV5670 / GC2355 / IMX278 / S5K5E2YA / IMX135 / GC2235 | inside the q0 tree: `src/mt6735m/ov5670_mipi_raw`, `src/mt6735{,m}/gc2355_mipi_raw`, `src/mt6735/imx278_mipi_raw`, `src/mt6755/s5k5e2ya_mipi_raw`, `src/mt6755/imx135_mipi_raw` (+`imx135_otp.c`); Vgdn has mt6755 `ov5670_mipi_raw` with `ov5670_otp.c`. GC2235: only the ID exists in `kd_imgsensor.h` (no driver hit in any 3.18 MTK tree searched) | grep log `grep_fitted_drivers.log` |
| DW9761AF VCM | https://github.com/bv9100/android_kernel_blackview_mt6765/tree/kernel-4.9/drivers/misc/mediatek/lens/main/common/dw9761af (same `lens/main/common` layout as q0), https://github.com/CyanogenMod/android_kernel_cyanogen_mt6735 (3.18.19, `lens/common/dw9761af/DW9761AF.c`), https://github.com/MediatekAndroidDevelopers/android_kernel_vernee_thor_k506 , https://github.com/elephone-dev/P8000-Kernel (`lens/mt6735/dw9761af`) | local tree already has `lens/main/common/dw9761af` (commit 45ea141a) |
| FocalTech **FT8057(S)** touch (MTK tpd `focaltech_touch`) | https://github.com/LineageOS/android_kernel_xiaomi_earth/tree/lineage-23.2/drivers/input/touchscreen/mediatek/ft8057 (`focaltech_config.h`: `#define _FT8057 0x80570828`, `FTS_CHIP_TYPE _FT8057`; full V3-style driver incl. `focaltech_flash.c`, `focaltech_test`), https://github.com/neel0210/android_kernel_samsung_a146p (`touchscreen/mediatek/FT8057S/`, also LCM `lcm/n28_ft8057s_dsi_vdo_hdp_dsbj_mantix/` = MTK LCM driver for an FT8057S HD+ video panel), https://github.com/danascape/linux-daria-mt6877 (`focaltech_ft8057s_v4_1`), https://github.com/noshricardo/android_kernel_hmd_sm4450 (`focaltech_ft8057s` + firmware .ini) | no 3.18 tree carries FT8057; the Nokia tree's `focaltech_touch_ft8613/ft8719` (same focaltech V2/V3 core on tpd) is the right 3.18 scaffold (already used locally) |
| Prisemi **PSC5415(A)** charger | MTK charger_class (4.4/4.9): https://github.com/bv9100/android_kernel_blackview_mt6765 (`drivers/power/supply/mediatek/charger/psc5415a.c/.h`, `arch/arm64/boot/dts/mediatek/psc5415a.dtsi`), https://github.com/VenomousSteam81/ZTE_Z3351S_Pie_4.4.146_Kernel (`drivers/power/mediatek/charger/psc5415a.c`, MediaTek-authored, `{.compatible = "mediatek,swithing_charger"}`), https://github.com/deadman96385/android_kernel_alcatel_mt6739 ; 4.19: https://github.com/HMD-OSS-Archive/android_kernel_nokia_c100 (`psc5415e.c`), https://github.com/MicromaxOSS/android_kernel_In_1b . 3.18 `charging_hw_*` framework donors (register-compatible BQ24158/FAN5405 family): q0 tree `drivers/misc/mediatek/power/mt6735/{fan5405.c,fan5405.h,charging_hw_fan5405.c,bq24157.c,charging_hw_bq24157.c}`; https://github.com/Zotio/Alcatel_1T_10 `drivers/misc/mediatek/power/mt6580/charging_hw_fan5405.c` carries `CONFIG_PSC5415A_CHARGER` / `CS_VTH_PSC5415A[]` (PSC5415A driven through the fan5405 driver) | `MTK_PSC5415_SUPPORT` = 0 hits (ODM symbol); stock config `CONFIG_MTK_PSC5415_SUPPORT=y`; local tree already has `power/mt6755/psc5415.c` + `charging_hw_psc5415.c` (commit 2c019483) |
| WillSemi **WUSB3801X** CC controller | https://github.com/HMD-OSS-Archive/android_kernel_nokia_c100/tree/hmd/Nokia_C100/drivers/misc/mediatek/typec/wusb3801x (`wusb3801x.c` "Copyright (c) 2019, WillSemi", `class-dual-role.c`, Kconfig `config USB_CC_WUSB3801X` — the exact symbol in the stock IKCFG), https://github.com/bq/joy-1/tree/master/drivers/usb/wusb3801x (WillSemi 2016 reference, author lei.huang@sh-willsemi.com, same Kconfig symbol), https://github.com/pocketbook/kernel-b288 (`drivers/usb/misc/wusb3801x.c`), MTK tcpc flavour `drivers/misc/mediatek/typec/tcpc/tcpc_wusb3801x.c` (https://github.com/oppo-source/android_kernel_oppo_mt6765 , realme/oneplus trees), mainline `drivers/usb/typec/wusb3801.c` (https://lwn.net/Articles/884759/) | `USB_CC_WUSB3801X` = 14 hits; local tree already has `drivers/misc/mediatek/wusb3801x/` |
| Awinic **AW87318** PA (if the ext amp is one) | https://github.com/deadman96385/android_kernel_alcatel_mt6739/tree/master/drivers/misc/mediatek/aw87318 (`aw87318.c`: `{.compatible = "mediatek,aw87318-pa"}`, `deb-gpios` enable pin), https://github.com/LgPWNd/Alcatel_mt6739_5059R_and_5041C_universal_kernel-4.4.95- , datasheet https://files.pine64.org/doc/datasheet/PineNote/Awinic%20AW87318%20Class-K%20Audio%20Amp%20Datasheet.pdf | stock uses plain `audgpio` extamp GPIO (`AudDrv_GPIO_EXTAMP_Select(true,3)` from `Ext_Speaker_Amp_Change` in `sound/soc/mediatek/mt6755/mt_soc_codec_63xx.c`), so a dedicated AW87318 driver is optional |
| GPIO Hall (`CONFIG_MTK_GPIO_HALL`) | https://github.com/mediatek-dev-playground/android_kernel_teclast_mt6753 and https://github.com/diparthshah/kernel_xolo_mt6753 — `drivers/misc/mediatek/halldet/halldet_drv.c` (the only trees using the stock Kconfig symbol); alternative `drivers/misc/mediatek/hall/hall.c` in Vgdn1942 | local tree has `hall-switch/` + `hallsensor/` (commit 6393dc26) |
| Silead FP / GSLX680 / Himax HX83102E / MT6605 NFC (compiled, not fitted) | Vgdn `drivers/input/fingerprint/gsl6163`; `gslX680` in HelloVolla/nasreirma/LineageOS earth; `hxchipset_hx83102p`/`HX83102_I2C` in flitsmeister/LineageOS earth; `nfc/mt6755/mt6605.c` in q0 | not needed for parity |

## 5. Chinese-language / forum sources

* 4PDA "Сборка ядра Android для процессоров MTK": https://4pda.to/forum/index.php?showtopic=583114 — index summarised in section 1; the K50V1_64 entry is a 2016 Marshmallow pre-release (`ALPS-FPB-M0.MP7-MT6750-OF.P11.PRE_K50V1_64_OM_C2K_P_KERNEL`, post p=47699292, hidden link).
* XDA: "Need SP Flash Tool ROM for MT6750 tablet (board: k50v1_64_bsp)" https://xdaforums.com/t/need-sp-flash-tool-rom-for-mt6750-tablet-board-k50v1_64_bsp.4767874/ — fake "Pad 6s Pro", `Custom build version: alps-mp-q0.mp1-v9`, build C30-v1.1-20250503 (same ODM release line as ours). hovatek "Air Tab U25 PRO MAX" https://www.hovatek.com/forum/thread-49199.html — board **k50sv1_64_bsp**, MT6755V/CM, kernel `3.18.119 #2 SMP PREEMPT Fri Jun 6 20:20:40 CST 2025`, build `M55P30DDR_BYC_U25_PRO_MAX_AIT_TAB_V1.0_20250606`. androidcentral ZAQE M505-Pro https://forums.androidcentral.com/threads/shady-zaqe-mp3-player-runs-android-9.1074694/ — `alps/full_k50v1_64_bsp`, Android 9, build user es01. Geekbench: https://browser.geekbench.com/v4/cpu/16232115 (alps k50sv1_64), https://browser.geekbench.com/v4/cpu/3256309 (alps k50v1_64_om_c2k6m_mp5md).
* Sibling firmware names: `MT6750_EGOPAD_E24_OSv10_V1.0_QP1A.190711.020_k50v1_64_bsp_alps`, `MT6750_MODIO_M36_OSv10_V1.2_QP1A.190711.020_k50v1_64_bsp_alps` (https://khulnafirmwarer.com/index.php?a=downloads&b=recent) — same QP1A.190711.020 / q0 family; their boot images are sibling DTB/IKCFG sources.
* Device trees generated from sibling ROMs (prebuilt kernels/DTBs, useful for DT comparison only): https://github.com/twrpdtgen/android_device_alps_k50v1_64_bsp (branch `full_k50v1_64_bsp-user-9-PPR1.180610.011-eng.es01.20240906…`), https://github.com/Astrobooks/k50v1_64_bsp_device_tree (2026), https://github.com/kx123456781/android_device_Newsmy_k50v1_64_bsp , https://github.com/XiKoTaSu/android_device_alps_k50v1_64_bsp .
* CSDN (all returned HTTP 521 "安全验证" from this network, also via r.jina.ai; web.archive.org is blocked for this tool — read them in a browser):
  * mir3da on MTK: https://blog.csdn.net/qq_48192676/article/details/141225161 (mtk兼容Gsensor驱动 mir3da; same author's LCM post https://blog.csdn.net/qq_48192676/article/details/138906838 references `kernel-3.18/arch/arm64/configs/k50v1_64_bsp_defconfig`, `device/mediateksample/k50v1_64_bsp/`, `vendor/mediatek/proprietary/bootable/bootloader/lk/project/k50v1_64_bsp.mk` — the author works on a k50v1_64 project), https://blog.csdn.net/touxiong/article/details/86482760 (g-sensor 唤醒系统 mir3da), https://blog.csdn.net/qq_46687516/article/details/147502045 (mir3da CTS), https://blog.csdn.net/SHH_1064994894/article/details/131562313 (DA380 on Android), https://blog.csdn.net/a11778/article/details/134898706 (da223/da228 gsensor 调试); 16rd forum thread with `mir3da.rar` (MT6572 hwmsen driver) + `DS_da211.pdf`: https://bbs.16rd.com/thread-16046-1-1.html
  * PSC5415A: https://blog.csdn.net/rosir_zhong/article/details/120767576 (MT6739 充电IC集成步骤 — `CONFIG_CHARGER_PSC5415A=y`, i2c1 @0x6a, `alps/kernel-4.4/drivers/power/mediatek/charger/`, LK part too), https://blog.csdn.net/zxw0775/article/details/88827962 (MTK6580 Android P PSX5415A 快充带OTG 调试, k80bsp)
  * GC5025 / camera porting: https://blog.csdn.net/mike8825/article/details/80268397 (摄像头移植简述, `kernel-3.18/drivers/misc/mediatek/imgsensor/src/mt6735/gc5025mipi_raw/`), https://blog.csdn.net/karaskass/article/details/105995491 (MT6739 GC5035 移植, `kd_imgsensor.h` + `{GC5025_SENSOR_ID, SENSOR_DRVNAME_GC5025_MIPI_RAW, GC5025MIPI_RAW_SensorInit}`), https://blog.csdn.net/qq_30624591/article/details/85255985 , https://blog.csdn.net/u010299133/article/details/111147966 (上电分析), https://blog.csdn.net/qq_25731223/article/details/94735762 (camera/af/flashlight 添加)
  * External PA / audgpio: https://blog.csdn.net/YuZhuQue/article/details/102921048 (MTK 外部功放的驱动配置: `AudDrv_GPIO_EXTAMP_Select`, `Ext_Speaker_Amp_Change`, dws EXTAMP pin), https://blog.csdn.net/qq_25731223/article/details/99689123 (mt6739 耳机通道外置功放: disable `CONFIG_MTK_SPEAKER`, `USING_EXTAMP_HP` in audio_custom_exp.h), https://blog.csdn.net/carolven/article/details/79315551 (MT6735 耳机通道外接功放)
  * MTK gsensor calibration/HAL: https://developer.aliyun.com/article/236848 (factory `ftm_gs_cali.c` paths)
* gitee: no MT6755/MT6750 3.18 mirror found via web search (searches only surfaced the GitHub trees above).

## 6. Bring-up write-ups / mechanisms (item 4)

* **MTK sensors-1.0 HAL <-> kernel contract** (q0, identical in Nokia): each sensor type registers a misc device via `sensor_attr_register()`
  (`drivers/misc/mediatek/sensors-1.0/hwmon/sensor_attributes`) and pushes samples through `sensor_event_*` (`hwmon/sensor_event`). For the
  accelerometer: `/dev/m_acc_misc` (read/poll of `struct sensor_event`) and `/sys/class/sensor/m_acc_misc/{accactive,accdelay,accbatch,accflush,acccali,accdevnum,accenablenodata}`
  (`DEVICE_ATTR` list in `sensors-1.0/accelerometer/accel.c`); legacy `/dev/hwmsensor`, `/dev/gsensor` are still created. Ownership/permissions
  come from `device/mediatek/mt6755/init.sensor_1_0.rc` (q0) — the LOS device tree must ship equivalent lines and matching sepolicy
  (`device/mediatek/mt6755/sepolicy/{basic,bsp}` in `mtk-watch/android_device_mediatek`). The vendor HAL (`sensors.mt6755.so`/`android.hardware.sensors@1.0-impl-mediatek`)
  is proprietary; XDA porting thread https://xdaforums.com/t/mediatek-helio-p10-development-porting-guides-bug-fixes-and-more.3664416/ (Nonta72, Doogee Y6/MT6750) lists the
  sensor daemons/blobs to carry (akmd*, geomagneticd, etc.) and per-subsystem fixes (fingerprint gatekeeper/keystore libs, audio, camera, RIL).
* **Camera sensor list alignment**: the kernel enumerates `CONFIG_CUSTOM_KERNEL_IMGSENSOR` in the order of `kdSensorList[]` in
  `drivers/misc/mediatek/imgsensor/src/mt6755/kd_sensorlist.c` (each entry `{SENSOR_ID, SENSOR_DRVNAME_*, *_SensorInit}` guarded by the
  `-D<NAME>` flags that `imgsensor/src/Makefile.custom` derives from the config string); the proprietary HAL (`libcameracustom.so`,
  `custom/mt6755/hal/imgsensor_src/sensorlist.cpp` in vendor) searches by `SENSOR_DRVNAME` string + `SENSOR_ID` and expects the same
  `kd_imgsensor.h` IDs (stock added ~35 lines there vs q0). Keep the stock order
  (`imx145 sp2508 ov5670 imx135 gc2355 gc5025main gc5025 imx278 s5k5e2ya gc2235`) and the stock `kd_imgsensor.h` IDs so `/proc/driver/camera_info`
  and the HAL's index-to-name mapping match; the Echo Show write-up https://github.com/jxlarrea/lineageos-echo-show-camera documents the same
  failure mode (kernel selecting a different sensor than the HAL tuning expects).
* **External speaker amp**: q0 `sound/soc/mediatek/mt6755/AudDrv_Gpio.c` looks up pinctrl states `extamp-pullhigh/extamp-pulllow/extamp2-pullhigh/extamp2-pulllow`
  from the `audgpio` node and `AudDrv_GPIO_EXTAMP_Select(bEnable, mode)` toggles them; `mt_soc_codec_63xx.c: Ext_Speaker_Amp_Change()` calls it with mode 3
  around `Speaker_Amp` DAPM events. The reference `k50sv1_64_bsp.dts` already declares all four states — the ODM only changed the GPIO numbers
  (compare with the stock DTB). Speaker path selection is a vendor-side `MTK_AUDIO_SPEAKER_PATH` (reference `int_spk_amp`; ext PA needs `ext_spk_amp`-class audio_param/HAL config).
* **PPM/HPS/thermal**: tunables are procfs (`/proc/ppm/policy/userlimit_*`, `/proc/ppm/mode`, `/proc/hps/*`, `/proc/mtktscpu/*`) driven by
  `init.mt6755.rc` + `thermal.conf` (`device/mediatek/mt6755` and `mediateksample/k50sv1_64_bsp/thermal*.conf` in the q0 device repos) and `throttle.sh`;
  kernel side `base/power/mt6755/mt_hotplug_strategy_*.c`, `base/power/ppm_v1|ppm_v2`, `thermal/mt6755` are byte-identical between Nokia and q0.
  Note the DEVICE_REPORT finding that this SoC is efuse-binned to the MT6750/E2 table (1.508/1.001 GHz) — keep the q0 `mt_cpufreq.c` tables.
* **mtk-kpd**: q0 `drivers/input/keyboard/mediatek/kpd.c` (identical to Nokia): `request_irq(kp_irqnr, kpd_irq_handler, IRQF_TRIGGER_NONE, …)` with the
  trigger taken from DT (`keypad@10010000 { compatible = "mediatek,mt6755-keypad","mediatek,kp"; interrupts = <GIC_SPI 164 IRQ_TYPE_EDGE_FALLING>; }` in `mt6755.dts`);
  the handler does `disable_irq_nosync()` -> `tasklet_schedule(kpd_keymap_tasklet)` -> `enable_irq()` after reading `KP_MEM1..5`. A "stuck"
  keypad interrupt therefore means the tasklet never re-enabled the line (e.g. keymap tasklet bailing out early, wrong `mediatek,kpd-key-debounce`
  or a DT trigger mismatch); the reference keymap for this project is `mediateksample/k50sv1_64_bsp/mtk-kpd.kl`. No public LOS write-up for this specific bug was found.
* Generic LOS-on-MTK threads: https://xdaforums.com/t/building-lineageos-for-a-new-unsupported-device-mediatek.4701189/ (MT6580 LOS 15.1, genfscon/sepolicy pitfalls),
  device-tree scaffolds https://github.com/maximus-sallam/android_device_mediatek (LOS 21 mt6735/6739/6755/6763 common), https://github.com/GearLabs/android_device_mediatek_mt6750-common , https://github.com/LineageOS-MediaTek/android_device_mediatek_common , https://github.com/SonyCustoms/device_sony_tuba .

## 7. Gaps

* No public copy of the ODM ("RUNSUI"/F212/es01) tree: zero hits for `OS_SYSCUST`, `MTK_PSC5415_SUPPORT`, `gc5025main_mipi_raw`, `ilip6h87`, `hdplus1560`+ft8057s LCM names, `TOUCHSCREEN_HIMAX_IC_HX83102E` under mediatek.
* GC2235 MTK 3.18 driver not located (only the ID in `kd_imgsensor.h`); IMX145 exists only for mt6735m/mt6753 (3.18) — the local mt6755 port stays hand-made.
* CSDN pages could not be fetched from this environment (521); Sony developer site and web.archive.org are blocked for the fetch tool.
* Vendor blobs / HAL sources for q0 are not public (DMCA); only device configs (`android_device_mediatek*`) are.
