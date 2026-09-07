# WI-080 / E-151 — Volume Up dies inside `mtk-kpd`: driver-source analysis

Date: 2026-09-01. Sources (all read-only): kernel
`lineage-17.1/kernel/xsh/k50sv1_64_bsp` (the keypad driver lives in
`drivers/input/keyboard/mediatek/{kpd.c,kpd.h,mt6755/hal_kpd.c,mt6755/hal_kpd.h}`;
there is no `drivers/misc/mediatek/keypad/` — the stock vmlinux's path strings say the same:
`/ssd/gl/mtk6750_Q/kernel-3.18/drivers/input/keyboard/mediatek/kpd.c` and `mt6755/hal_kpd.c`),
stock binary `work/.capture-staging/k50-stock-vmlinux.elf`, stock DT
`factory_image_unpacked/dtb/{boot_dtb.dts,odmdtbo.dts}`, framework
`frameworks/base/.../PhoneWindowManager.java` and `frameworks/native/.../InputDispatcher.cpp`,
plus read-only measurements on the live handset (source kernel `#1 SMP PREEMPT Tue Sep 1 19:56:44 CEST 2026`, uptime 51 min).
Patch file: `kpd-wi080.patch` next to this report (also embedded in section 5). Nothing was applied, written to the handset, or committed.

---

## TL;DR

* **Kernel half (established from E-151's own numbers).** The two volume keys are single-ended
  column switches: Volume Down = KCOL0 (GPIO103), Volume Up = KCOL1 (GPIO104), each to ground.
  E-151's "released" register dump `fbfd eff7 bfdf ff7f fe` has exactly the eight column-1 bits low
  (hw 1,10,19,28,37,46,55,64), i.e. **the keypad block saw KCOL1 permanently low = Volume Up
  permanently pressed**. A physical press then changes nothing → no debounced change → no IRQ →
  no `kpd: register` line (`kpd.c:434-440`). Column 0 is unaffected, so Volume Down keeps
  working on the same IRQ. The 10.8 s "press" was the onset: the column going low *is* a press to
  the block, and the release never came because the column never went high again.
* **Framework half (established from source).** The DOWN latched
  `PhoneWindowManager.mA11yShortcutChordVolumeUpKeyTriggered` (`:4433-4435`); the only thing that
  clears it is a VOLUME_UP UP passing `interceptKeyBeforeQueueing` (`:4445-4446`), and the
  dispatcher's synthesised `FLAG_CANCELED` UP never goes there (`InputDispatcher.cpp:2444-2497`
  vs the two policy call sites `:2691` notifyKey, `:2891` injectInputEvent). With the flag set,
  `interceptPowerKeyDown` computes `mPowerKeyHandled = … || mA11yShortcutChordVolumeUpKeyTriggered`
  (`:1161-1162`) → no `wakeUpFromPowerKey` (`:1191/:1207`) and `interceptPowerKeyUp` treats the
  press as handled (`:1221-1222`) → no sleep; `GestureLauncherService.interceptPowerKeyDown` runs
  *before* that check (`:1146-1148`) → double-press camera still works. E-151's "left
  unexplained" half is therefore explained, and it is not a kernel fault.
* **What holds KCOL1 low is not yet caught in the act.** The pad was an output
  (`GPIO_EXT_LDO_EN_PIN`) in the reference design and MediaTek's IRTX driver hard-codes it as an
  output, but that driver is not built on this board; no other software writer of GPIO104 exists
  in this tree. The proposed patch (a) records registers + pad state and names any runtime writer of
  the keypad pads, (b) recovers what software can recover and un-latches the framework within
  20 s so the power key never dies again, (c) removes the suspend-time `KP_EN` clearing that
  `kpd_call_state=2` works around.
* **Stock and source drivers are the same code**: identical symbol set, identical function sizes,
  and the normalised disassembly of every kpd function (8 ranges, 1,234 instructions) differs in
  zero lines. Whatever E-151 measured on the prebuilt kernel, the source build reproduces.

---

## 1. Key → matrix / PMIC mapping on this board

| Key | Linux code | Source of the event | Proof (file:line) |
|---|---|---|---|
| VOLUME_DOWN | 114 (0x72) | KP matrix hw 0 = row 0 / col 0 = **KCOL0 = GPIO103, pad mode 1** | `odmdtbo.dts:1505` `kpd-hw-init-map[0]=0x72`; `mt6755-pinfunc.h:692`; `kpd.c:410-416` (`hw_keycode=(i<<4)+j`, `kpd_keymap[hw]`); DWS `k50sv1_64_bsp.dws:1264-1277` (`GPIO_KPD_KCOL0_PIN`) |
| VOLUME_UP | 115 (0x73) | KP matrix hw 1 = row 0 / col 1 = **KCOL1 = GPIO104, pad mode 1** | `odmdtbo.dts:1505` `[1]=0x73`; `mt6755-pinfunc.h:696`; LK keys `kpd-hw-dl-key0=1`, `kpd-hw-recovery-key=1` (`odmdtbo.dts:1508,1511`) |
| POWER | 116 (0x74) | **PMIC MT6353 PWRKEY interrupt**, not the matrix | `k50sv1_64_bsp_defconfig:384` `CONFIG_KPD_PWRKEY_USE_PMIC=y`; `pmic/mt6353/pmic_irq.c:201-241` (`pwrkey_int_handler[_r]` → `kpd_pwrkey_pmic_handler`), `kpd.c:356-370`, `hal_kpd.c:400-413` reports `kpd_sw_pwrkey`; `odmdtbo.dts:1499` (`sw-pwrkey=0x74`). `hw-pwrkey=8` is only the reference matrix slot, zeroed at `kpd.c:850-853` |
| HOME | 102 (0x66) | **PMIC HOMEKEY interrupt** (`sw-rstkey`) | `odmdtbo.dts:1501-1502` (`sw-rstkey=0x66`, `hw-rstkey=0x11`=17); `pmic_irq.c:247-264` → `kpd.c:373-384` → `hal_kpd.c:386-398`; the matrix slots 17,26,…,71 (column 8) are zeroed at `kpd.c:854-857` ("only [8] works for Power key"); `mtk-kpd.kl` leaves 102 undeclared so InputReader drops it |
| RESTART | 408 | `mrdump_ext_rst-eint` EINT, `CONFIG_MTK_MRDUMP_KEY=y` (`defconfig:385`), `hal_kpd.c:436-455` | not populated; `.kl` leaves it undeclared |

