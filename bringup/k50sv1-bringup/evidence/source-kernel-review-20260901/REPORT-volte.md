# VoLTE / VoWiFi on the source-built kernel — kernel-side investigation (read-only)

Date: 2026-09-01 22:39–22:55 CEST. Handset 0123456789ABCDEF, root, Permissive.
Running kernel: `Linux version 3.18.119 ... #1 SMP PREEMPT Tue Sep 1 19:56:44 CEST 2026`
(source build, image eng.desmon.20260901.195217). Prebuilt reference banner:
`#1 SMP PREEMPT Thu Dec 25 16:31:40 CST 2025`.
Fixture: slot 0 China Unicom 46001 (roaming on vodafone NL 20404, LTE), slot 1 CMCC
46000 (roaming on KPN 20408, GSM). Uptime 46 min at capture. Nothing on the device
was changed except `logcat -b all -G 64M`.

All raw outputs are in this directory (`getprop.txt`, `telephony-registry.txt`,
`ipaddr.txt`, `ip6addr.txt`, `iproute.txt`, `xfrm.txt`, `sys-class-net.txt`,
`proc-net-dev.txt`, `devnodes.txt`, `lsmod.txt`, `kernel-ifaces.txt`, `ccci-sysfs.txt`,
`dmesg-live.txt`, `logcat-radio.txt`, `logcat-all.txt`, `carrier_config.txt`,
`check-volte-chain.out` + `chain-volte/`, `check-vowifi-chain.out` + `chain-vowifi/`,
`config-diff-stock-vs-source.txt`, `stock-syms.txt`/`source-syms.txt`/`syms-stock-only.txt`,
`stock-strings.txt`/`source-strings.txt`, `dmesg-*-ccci-templates.txt`,
`radio-marker-compare.txt`, `all-marker-compare.txt`, `getprop-*-all.txt`).

## 1. Verdict

**Nothing kernel-side is missing, broken, or different in a way that touches IMS.**
The source kernel's config, ccci/ccmni/XFRM/netfilter symbol inventory, device nodes,
sysfs/procfs interfaces, modem boot state and ccmni data path are all identical to
the stock kernel, and the modem is up, LTE-registered and passing data on ccmni0.