* `hw-rstkey = 17` = row 1, col 8 = the "PMIC column" reference position; nothing in the driver
  ever reports it from the matrix, so it cannot mask Volume Up (hw 1).
* Rows: KROW0 = GPIO102 in keypad mode, output (DWS `:1250-1263`; live pad `102:100011100`).
  KPROW1 = GPIO101 and KPROW2/KPCOL2 = GPIO43/42 are *not* in keypad mode (live 101 is mode 0;
  DWS names them `GPIO_EINT_CHG_STAT_PIN`, `GPIO_OTG_DRVVBUS_PIN`, `GPIO_EINT_WPC_PIN`).
* **Wiring, inferred from E-151's dumps:** Volume Down toggles hw {0,9,18,27,36,45,54,63} =
  column 0 in *all eight* row phases (`0xfbfd^0xf9fc=0x0201`, `0xeff7^0xe7f3=0x0804`,
  `0xbfdf^0x9fcf=0x2010`, `0xff7f^0x7f3f=0x8040`). A switch to KROW0 would only read in row 0.
  So each volume key shorts its column pad to a static low (ground); the column reads "pressed"
  whenever the pad input is low, for whatever reason. The pad pull-up (live: PULL_EN=1,
  PULL_SEL=1) is the only thing holding it high.
* Reference vs ODM: the DWS keypad block (`:2117-2138`) has only VOLUMEDOWN in the matrix and
  `<home_key>VOLUMEUP</home_key>` (PMIC HOMEKEY), and GPIO104 is `GPIO_EXT_LDO_EN_PIN`, mode 0,
  output (`:1278-1291`). The ODM moved Volume Up onto KCOL1 and changed only the DTBO
  (`odmdtbo.dts:1496-1514`, fragment@66 → `&keypad`; the boot DTB node `boot_dtb.dts:666-672` is
  bare: `interrupts = <0 0xa4 0x2>` = SPI 164, edge-falling = Linux IRQ 196). Whether the switch is
  *also* still wired to the PMIC HOMEKEY pin is unproven; if it is, a healthy Volume Up press also
  prints `kpd: (pressed) HW keycode =102 using PMIC`.

Register model (`hal_kpd.h:20-35`): KP_STA 0x00, KP_MEM1-5 0x04-0x14 (bit = 1 released, 0
pressed; 8×9 = 72 keys, hw = 16·i + bit = row·9 + col), KP_DEBOUNCE 0x18 (1024 → 32 ms at
32 kHz, `odmdtbo.dts:1498`), KP_SCAN_TIMING 0x1c, KP_SEL 0x20 (COL0/1/2_SEL bits defined, never
written), KP_EN 0x24. The kernel writes only KP_DEBOUNCE (probe, `kpd.c:900`) and KP_EN
(`enable_kpd`, `hal_kpd.c:87-96`, from the PM hooks). `kpd_keymap_state[]` (`kpd.c:38`) is written
only by the tasklet (`kpd.c:429`); the HAL keeps a *second*, separate shadow (`hal_kpd.c:41-43`)
used only by the factory-mode path.

## 2. Ranked mechanisms for E-151's exact symptom set

**M1 — KCOL1 (GPIO104) input held low. Established.** Path: pad low → block debounces column 1
as pressed in every row → one IRQ at onset (`kpd_irq_handler` `kpd.c:434-440` → tasklet
`kpd_keymap_handler` `:389-432` → `report Linux keycode = 115`, `pressed`) → no further change
on that column → no IRQ, no dump, no release, ever. Column 0 (Volume Down) and the PMIC power
key are untouched at kernel level. Sub-causes, ranked:

1. *Pad reconfiguration by software* (mode ≠ 1, or DIR=out, or pull disabled/down). Designed-in
   hazard: MediaTek's IRTX driver hard-codes this pad as the IR-LED enable output
   (`drivers/misc/mediatek/irtx/mt6755/mt_irtx.c:55` `IRTX_GPIO_EN (GPIO104|0x80000000)`,
   `:240-242, :266-268, :365-367, :403-405` `mt_set_gpio_mode(GPIO104, GPIO_MODE_00)` + output),
   and the ODM DTBO still names the `irtx_gpio_en_default/set` states while their `@gpio104`
   nodes are **empty** (`odmdtbo.dts:699-703, 730-737`). But `CONFIG_MTK_IRTX_SUPPORT` is unset
   in both defconfigs (`k50sv1_64_bsp_stock_defconfig:1469-1470`), `/dev/irtx` does not exist, and
   the stock vmlinux has zero `[IRTX]` strings — so it is not the actor on this build. No other
   writer exists: no kernel reference to GPIO104 by number or by its DWS name
   (`GPIO_EXT_LDO_EN` → 0 hits), no pinmux for pin 104 in either DTB (no `0x68xx` `pins` values),
   pinctrl shows pins 101-104 `MUX UNCLAIMED`, and ECCCI/C2K (`CONFIG_MTK_ECCCI_C2K=y`; the pad's
   alternate functions are `C2K_URXD0/1`, `C2K_DM_EINT1`) never sets GPIO modes. Verdict: not
   identified; must be caught, not guessed — the patch's guard does that.
2. *Electrical*: sticky/dirty dome, moisture or ESD on the KCOL1 net, or the pad pull-up being
   marginal. A reboot fixing it does not discriminate (a WDT/long-press reset restarts the PMIC
   rails on this platform, so the pads are power-cycled either way).
3. *Keypad block internal state* (debounce/synchroniser) latched for column 1 and cleared by a
   KP_EN 0→1 cycle — the very toggle the stock driver performed on every suspend/resume before
   `kpd_call_state=2` disabled it. Unverifiable from source; cheap to try (the patch tries it).

*Confirming evidence on the device (next occurrence):*
* `cat /proc/interrupts | grep mtk-kpd` before/after N Volume Up presses: **+0** (fault) vs +2 per
  press; Volume Down +2 per press in both states (proves the IRQ path is alive).
* `dmesg | grep 'kpd: register'` after a Volume Down press: idle state with
  `MEM1&0x0402==0, MEM2&0x1008==0, MEM3&0x4020==0, MEM4&0x0080==0, MEM5&0x0001==0` = column 1
  low (healthy: `ffff ffff ffff ffff ff`).
* `cat /sys/devices/virtual/misc/mtgpio/pin | grep -E '^(102|103|104):'` — nine digits
  `MODE PULL_SEL DIN DOUT PULL_EN DIR IES SMT DRV` (`gpio/mt6755/mt_gpio_debug.c:454-462`).
  Healthy baseline measured today: `103:111010100`, `104:111010100`. In the fault, with nobody
  pressing: DIN (3rd digit) = 0 confirms M1; then MODE/PULL_SEL/PULL_EN/DIR ≠ `1/1/1/0` ⇒ sub-cause
  1 (software; the patched kernel prints `mt_gpio: GUARDED pin 104: set_xxx(..) by <comm>` plus a
  stack trace naming the writer); all intact ⇒ 2 or 3, split by
  `echo 1 > /sys/bus/platform/drivers/mtk-kpd/kpd_recover` (patched): clears ⇒ 3, stays low ⇒ 2.
* `dumpsys input | grep -A12 'Device .*mtk-kpd'` → `KeyDowns: 1`; `getevent -lt` → no
  `KEY_VOLUMEUP`. If `KEY_HOME` (0066) events *do* appear on Volume Up presses while faulted, the
  switch is dual-wired to PMIC HOMEKEY and the net is not stuck — that points at the pad/block
  (sub-causes 1/3), not the switch.
* Patched kernel: `cat /sys/bus/platform/drivers/mtk-kpd/kpd_hw` at any time, and the automatic
  `kpd: stuck check: …` block in dmesg 20 s after the onset (registers, pads, shadow, IRQ count).

**M2 — Framework latch (the power-key half). Established.** Code path above (TL;DR). Extra
consequences worth knowing while latched: a power press also arms the ringer-toggle chord
(`PhoneWindowManager.java:1594ff`, VOLUME_HUSH) and a Volume Down press arms the accessibility
shortcut chord (`:1578-1590`). Two no-reboot resets follow from the source, both untested:
`adb shell input keyevent 24` (an injected VOLUME_UP goes through `interceptKeyBeforeQueueing`,
`InputDispatcher.cpp:2889-2891`, so its UP clears the flag) and `stop; start` (E-151 saw
`KeyDowns` reset). Neither revives Volume Up; only the kernel side can.

**M3 — Shadow desync across suspend (the E-024 class). Excluded for E-151, real otherwise.**
`kpd_pdrv_suspend` (`kpd.c:947-960`) clears KP_EN unless `call_status==2`; the IRQ is edge-triggered
(DT `<0 0xa4 0x2>`, `IRQF_TRIGGER_NONE` at `kpd.c:901`) and `kpd_pdrv_resume` (`:962-975`) never
re-reads KP_MEM, so an edge lost while disabled leaves `kpd_keymap_state[]` wrong. Its symptom
differs from E-151: IRQs and `kpd: register` dumps still appear on every press, presses are
swallowed and releases reported (XOR against a stale shadow). Mitigated today by
`kpd_call_state=2`; fixed structurally by the patch.

**M4 — PMIC long-press reset (`kpd_enable_lprst`). Excluded.** `long_press_reboot_function_setting`
(`hal_kpd.c:247-325`) with `CONFIG_KPD_PMIC_LPRST_TD=0` (`defconfig:383`) and neither
`CONFIG_ONEKEY/TWOKEY_REBOOT_*` set only logs `Normal Boot long press reboot selection` /
`Enable normal mode LPRST` and writes nothing; `RG_PWRKEY_RST_EN/RG_HOMEKEY_RST_EN` govern the PMIC
key pins only and cannot pull a matrix column. PMIC IRQs for PWRKEY/HOMEKEY press+release are
enabled together (`pmic_irq.c:478-480`, `INT_CON0_SET 0xf`; callbacks `:487-490`).

**M5 — Factory-mode ioctl. Excluded.** `SET_KPD_KCOL` (`kpd.c:726-729` → `hal_kpd.c:203-244`)
reports from the HAL's separate shadow and could leave the input core with a press the tasklet
never releases, but it needs a root process on `/dev/mtk-kpd` (0600) and does not stop IRQs.

**M6 — IRQ left disabled** (`disable_irq_nosync` without `enable_irq`): would kill both keys; Volume
Down working excludes it. **M7** — `kpd_slide_qwerty_init` is empty (`KPD_HAS_SLIDE_QWERTY 0`),
there is no per-key mask API (`kpd_key_mask`/`kpd_masked_*` do not exist in this driver), KP_SEL is
never written. **M8** — clock/power gating of the block would kill all keys; the block is in the
always-on domain and `get kpd-clk fail, but not return` is the normal log for a DT node without
`clocks`. **M9** — `kpd_pdrv_remove` is `return 0` (`kpd.c:941-944`): that is why E-151's `unbind`
was a no-op and `bind` failed with EBUSY (`request_irq` on the still-owned line).

## 3. Stock binary vs source

* `nm` symbol sets identical (`kpd_*`, `sb_kpd_*`); per-function sizes from the two symbol tables
  identical (e.g. `kpd_keymap_handler` 0x364, `kpd_pdrv_probe` 0x524, `kpd_get_keymap_state` 0x74).