**VoLTE is not registered on this boot for exactly the reason it was not registered on
the prebuilt kernel with the same two SIMs (E-112, HANDOFF "Latest measured radio
state"):** CarrierConfig resolves `carrier_volte_available_bool=false` for 46001 and
46000, so `ImsManager.updateVolteFeatureValue: available = false` → `turnOffIms` →
`AT+EIMSVOICE=0`, `AT+EIMSVOLTE=0`, `AT+EIMS=0` → `+EIMS: 0`, and the framework never
enables the IMS APN (`ims:[state=IDLE,enabled=false]`). The modem is explicitly told not
to register. This sequence is present, line for line and with the same counts, in the
prebuilt-kernel capture (tier1-verify-cycle2-20260831T205510Z) and the source-kernel
capture (tier1-source-kernel-codec-fix-verify-20260901T183046Z).

**"VoWiFi worked" on the prebuilt kernel can only have meant "the chain up to the
carrier gate passes and stages 7–8 are skipped"** — with these SIMs no ePDG tunnel is
ever demanded (`carrier_wfc_ims_available_bool=false`, `persist.vendor.mtk.wfc.enable=0`).
That is exactly what `check-vowifi-chain.sh` reports now (20 pass, 2 fail — both the
VoLTE regression guard above — 0 unread, 3 intentionally skipped), and neither the
prebuilt nor the source capture contains a single `Query [epdg...]`, `IKE_SA` or
`woattach` line.

So the owner's report is a comparison against the wrong baseline: on this fixture the
prebuilt kernel also had `+CIREGU: 0`, MMTEL Voice=false and no IMS PDN
(HANDOFF: "check-volte-chain.sh 9 pass, 3 fail, 6 unread; +CIREGU 0; IMS PDN not
activated"). The source kernel reads 13 pass / 3 fail / 2 unread with the same three
failures. The positive control that proved VoLTE on this port (E-091, `+CIREGU: 1,5`)
used a Vodafone NL 20404 SIM in slot 0 on its home network, for which the device
overlay advertises VoLTE (carrier-id-20 allocation only).

## 2. Chain tools (live, 64 MiB ring)

`check-volte-chain.sh` → `chain: pass=13 fail=3 unread=2`, exit 1

    0  PASS radio ring is 64 MiB
    1  PASS both SIMs LOADED / ???? phone 0 mVopsSupport = 3 (NOT_SUPPORTED; non-decisive, same as prebuilt registry)
    2  PASS persist.vendor.mtk_wfc_support=1 / PASS no dm_get_ims_pdn_req refusal / PASS responseUnsolDataCallRspToMal reached MAL (1)
    3  PASS binder "wfo" published / PASS WfoService took the WifiOffloadService branch
    4  PASS vendor.mediatek.hardware.wfo@1.0::IWifiOffload registered / ???? no initHidlService() line in window
    5  PASS RDS refused 24 times during startup and then opened
    6  PASS queryEpdgRat computed a RAT ([queryEpdgRat] Call rild_rds_sdc_req success); sys_wfc_support=1
       PASS epdgConfig, isHandOver: 0, eran_type: 1 / PASS IMSM logged no rat error
    7  FAIL the IMS PDN never completed activation / PASS the PDN was not aborted
    8  FAIL +CIREGU last reported unregistered (last: +CIREGU: 0) [seen: 9 +CIREGU: 0;]
       FAIL phone 0 MmTel Capabilities - [Voice: false Video: false UT: false SMS: false]

Note on stage 6: the `queryEpdgRat ... eran_type: 1` PASS at 22:30:17 is the INTERNET
PDN (3gnet → ccmni0, 172.25.201.61, reason `roamingOn`), not an IMS PDN. It proves the
RIL→RDS→MAL RAT path and the ccmni data plane work on this kernel; the IMS PDN was never
requested because the framework never enabled the `ims` APN context.

`check-vowifi-chain.sh` → `20 pass, 2 fail, 0 unread, 3 intentionally skipped`, exit 1

    1  FAIL modem IMS NOT registered (+CIREGU: 0) / FAIL phone 0 MMTEL voice LOST (regression guard = the VoLTE state above)
    2  PASS all 11 exact ePDG paths are ordinary files
    3  PASS init.svc.wfca=running / PASS init.svc.vendor.epdg_wod=running / PASS no ePDG tombstone / PASS epdg_wod sized for 2 slots
    4  PASS wpa_supplicant -O override / PASS /data/vendor/wifi/sock/wlan0 / PASS no legacy bind mount / PASS MAL never lost wpa
    5  PASS notifyMalSimInfo OK / PASS vendor.gsm.ril.uicctype=USIM
    6  PASS config_device_wfc_ims_available=true / PASS mtk_wfc_support=1 / PASS sys_wfc_support=1 / PASS 3x wfc_avail_ovr=0
       SKIP phone 0 carrier contributes no WFC availability; effective default false
    7  SKIP home carrier does not advertise WFC; no ePDG tunnel is demanded
    8  SKIP IWLAN registration is outside this fixture
    9  PASS the RIL shim armed its attach-APN hooks (sentinel APN 25x, re-sent 0x) / PASS gsm.operator.numeric=20404,20408

## 3. Live state (source kernel)

* Properties (full list in `getprop-ims.txt`): `persist.vendor.mtk_wfc_support=1`,
  `persist.vendor.wfc.sys_wfc_support=1`, `persist.vendor.volte_support=1`,
  `persist.vendor.ims_support=1`, `persist.vendor.mtk_ct_volte_support=1`,
  `persist.vendor.mtk.volte.enable=0`, `persist.vendor.mtk.wfc.enable=0`,
  `persist.dbg.wfc_avail_ovr{,0,1}=0`, `ro.vendor.md_auto_setup_ims=0`,
  `vendor.mtk.md1.status=ready`, `ro.vendor.mtk_md1_support=10`, `ro.vendor.mtk_eccci_c2k=1`,
  `init.svc.{mtk_hal_imsa,wfca,vendor.epdg_wod,vendor.ril-daemon-mtk,vendor.ril-proxy,ccci_mdinit,vendor.ccci_fsd,vendor.ccci_rpcd}=running`,
  `init.svc.vendor.volte_{imcb,stack,ua}=stopped` (started at 148.9 s, stopped by turnOffIms — identical on the prebuilt getprop),
  `gsm.sim.state=LOADED,LOADED`, `gsm.operator.numeric=20404,20408`, `gsm.network.type=LTE,Unknown`,
  `vendor.ril.nw.signalstrength.lte.1=-111,3`.
  Full getprop diff vs the prebuilt capture (`getprop-prebuilt-all.txt` vs `getprop-live-all.txt`)
  after removing boottime/pid/timestamps: only `ro.lineage.version/ro.modversion` (date),
  `persist.netd.stable_secret`, `gsm.defaultpdpcontext.active=true` (data PDN up only in
  this boot), `vendor.audiohal.*` empties, `init.svc.mms-1-5`, and the boot-reason
  string. **No IMS/VoLTE/WFC/ePDG/RIL property differs.**
* `dumpsys telephony.registry` phone 0: voice+data IN_SERVICE, ROAMING/INTERNATIONAL, LTE,
  vodafone NL, `mVopsSupport = 3`, `mIsIwlanPreferred=false`; phone 1: NL KPN, GSM, data
  OUT_OF_SERVICE. Same field set as the prebuilt capture's telephony-registry.txt.
* `ip addr`: ccmni0 UP, 172.25.201.61/16 (3gnet, DNS 202.106.195.68/202.106.46.151);
  ccmni1..17 DOWN (noop); wlan0 up with v4+v6; ip_vti0/ip6_vti0/ip6tnl0/sit0/tunl0 present.
  No IPv6 on ccmni0 (PDN came up as `type=IP`; the RIL response says so — not kernel).
* `ip route`: `172.25.0.0/16 dev ccmni0`, `192.168.1.0/24 dev wlan0`; policy rules have
  the ccmni0 and wlan0 tables. `ip xfrm state` / `ip xfrm policy`: empty (no tunnel
  demanded), `/proc/net/xfrm_stat` all zeros (no XFRM errors), rc=0 — XFRM netlink works.
* `/sys/class/net`: ccmni0..17, ifb0/1, ip6_vti0, ip6tnl0, ip_vti0, lo, p2p0, sit0, tunl0, wlan0.
  `/proc/net/dev`: ccmni0 rx 18 pkts/6006 B, tx 31 pkts (data path alive; phone is on Wi-Fi).
* `/dev`: ccci_aud, ccci_fs, ccci_imsa, ccci_imsc, ccci_imsdc, ccci_imsem, ccci_imsv,
  ccci_ioctl0..4, ccci_ipc_1220_0, ccci_ipc_2/4/5, ccci_it, ccci_lb_it, ccci_md{1,2,3,x}_sta,
  ccci_md_log_ctrl, ccci_mdl_monitor, ccci_monitor, ccci_raw_{dbm,dhl,netd,usb}, ccci_rpc,
  ttyC0..3 (major 233/249, radio:radio), plus /dev/tun (10,200). All mirrored in
  `/sys/class/ccci_node/`. No `/dev/ccmni*` or `/dev/eemcs*` nodes — none exist on this
  platform (ccmni are netdevs; eemcs is the older external-modem driver).
* `lsmod`: only gps_drv, bt_drv, wlan_drv_gen2, wmt_chrdev_wifi, wmt_drv (all 5 from
  /vendor/lib/modules). ccci/ccmni are built in (`CONFIG_MTK_ECCCI_DRIVER=y`, `CONFIG_MTK_NET_CCMNI=y`).
* `/sys/kernel/ccci/`: `boot` = `md1:4/0 | md2:n/a | md3:n/a` → `ccci_md_get_state()=4=READY`,
  `mdee_get_ex_stage()=0` (no exception) per `mt_ccci_common.h` MD_STATE and
  `eccci/ccci_core.c:boot_md_show`. `md_en=E-D-D-D-D`, `kcfg_setting`: modem num 1,
  MTK_ECCCI_C2K 1, ccci_drv_ver V2. `lk_md`: LK load MD success. `md1_postfix=1_ulwctg_n`.
  `md_chn` shows the normal sequence: IOC_RELOAD_MD_TYPE 0xa, start MD ioctl, control
  message 0x5555FFFF then 0x0 (HS done), port opens/closes by wfca/mtkrild/volte_imcb
  with `critical user check: 0x3` and zero drops. `mdsys1/parameter`: BD_NUM=18,
  NET_buffer_number=(256,256). `/proc`: ccci_dump, ccci_log, mdstat present.
* `/proc/net/ip_tables_names`: security raw nat mangle filter; `ip6_tables_names`: raw
  mangle filter. `/proc/sys/net/ipv6/conf/ccmni0..17` present.
* dmesg (live ring starts at t=2320 s, boot scrolled out): the only ccci lines are the
  ccmni traffic monitor every 10 s: `[ccci1/net]ccmni0(1,1), irat_MD1, rx=(18,6006,0),
  tx=(31,24,7), ... tx_drop=(0,0,0), rx_drop=(0,0), tx_busy=(0,0), sta=(0x3,0x81,0x0,0x0)`
  — zero drops, zero busy. Zero xfrm/esp/ipsec/netfilter/nf_/ip6t error lines. Zero MD
  exception / EE / md_ee lines here and in the source-kernel capture's early/continuous/late dmesg.
* logcat-all complaints touching ccci/ccmni/xfrm/netfilter: none functional. The only
  hits are `ccci_rpcd/ccci_fsd: Failed to read ... errno = 4` (EINTR, 9x each, present on
  stock behaviour), `NetdagentIptables ... -D oem_mangle_post -o ccmniN -j DROP` status
  256 (deleting a rule that does not exist yet; MTK netdagent boilerplate), and
  `FS_OTP_init: open /dev/otp failed` (no OTP node; unrelated). No "Operation not
  supported", no ioctl failure on ccci/ccmni, no ENODEV on any radio node.

## 4. Kernel comparison, stock vs source

### 4a. .config
`work/.capture-staging/k50-source-config.iHHtKF/.config` is byte-identical to
`KERNEL_OBJ/.config`. Full diff against `k50-stock-config.Vh0Pll/.config`
(`config-diff-stock-vs-source.txt`, 65 lines) touches ONLY: CUSTOM_KERNEL_ALSPS,
CUSTOM_KERNEL_IMGSENSOR list, CUSTOM_KERNEL_LCM list, FRAME_WARN 1600→1700, GATOR (m→n),
K50_LCM_BIAS, MTK_GPIO_HALL, seven MTK_LENS_* AF drivers, MTK_MIR3DA, MTK_NFC/NFC_MT6605/
NFC_MSR3110, TOUCHSCREEN_MTK_FOCALTECH_FT8057. grep of the diff for
XFRM|ESP|NETFILTER|NF_|IP6|IPV6|CCCI|CCMNI|MD|IMS|C2K|LTE|EMI|CRYPTO|TUN|KEY → nothing.

Relevant symbols, identical in both (`source-config-relevant.txt`, 200 lines): CONFIG_XFRM=y,
XFRM_USER, XFRM_ALGO, XFRM_IPCOMP, XFRM_MIGRATE, XFRM_STATISTICS, XFRM_SUB_POLICY, NET_KEY,
INET_{AH,ESP,IPCOMP,TUNNEL,XFRM_TUNNEL,XFRM_MODE_{TRANSPORT,TUNNEL,BEET}}, the INET6 twins
incl. INET6_XFRM_MODE_ROUTEOPTIMIZATION, IPV6_{VTI,TUNNEL,MIP6,MULTIPLE_TABLES,SUBTREES},
TUN, full NETFILTER/NF_CONNTRACK{,_IPV4,_IPV6}/NF_NAT/IP_NF_*/IP6_NF_{IPTABLES,FILTER,
MANGLE,RAW,MATCH_*,TARGET_*}/NETFILTER_XT_{MATCH,TARGET}_* set (incl. QTAGUID, QUOTA2,
IDLETIMER, SOCKET, TPROXY, POLICY), CRYPTO_{AES,AES_ARM64_CE,SHA1,SHA256,MD5,HMAC,CBC,CTR,
GCM,DES,NULL,AUTHENC,SEQIV}; MTK: ECCCI_DRIVER, ECCCI_CLDMA, ECCCI_C2K, ECCCI_STOP_TRACE,
CCCI_DEVICES, NET_CCMNI, EMI_MPU, MD1_SUPPORT=10, MD3_SUPPORT=0, C2K_LTE_MODE=0,
CONN_LTE_IDC_SUPPORT, MD1_SIZE=0x5000000, MD1_SMEM_SIZE=0x200000; CCCI_EXT/CCCI_DRIVER
(old driver)/ECCCI_CCIF/ECCCI_UT not set in both. There is no CONFIG_MTK_IMS_SUPPORT,
MTK_ENABLE_MD1/3 or MTK_TC1_FEATURE in either config (those are userspace/prop flags on
this ALPS release). ANDROID_PARANOID_NETWORK=y both.

### 4b. Symbols
`nm k50-stock-vmlinux.elf` (47,056 symbols, kallsyms-derived) vs `System.map`, families
ccci_|ccmni_|md_|eccci|xfrm_|esp*_|ip6t_|ipt_|xt_|nf_|ah*_|ipcomp|mtk_ccci|port_|modem_|
ccif|cldma|lte_: **stock-only = 0** (`syms-stock-only.txt` is empty); source-only = 323,
all static data/attr objects not exported into stock's kallsyms (ccci_attr_*, esp4_handlers,
ip6t_builtin_mt, ...). The mt6755 ccci platform function list (md_cd_*, md1_pll_*,
md1_pmic_setting_on/off, ccci_platform_init) is identical in both. (An earlier
`strings`-based pass flagged `md1_pmic_setting_on/off` as stock-only; `nm`/System.map show
both present in source at 0xffffffc00068f968/97c — the strings hit was a filter artefact.)

### 4c. Feature strings
`strings -a` over both images for ccmni|MD_CFG|eccci|ccci ver|MTK_MD|md1_|LTE_MODE|cldma:
stock-only strings are exclusively the vendor build-path strings
`/ssd/gl/mtk6750_Q/kernel-3.18/drivers/misc/mediatek/{ccmni,eccci,eccci/mt6755}/*.c`
(and `mt_soc_pcm_voice_md1_bt.c`) — i.e. the same source files compiled from a different
directory. Source-only strings are the CCCI_CCMNI{0..17}_{RX,TX,...} trace names and
similar debug identifiers. The ccmni traffic-monitor format string
`[ccci%d/net]%s(%d,%d), irat_MD%d, rx=(...` exists in both binaries; it only shows in the
live dmesg because only this boot brought ccmni0 up (none of the reference captures had a
mobile PDN active — their dmesgs contain zero `ccmni0(1,1)` lines).

### 4d. dmesg templates (prebuilt rescue dmesg vs source early-dmesg, numbers masked)
Both have the same ccci probe sequence and stack-dump function names. Both have
`[ccci0/cif]md_ccif_probe:get hw info fail(-1)` + `ccif_modem: probe of
1020b000.ap2c2k_ccif failed with error -1` at 0.514 s (C2K CCIF for the absent MD3;
expected, identical). Source-only extra lines: `[ccci1/mcd]md_boot_stats0:0x...`,
`[PBM] MD section level init` / `APNMDN section level`, `mtk_rtc_hal_common: rtc_spare_reg`
— informational prints, not errors. No MD exception on either.

## 5. Modem health on the source kernel
`vendor.mtk.md1.status=ready`, `/sys/kernel/ccci/boot md1:4/0` (READY, no EE),
`vendor.ril.mux.ee.md1=0`, `vendor.ril.muxreport.run=0`, ccci_mdinit "modem boot ready and
deamon begin to run!", both SIMs LOADED, slot 0 LTE ROAMING on 20404 with signal
`-111 dBm`, 654 `+ECSQ` in the radio ring, internet PDN activated on ccmni0 at 22:30:17
(`requestSetupDataCallFallback ... status=0, active=2, ifname=ccmni0, addresses=172.25.201.61`,
`DcActiveState: enter`, ConnectivityService registered MOBILE[LTE] network 101). The RIL
shim's attach-APN hooks are armed (E-095/E-098 path intact). The only `EE`-looking radio
lines are `AT+CMEE=1` and the string "restart MAL if modem reset while sim switching".

## 6. The userspace link that stops VoLTE — same on both kernels

Live timeline (logcat-all, phone 0):

    21:52:29.613  AT< +CIREGU: 0                       (modem boot; IMS not registered yet)
    21:52:30.565  AT> AT+EIMSSMS=1 / EIMSVOLTE=1 / EIMSWFC=0 / EIMSVOICE=1 / AT+EIMS=1   (RIL init defaults)
    21:52:30.595  AT< +EIMS: 1
    21:54:49.221  RIL_REQUEST_SET_IMS_ENABLE -> AT+EIMS=1 -> +EIMS: 1
    21:54:50.528  ImsManager: updateVolteFeatureValue: available = false, enabled = true, nonTTY = true
    21:54:51.556  ImsManager: updateImsServiceConfig: turnOffIms
    21:54:51.560  ImsService: turnOffIms, phoneId = 0
    21:54:51.642  MFI-RDS rds_set_ui_param wfc(0), volte(0), ccp(0), wifiui(1), allow_turnoff_ims(1)
    21:54:51.646  AT> AT+EIMSVOICE=0
    21:54:51.669  AT> AT+EIMSVOLTE=0
    21:54:51.989  RIL_REQUEST_SET_IMS_ENABLE -> AT+EIMS=0
    21:54:52.002  AT< +EIMS: 0
    (repeats at 21:55:16, 21:55:27, 22:11:34, 22:13:42, 22:30:10 — every carrier-config/SIM event re-evaluates and re-issues turnOffIms)

`dumpsys carrier_config` phone 0 and 1: `carrier_volte_available_bool = false`,
`carrier_wfc_ims_available_bool = false` (Default section; no mConfigFromDefaultApp
override for 46001/46000 — E-112 removed the CU fragment on purpose). `available` in
`updateVolteFeatureValue` is `isVolteEnabledByPlatform()`, which ANDs that key; hence
`turnOffIms`. DcTracker consequently never enables the IMS ApnContext:
`ims:[state=IDLE,enabled=false]` in every `setupDataOnAllConnectableApns` line, so no IMS
PDN request reaches the RIL (stage 7 FAIL), the modem holds `+CIREGU: 0` (stage 8 FAIL),
and MMTEL caps are false. `ImsManager: changeMmTelCapability` requests carry only
`mCapabilitiesToDisable` (VOICE LTE+IWLAN, VIDEO, UT).

Counts, `all-marker-compare.txt` (prebuilt capture / source-kernel capture / live):

    updateVolteFeatureValue: available = false     6 / 6 / 9
    updateVolteFeatureValue: available = true      0 / 0 / 0
    updateImsServiceConfig: turnOffIms             6 / 6 / 9        turnOnIms  0 / 0 / 0
    AT> AT+EIMS=0                                  1 / 1 / 1        AT< +EIMS: 0  1 / 1 / 1
    AT> AT+EIMSVOLTE=0                             1 / 1 / 1
    AT< +CIREGU: 0  (all buffers)                  3 / 3 / 3        +CIREGU: 1  0 / 0 / 0
    PDN_ACT_COMPLETED / rat error                  0 / 0 / 0
    Query [epdg / IKE_SA / woattach                0 / 0 / 0
    WfoService new WifiOffloadService              1 / 1 / 1
    attach-APN re-send armed                       1 / 1 / 1

Radio-buffer markers (`radio-marker-compare.txt`) are likewise identical between the two
captures: `+CIREGU: 0` 9/9, `EPDG is not supported` 0/0, `rat error` 0/0, `for IMS in
wrong state` 0/0, `RADIO_NOT_AVAILABLE` 18/18 (CDMA broadcast config; expected per HANDOFF).
The prebuilt RESULT.txt itself records `UNREAD modem IMS registration: +CIREG registered`,
`UNREAD MMTEL voice capability` and `PASS phone 0 home 46001: unproven carrier VoLTE
remains false` — the same three lines the source-kernel RESULT.txt has.

## 7. VoWiFi specifically
Kernel: XFRM/ESP/AH/IPCOMP/VTI/TUN/netfilter all built in and identical to stock;
`ip xfrm` works; `/dev/tun` present. Userspace: the 29-blob ePDG plane is installed,
`wfca` and `vendor.epdg_wod` are running (epdg_wod sized for 2 slots), the wpa control
socket exists, MAL learned the SIM, all five platform gates are correct. Nothing is demanded
of the kernel because the carrier gate is false and `persist.vendor.mtk.wfc.enable=0`
(both identical on the prebuilt getprop). E-093/E-096 note the CU home ePDG FQDN has no
A/AAAA record anyway. There is no VoWiFi regression to attribute to the kernel; there was
no VoWiFi tunnel on the prebuilt kernel either (0 `Query [epdg`, 0 `IKE_SA`, `charon` only
in the 2 boot-time "stopping" lines that vowifi-feasibility.md says not to count).

## 8. Ranked hypotheses

1. **(Strongest — proven) Userspace carrier gate, not the kernel.** CU 46001 / CMCC 46000
   resolve `carrier_volte_available_bool=false` → `ImsManager.turnOffIms` → `AT+EIMS=0`.
   Evidence: section 6 timeline; identical counts on the prebuilt-kernel capture; E-112;
   HANDOFF "Latest measured radio state" (prebuilt: 9/3/6, +CIREGU 0, IMS PDN not activated).
   The source kernel changes nothing here. To see `+CIREGU: 1,5` again this fixture needs a
   SIM whose CarrierConfig advertises VoLTE (the E-091 Vodafone NL card / carrier-id-20
   allocation) — that is a fixture/config choice for the owner, not a kernel fix.
2. **(Disproven) "Kernel lacks X".** No stock ccci/ccmni/md/xfrm/esp/ip6t/xt/nf symbol is
   absent from the source kernel (0 stock-only); the resolved `.config` differs only in
   camera/touch/sensor/NFC/LCM/debug options; all ccci device nodes, sysfs and procfs
   interfaces exist; modem state READY with no exception; internet PDN activates on ccmni0
   with zero drops; XFRM netlink answers and reports zero errors.
3. **(Disproven) "Userspace can't talk to the kernel".** Zero ioctl/ENOTSUP/ENODEV
   complaints on ccci/ccmni/xfrm/netfilter in 360k logcat lines; `ccci_mdinit` reached
   "modem boot ready"; `RIL-OEM: CCCI ioctl result: ret_val=0`; `responseUnsolDataCallRspToMal`
   reached MAL; RDS/MAL/WFO/wfo-HIDL all up.
4. **(Cosmetic, source-only) Extra kernel prints:** `md_boot_stats`, `[PBM] MD section
   level init`, `rtc_spare_reg`, and the 10-second `ccmni0 ... irat_MD1` monitor (present
   in stock's binary too, only visible when a ccmni is up). None are errors.

If the intent is to re-prove VoLTE on the source kernel, the exact links to satisfy are
`check-volte-chain.sh` stages 7 and 8, and what they need is `updateVolteFeatureValue:
available = true` (a VoLTE-advertising CarrierConfig for the inserted slot-0 SIM, or the
Vodafone NL card) so DcTracker enables the `ims` ApnContext and the RIL issues the IMS
`SETUP_DATA_CALL`. Everything below that — RIL, RDS, MAL, ccci, ccmni, XFRM — is already
measured working on this kernel.