* Normalised disassembly (`aarch64-linux-android-objdump`, addresses/immediates/symbols masked)
  of `kpd_keymap_handler`, `kpd_irq_handler`, `kpd_pdrv_suspend/resume`, `kpd_store_call_state…
  kpd_dev_ioctl`, `kpd_pwrkey_pmic_handler…kpd_get_dts_info`, `kpd_pdrv_probe`, and the whole HAL
  (`kpd_get_keymap_state…kpd_pwrkey_handler_hal`): 217/19/58/68/162/329/230/151 instructions each,
  **0 differing lines**. Note for future work: the reconstructed stock ELF loads `_stext` at its
  PT_LOAD base (`0xffffffc000082000`) while kallsyms use the `0x80000` link base, so disassemble the
  stock file at `<kallsyms address> + 0x2000`.
* Same relevant config on both: `CONFIG_KPD_PWRKEY_USE_PMIC=y`, `CONFIG_KPD_PMIC_LPRST_TD=0`,
  `CONFIG_MTK_MRDUMP_KEY=y`, `CONFIG_MTK_PMIC_CHIP_MT6353=y`, no `CONFIG_MTK_LEGACY`, no IRTX, no
  SMARTBOOK (`sb_kpd_enable empty function for HAL!` in both). Strings match one-for-one.

## 4. Live baseline (today, healthy)

```
/proc/interrupts:  196:  1  0  GIC 196  mtk-kpd     (1 IRQ in 51 min, no volume presses in the retained log; a press adds 2)
mtgpio pin:        102:100011100  103:111010100  104:111010100   (MODE PULL_SEL DIN DOUT PULL_EN DIR IES SMT DRV)
pinctrl:           pins 101-104 (MUX UNCLAIMED) (GPIO UNCLAIMED)
dumpsys input:     Device 4: mtk-kpd  /dev/input/event2  KeyLayoutFile /vendor/usr/keylayout/mtk-kpd.kl  KeyDowns: 0
/dev/mtk-kpd:      crw------- root   (ioctl SET_KPD_KCOL reachable by root only)
kpd_call_state:    2 ; /dev/irtx: absent ; ACCDET (event1) still advertises 0x72/0x73 (neutralised by ACCDET.kl)
dmesg (retained window only): PMIC power key press/release logged as "HW keycode =116 using PMIC"
```

## 5. Proposed patch (unified diff, NOT applied)

Files: `drivers/input/keyboard/mediatek/kpd.c`, `mt6755/hal_kpd.c`, `mt6755/hal_kpd.h`,
`drivers/misc/mediatek/gpio/mt_gpio_core.c`. All four pass `-fsyntax-only -Wall` with the exact
compiler command recorded in the build tree's `.kpd.o.cmd` / `.hal_kpd.o.cmd` /
`.mt_gpio_core.o.cmd` (the kpd Makefile adds `-Werror`); nothing was written to the build tree.

What it does, by priority:
1. **Evidence at the moment of the fault.** `kpd_hw` sysfs (registers KP_STA/MEM1-5/DEBOUNCE/
   SCAN_TIMING/SEL/EN, pads 102-104 mode/dir/pull/din/dout, shadow, forced-up mask, valid mask,
   IRQ count) and, in `mt_gpio_core.c`, a `GUARDED pin` log + `dump_stack()` for any runtime write
   to GPIO102/103/104. Every legacy setter and every pinctrl write on MT6755 goes through
   `MT_GPIO_OPS_SET` (`pinctrl-mt6755.c:310-318` points the devdata hooks at the legacy API), so
   one hook sees them all. It logs only.
2. **Recovery without reboot.** A delayed work armed whenever a mapped key is down
   (`kpd_stuck_check_ms`, default 20000, module parameter). After the timeout: snapshot → if a
   column pad's mode/dir/pull is wrong, restore it → KP_EN 0→1 restart → re-read. If the column is
   still low, the key is released in software and hidden behind `kpd_forced_up` until the hardware
   reads it up (no ghost re-press on the next Volume Down IRQ, no double release later). This
   un-latches the framework (power key, chords, auto-repeat) within 20 s. `kpd_recover` sysfs
   runs the same path on demand. It cannot revive a column that is electrically held low; it
   makes the fault survivable and self-documenting.
3. **Suspend/resume.** Never clear KP_EN; on resume re-read KP_MEM and report the differences
   under `tasklet_disable()`. This is the structural fix for E-024's class.
4. **`kpd_pdrv_remove`** does a real teardown so `unbind`/`bind` becomes a usable re-probe.

Caveats: the 20 s threshold exceeds every legitimate hold this platform knows (the AEE
VolUp+VolDown 5-15 s timers are inert) but is a parameter; the KP_EN restart can produce a
release/press pair for a key that is genuinely held at that moment (end state is still correct);
the stack-trace guard is chatty only if something actually writes those pads, which is the point.

```diff
diff -urN a/drivers/input/keyboard/mediatek/kpd.c b/drivers/input/keyboard/mediatek/kpd.c
--- a/drivers/input/keyboard/mediatek/kpd.c	2026-09-01 23:03:56.168222277 +0200
+++ b/drivers/input/keyboard/mediatek/kpd.c	2026-09-01 23:09:14.485879913 +0200
@@ -36,6 +36,19 @@
 /*for kpd_memory_setting() function*/
 static u16 kpd_keymap[KPD_NUM_KEYS];
 static u16 kpd_keymap_state[KPD_NUM_MEMS];
+/*
+ * WI-080 (E-151): a column held low makes the block report one press and no
+ * release, ever, while every later press of that key is invisible (no state
+ * change, no IRQ).  kpd_valid_mask marks the bits that carry a mapped key,
+ * kpd_forced_up the keys released in software while their column still reads
+ * low; they stay hidden until the hardware agrees they are up.
+ */
+static u16 kpd_valid_mask[KPD_NUM_MEMS];
+static u16 kpd_forced_up[KPD_NUM_MEMS];
+static unsigned int kpd_stuck_check_ms = 20000;
+static unsigned int kpd_irq_count;
+static void kpd_stuck_work_func(struct work_struct *work);
+static DECLARE_DELAYED_WORK(kpd_stuck_work, kpd_stuck_work_func);
 #if (defined(CONFIG_ARCH_MT8173) || defined(CONFIG_ARCH_MT8163) || defined(CONFIG_ARCH_MT8167))
 static struct wake_lock pwrkey_lock;
 #endif
@@ -147,8 +160,37 @@
 
 static DRIVER_ATTR(kpd_call_state, S_IWUSR | S_IRUGO, kpd_show_call_state, kpd_store_call_state);
 
+/* WI-080: registers, pads, shadow and counters in one read; a manual recovery. */
+static ssize_t kpd_show_hw(struct device_driver *ddri, char *buf)
+{
+	int n = kpd_hw_snapshot(buf, PAGE_SIZE);
+
+	n += scnprintf(buf + n, PAGE_SIZE - n,
+		       "shadow=%04x %04x %04x %04x %04x forced_up=%04x %04x %04x %04x %04x valid=%04x %04x %04x %04x %04x\n",
+		       kpd_keymap_state[0], kpd_keymap_state[1], kpd_keymap_state[2],
+		       kpd_keymap_state[3], kpd_keymap_state[4],
+		       kpd_forced_up[0], kpd_forced_up[1], kpd_forced_up[2], kpd_forced_up[3], kpd_forced_up[4],
+		       kpd_valid_mask[0], kpd_valid_mask[1], kpd_valid_mask[2], kpd_valid_mask[3], kpd_valid_mask[4]);
+	n += scnprintf(buf + n, PAGE_SIZE - n, "irq=%u stuck_check_ms=%u call_state=%lu\n",
+		       kpd_irq_count, kpd_stuck_check_ms, call_status);
+	return n;
+}
+
+static ssize_t kpd_store_recover(struct device_driver *ddri, const char *buf, size_t count)
+{
+	kpd_print("recovery requested from sysfs\n");
+	mod_delayed_work(system_wq, &kpd_stuck_work, 0);
+	flush_delayed_work(&kpd_stuck_work);
+	return count;
+}
+
+static DRIVER_ATTR(kpd_hw, S_IRUGO, kpd_show_hw, NULL);
+static DRIVER_ATTR(kpd_recover, S_IWUSR, NULL, kpd_store_recover);
+
 static struct driver_attribute *kpd_attr_list[] = {
 	&driver_attr_kpd_call_state,
+	&driver_attr_kpd_hw,
+	&driver_attr_kpd_recover,
 };
 
 /*----------------------------------------------------------------------------*/
@@ -386,18 +428,41 @@
 /*********************************************************************/
 
 /*********************************************************************/
-static void kpd_keymap_handler(unsigned long data)
+static bool kpd_any_key_down(const u16 state[])
+{
+	int i;
+
+	for (i = 0; i < KPD_NUM_MEMS; i++)
+		if (~state[i] & kpd_valid_mask[i])
+			return true;
+	return false;
+}
+
+/* Re-arm the stuck-key check while a mapped key is down, drop it otherwise. */
+static void kpd_arm_stuck_check(void)
+{
+	if (kpd_any_key_down(kpd_keymap_state))
+		mod_delayed_work(system_wq, &kpd_stuck_work, msecs_to_jiffies(kpd_stuck_check_ms));
+	else
+		cancel_delayed_work(&kpd_stuck_work);
+}
+
+/*
+ * Report every difference between a fresh hardware read and the shadow.
+ * Callers serialise against the tasklet (they are the tasklet, or hold
+ * tasklet_disable()).
+ */
+static void kpd_report_changes(u16 new_state[])
 {
 	int i, j;
 	bool pressed;
-	u16 new_state[KPD_NUM_MEMS], change, mask;
+	u16 change, mask;
 	u16 hw_keycode, linux_keycode;
 
-	kpd_get_keymap_state(new_state);
-
-	wake_lock_timeout(&kpd_suspend_lock, HZ / 2);
-
 	for (i = 0; i < KPD_NUM_MEMS; i++) {
+		/* keys released in software: hidden until the hardware reads them up */
+		kpd_forced_up[i] &= ~new_state[i];
+		new_state[i] |= kpd_forced_up[i];
 		change = new_state[i] ^ kpd_keymap_state[i];
 		if (!change)
 			continue;
@@ -426,19 +491,89 @@
 		}
 	}
 
-	memcpy(kpd_keymap_state, new_state, sizeof(new_state));
+	memcpy(kpd_keymap_state, new_state, KPD_NUM_MEMS * sizeof(u16));
 	kpd_print("save new keymap state\n");
+}
+
+static void kpd_keymap_handler(unsigned long data)
+{
+	u16 new_state[KPD_NUM_MEMS];
+
+	kpd_get_keymap_state(new_state);
+
+	wake_lock_timeout(&kpd_suspend_lock, HZ / 2);
+
+	kpd_report_changes(new_state);
+	kpd_arm_stuck_check();
 	enable_irq(kp_irqnr);
 }
 
 static irqreturn_t kpd_irq_handler(int irq, void *dev_id)
 {
+	kpd_irq_count++;
 	/* use _nosync to avoid deadlock */
 	disable_irq_nosync(kp_irqnr);
 	tasklet_schedule(&kpd_keymap_tasklet);
 	return IRQ_HANDLED;
 }
 
+/*
+ * A mapped key has read "pressed" for kpd_stuck_check_ms.  Record the
+ * evidence, repair what software can repair (pad configuration, block state),
+ * and if the column is still low release the key in software so the input
+ * core and PhoneWindowManager stop treating it as held (E-151: dead power
+ * key, armed a11y/ringer chords, 160 auto-repeats).  Runs in process context.
+ */
+static void kpd_stuck_work_func(struct work_struct *work)
+{
+	u16 hw[KPD_NUM_MEMS], mask;
+	char snap[512];
+	int i, j;
+
+	kpd_get_keymap_state(hw);
+	if (!kpd_any_key_down(hw))
+		return;		/* released meanwhile; the IRQ path reports it */
+
+	kpd_hw_snapshot(snap, sizeof(snap));
+	kpd_print("stuck check: a matrix key has read pressed for %u ms, irq=%u\n%s",
+		  kpd_stuck_check_ms, kpd_irq_count, snap);
+
+	if (!kpd_kcol_pads_sane()) {
+		kpd_print("stuck check: column pad configuration disturbed, restoring\n");
+		kpd_kcol_pads_reinit();
+	}
+	kpd_hw_restart(kpd_dts_data.kpd_key_debounce);
+	/*
+	 * Debounce counts 32 kHz ticks.  Wait for a fresh scan and for the
+	 * tasklet the restart may trigger, so the shadow is current below.
+	 */
+	msleep(100 + 2 * (kpd_dts_data.kpd_key_debounce / 32 + 1));
+
+	kpd_get_keymap_state(hw);
+	if (!kpd_any_key_down(hw)) {
+		kpd_print("stuck check: cleared by pad/block re-init\n");
+		/* the block has raised, or will raise, the release IRQ itself */
+		return;
+	}
+
+	tasklet_disable(&kpd_keymap_tasklet);
+	for (i = 0; i < KPD_NUM_MEMS; i++) {
+		for (j = 0; j < 16; j++) {
+			mask = 1U << j;
+			if (!(kpd_valid_mask[i] & mask) || (hw[i] & mask) || (kpd_keymap_state[i] & mask))
+				continue;
+			kpd_print("stuck check: forcing release of Linux keycode %u (hw %d), column still low\n",
+				  kpd_keymap[(i << 4) + j], (i << 4) + j);
+			kpd_aee_handler(kpd_keymap[(i << 4) + j], 0);
+			input_report_key(kpd_input_dev, kpd_keymap[(i << 4) + j], 0);
+			input_sync(kpd_input_dev);
+			kpd_forced_up[i] |= mask;
+			kpd_keymap_state[i] |= mask;
+		}
+	}
+	tasklet_enable(&kpd_keymap_tasklet);
+}
+
 /*********************************************************************/
 
 /*****************************************************************************************/
@@ -856,8 +991,10 @@
 			kpd_keymap[i] = 0;
 	}
 	for (i = 0; i < KPD_NUM_KEYS; i++) {
-		if (kpd_keymap[i] != 0)
+		if (kpd_keymap[i] != 0) {
 			__set_bit(kpd_keymap[i], kpd_input_dev->keybit);
+			kpd_valid_mask[i >> 4] |= 1U << (i & 15);
+		}
 	}
 
 #if KPD_AUTOTEST
@@ -937,9 +1074,25 @@
 	return 0;
 }
 
-/* should never be called */
 static int kpd_pdrv_remove(struct platform_device *pdev)
 {
+	/* E-151: the empty remove() made unbind a no-op and bind fail with EBUSY. */
+	cancel_delayed_work_sync(&kpd_stuck_work);
+	free_irq(kp_irqnr, NULL);
+	tasklet_kill(&kpd_keymap_tasklet);
+	hrtimer_cancel(&aee_timer);
+#if AEE_ENABLE_5_15
+	hrtimer_cancel(&aee_timer_5s);
+#endif
+	kpd_delete_attr(&kpd_pdrv.driver);
+	misc_deregister(&kpd_dev);
+	input_unregister_device(kpd_input_dev);
+	kpd_input_dev = NULL;
+	wake_lock_destroy(&kpd_suspend_lock);
+	iounmap(kp_base);
+	kp_base = NULL;
+	memset(kpd_forced_up, 0, sizeof(kpd_forced_up));
+	memset(kpd_valid_mask, 0, sizeof(kpd_valid_mask));
 	return 0;
 }
 
@@ -947,29 +1100,28 @@
 static int kpd_pdrv_suspend(struct platform_device *pdev, pm_message_t state)
 {
 	kpd_suspend = true;
-#ifdef MTK_KP_WAKESOURCE
-	if (call_status == 2) {
-		kpd_print("kpd_early_suspend wake up source enable!! (%d)\n", kpd_suspend);
-	} else {
-		kpd_wakeup_src_setting(0);
-		kpd_print("kpd_early_suspend wake up source disable!! (%d)\n", kpd_suspend);
-	}
-#endif
-	kpd_print("suspend!! (%d)\n", kpd_suspend);
+	/*
+	 * E-024/E-028: the block used to be disabled here unless call_status == 2.
+	 * The keypad IRQ is in the SPM wake mask, the volume keys are wanted as
+	 * wake sources, and an edge that arrives while KP_EN is 0 is lost for good
+	 * (edge-triggered IRQ, shadow never re-read).  Leave the block enabled
+	 * unconditionally; kpd_call_state is kept for compatibility only.
+	 */
+	kpd_print("suspend!! (%d) call_state=%lu, keypad left enabled\n", kpd_suspend, call_status);
 	return 0;
 }
 
 static int kpd_pdrv_resume(struct platform_device *pdev)
 {
+	u16 new_state[KPD_NUM_MEMS];
+
 	kpd_suspend = false;
-#ifdef MTK_KP_WAKESOURCE
-	if (call_status == 2) {
-		kpd_print("kpd_early_suspend wake up source enable!! (%d)\n", kpd_suspend);
-	} else {
-		kpd_print("kpd_early_suspend wake up source resume!! (%d)\n", kpd_suspend);
-		kpd_wakeup_src_setting(1);
-	}
-#endif
+	/* Bring the shadow back in step with whatever happened while we were down. */
+	tasklet_disable(&kpd_keymap_tasklet);
+	kpd_get_keymap_state(new_state);
+	kpd_report_changes(new_state);
+	kpd_arm_stuck_check();
+	tasklet_enable(&kpd_keymap_tasklet);
 	kpd_print("resume!! (%d)\n", kpd_suspend);
 	return 0;
 }
@@ -1056,6 +1208,7 @@
 
 module_param(kpd_show_hw_keycode, int, 0644);
 module_param(kpd_show_register, int, 0644);
+module_param(kpd_stuck_check_ms, uint, 0644);
 
 MODULE_AUTHOR("yucong.xiong <yucong.xiong@mediatek.com>");
 MODULE_DESCRIPTION("MTK Keypad (KPD) Driver v0.4");
diff -urN a/drivers/input/keyboard/mediatek/mt6755/hal_kpd.c b/drivers/input/keyboard/mediatek/mt6755/hal_kpd.c
--- a/drivers/input/keyboard/mediatek/mt6755/hal_kpd.c	2026-09-01 23:03:56.170855561 +0200
+++ b/drivers/input/keyboard/mediatek/mt6755/hal_kpd.c	2026-09-01 23:06:20.390670996 +0200
@@ -383,6 +383,101 @@
 }
 
 /********************************************************************/
+/*
+ * WI-080 diagnostics and recovery.  Legacy MTK GPIO API, exported by
+ * drivers/misc/mediatek/gpio/mt_gpio_core.c; pinctrl-mt6755.c routes its own
+ * writes through the same functions.  Values as in mt-plat/mt_gpio.h:
+ * GPIO_DIR_IN = 0, GPIO_PULL_ENABLE = 1, GPIO_PULL_UP = 1.
+ */
+extern int mt_set_gpio_mode(unsigned long pin, unsigned long mode);
+extern int mt_get_gpio_mode(unsigned long pin);
+extern int mt_set_gpio_dir(unsigned long pin, unsigned long dir);
+extern int mt_get_gpio_dir(unsigned long pin);
+extern int mt_set_gpio_pull_enable(unsigned long pin, unsigned long enable);
+extern int mt_get_gpio_pull_enable(unsigned long pin);
+extern int mt_set_gpio_pull_select(unsigned long pin, unsigned long select);
+extern int mt_get_gpio_pull_select(unsigned long pin);
+extern int mt_get_gpio_in(unsigned long pin);
+extern int mt_get_gpio_out(unsigned long pin);
+
+#define KPD_PAD_DIR_IN		0
+#define KPD_PAD_PULL_ENABLE	1
+#define KPD_PAD_PULL_UP		1
+
+static const unsigned long kpd_kcol_pins[] = { KPD_KCOL0_PIN, KPD_KCOL1_PIN };
+
+static int kpd_pad_snapshot(char *buf, size_t len, const char *name, unsigned long pin)
+{
+	return scnprintf(buf, len,
+			 "%s GPIO%lu: mode=%d dir=%d pullen=%d pullsel=%d din=%d dout=%d\n",
+			 name, pin, mt_get_gpio_mode(pin), mt_get_gpio_dir(pin),
+			 mt_get_gpio_pull_enable(pin), mt_get_gpio_pull_select(pin),
+			 mt_get_gpio_in(pin), mt_get_gpio_out(pin));
+}
+
+/* Registers of the block plus the three pads it uses.  Read-only. */
+int kpd_hw_snapshot(char *buf, size_t len)
+{
+	int n = 0;
+
+	n += scnprintf(buf + n, len - n,
+		       "KP_STA=%04x MEM=%04x %04x %04x %04x %04x DEBOUNCE=%04x SCAN_TIMING=%04x SEL=%04x EN=%04x\n",
+		       *(volatile u16 *)KP_STA, *(volatile u16 *)KP_MEM1, *(volatile u16 *)KP_MEM2,
+		       *(volatile u16 *)KP_MEM3, *(volatile u16 *)KP_MEM4, *(volatile u16 *)KP_MEM5,
+		       *(volatile u16 *)KP_DEBOUNCE, *(volatile u16 *)KP_SCAN_TIMING,
+		       *(volatile u16 *)KP_SEL, *(volatile u16 *)KP_EN);
+	n += kpd_pad_snapshot(buf + n, len - n, "KROW0", KPD_KROW0_PIN);
+	n += kpd_pad_snapshot(buf + n, len - n, "KCOL0", KPD_KCOL0_PIN);
+	n += kpd_pad_snapshot(buf + n, len - n, "KCOL1", KPD_KCOL1_PIN);
+	return n;
+}
+
+/* True when both column pads are still function-mode inputs with a pull-up. */
+bool kpd_kcol_pads_sane(void)
+{
+	bool ok = true;
+	int i;
+
+	for (i = 0; i < ARRAY_SIZE(kpd_kcol_pins); i++) {
+		unsigned long pin = kpd_kcol_pins[i];
+
+		if (mt_get_gpio_mode(pin) != KPD_PAD_FUNC_MODE ||
+		    mt_get_gpio_dir(pin) != KPD_PAD_DIR_IN ||
+		    mt_get_gpio_pull_enable(pin) != KPD_PAD_PULL_ENABLE ||
+		    mt_get_gpio_pull_select(pin) != KPD_PAD_PULL_UP) {
+			kpd_print("column pad GPIO%lu disturbed: mode=%d dir=%d pullen=%d pullsel=%d\n",
+				  pin, mt_get_gpio_mode(pin), mt_get_gpio_dir(pin),
+				  mt_get_gpio_pull_enable(pin), mt_get_gpio_pull_select(pin));
+			ok = false;
+		}
+	}
+	return ok;
+}
+
+void kpd_kcol_pads_reinit(void)
+{
+	int i;
+
+	for (i = 0; i < ARRAY_SIZE(kpd_kcol_pins); i++) {
+		unsigned long pin = kpd_kcol_pins[i];
+
+		mt_set_gpio_mode(pin, KPD_PAD_FUNC_MODE);
+		mt_set_gpio_dir(pin, KPD_PAD_DIR_IN);
+		mt_set_gpio_pull_select(pin, KPD_PAD_PULL_UP);
+		mt_set_gpio_pull_enable(pin, KPD_PAD_PULL_ENABLE);
+	}
+}
+
+/* Disable and re-enable the block; it re-scans and raises an IRQ for any change. */
+void kpd_hw_restart(u16 debounce)
+{
+	mt_reg_sync_writew(0, KP_EN);
+	udelay(100);
+	kpd_set_debounce(debounce);
+	mt_reg_sync_writew(1, KP_EN);
+}
+
+/********************************************************************/
 void kpd_pmic_rstkey_hal(unsigned long pressed)
 {
 	if (kpd_dts_data.kpd_sw_rstkey != 0) {
diff -urN a/drivers/input/keyboard/mediatek/mt6755/hal_kpd.h b/drivers/input/keyboard/mediatek/mt6755/hal_kpd.h
--- a/drivers/input/keyboard/mediatek/mt6755/hal_kpd.h	2026-09-01 23:03:56.171993815 +0200
+++ b/drivers/input/keyboard/mediatek/mt6755/hal_kpd.h	2026-09-01 23:06:20.390611113 +0200
@@ -62,4 +62,21 @@
 #define KPD_MEM5_BITS	8
 
 #define KPD_NUM_KEYS	72	/* 4 * 16 + KPD_MEM5_BITS */
+
+/*
+ * WI-080: pads of the keypad block on k50sv1_64_bsp
+ * (arch/arm64/boot/dts/mt6755-pinfunc.h:687,692,696).  Both volume keys are
+ * single-ended column switches (E-151 register dumps toggle a whole column),
+ * so a column reads "pressed" whenever its pad input is low: the pad must stay
+ * in function mode 1, input, pull-up.
+ */
+#define KPD_KROW0_PIN		102
+#define KPD_KCOL0_PIN		103
+#define KPD_KCOL1_PIN		104
+#define KPD_PAD_FUNC_MODE	1
+
+int kpd_hw_snapshot(char *buf, size_t len);
+bool kpd_kcol_pads_sane(void);
+void kpd_kcol_pads_reinit(void);
+void kpd_hw_restart(u16 debounce);
 #endif
diff -urN a/drivers/misc/mediatek/gpio/mt_gpio_core.c b/drivers/misc/mediatek/gpio/mt_gpio_core.c
--- a/drivers/misc/mediatek/gpio/mt_gpio_core.c	2026-09-01 23:03:56.172988518 +0200
+++ b/drivers/misc/mediatek/gpio/mt_gpio_core.c	2026-09-01 23:07:29.194638538 +0200
@@ -14,6 +14,7 @@
 #include <linux/init.h>
 #include <linux/module.h>
 #include <linux/kernel.h>
+#include <linux/sched.h>
 #include <generated/autoconf.h>
 #include <linux/platform_device.h>
 #include <linux/fs.h>
@@ -111,6 +112,30 @@
 };
 
 DEFINE_SPINLOCK(mt_gpio_lock);
+
+/*
+ * WI-080: the keypad pads (KROW0/KCOL0/KCOL1 = GPIO102/103/104 on k50sv1_64_bsp)
+ * are configured once by the bootloader and must never be touched again; a
+ * runtime write is the prime software suspect for "Volume Up column held low"
+ * (E-151).  Every legacy setter and, through pinctrl-mt6755.c's devdata hooks,
+ * every pinctrl write passes through MT_GPIO_OPS_SET, so this one hook sees
+ * them all.  It only logs; it changes nothing.
+ */
+static const unsigned long mt_gpio_guarded_pins[] = { 102, 103, 104 };
+
+static void mt_gpio_guard(unsigned long pin, const char *op, unsigned long arg)
+{
+	int i;
+
+	for (i = 0; i < ARRAY_SIZE(mt_gpio_guarded_pins); i++) {
+		if (pin != mt_gpio_guarded_pins[i])
+			continue;
+		pr_err("mt_gpio: GUARDED pin %lu: %s(%lu) by %s[%d]\n",
+		       pin, op, arg, current->comm, current->pid);
+		dump_stack();
+	}
+}
+
 struct mt_gpio_obj_t {
 	atomic_t ref;
 	dev_t devno;
@@ -137,6 +162,7 @@
 ({   unsigned long flags;\
 	u32 retval = 0;\
 	mt_gpio_pin_decrypt(&pin);\
+	mt_gpio_guard(pin, #operation, (unsigned long)(arg));\
 	spin_lock_irqsave(&mt_gpio_lock, flags);\
 	if (MT_BASE == MT_GPIO_PLACE(pin)) {\
 			if ((mt_gpio->base_ops == NULL) || (mt_gpio->base_ops->operation == NULL)) {\
```

## 6. Is `kpd_call_state=2` still needed once the source driver is fixed?

**No — after this patch it is inert.** Both PM hooks stop calling `kpd_wakeup_src_setting()`
altogether (KP_EN is never cleared; the SPM wake mask already carries `R12_KP_IRQ_B`, E-028), so
`call_status` is only echoed in the `suspend!!` log line. The sysfs attribute stays for
compatibility and the `init.mt6755.rc:270` write is harmless (`kpd_store_call_state`, `kpd.c:112-138`,
parses and logs). Recommended order: keep the write through the first patched image, re-run the
E-028 procedure (USB unplugged, network adb, `dmesg` showing `suspend!! (1) call_state=2, keypad
left enabled` and Volume Up waking the display), then drop the write and the two comments that
call it a stuck-key fix (`keylayout/mtk-kpd.kl:22-26`, `overlay/.../config.xml:90`). It was never
a mitigation for E-151: E-151 happened with it in place, and the E-151 mechanism (a column held
low) is independent of suspend.

## 7. What remains open

* The writer/holder of KCOL1 has not been observed. Sub-cause 1 (software) is fully
  instrumented by the patch; sub-cause 2 (electrical) would show as intact pad configuration with
  DIN=0 that `kpd_recover` cannot clear — that is a hardware/ODM finding, not a kernel one.
* Whether Volume Up is also wired to PMIC HOMEKEY (one healthy press with `dmesg` open settles it).
* The single IRQ at boot on today's uptime (consistent with the edge raised when the block is
  enabled at probe; `kpd_hw` will show `irq=` from now on).
