# board_config.mk:130-131 computes TARGET_DEVICE_DIR from the path of the very
# BoardConfig.mk it is about to include on :133, and marks it .KATI_READONLY, so
# it is both already correct here and incapable of drifting from this file's
# real location. A hardcoded literal could.
#
# This only works below the board-config layer. envsetup.mk includes
# product_config.mk (:268) BEFORE board_config.mk (:279), so TARGET_DEVICE_DIR
# does not exist yet while device.mk and lineage_k50sv1_64_bsp.mk are being
# parsed; those two keep their own path expressions.
DEVICE_PATH := $(TARGET_DEVICE_DIR)
include $(DEVICE_PATH)/build_tiers.mk

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_VARIANT := cortex-a53
TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := cortex-a53
# INERT on this device, kept as a statement of fact -- the same treatment
# TARGET_NO_RADIOIMAGE and TARGET_KERNEL_ARCH get below and above. Both
# consumers are unreachable once TARGET_IS_64_BIT is true, which TARGET_ARCH :=
# arm64 makes it: soong_config.mk:9-14 only sets BINDER32BIT when the target is
# NOT 64-bit, and config.mk:751-757's error only fires for a 32-bit target at
# PRODUCT_SHIPPING_API_LEVEL >= 28 (this product is at 26 for the reason
# recorded further down).
TARGET_USES_64_BIT_BINDER := true

# Platform
TARGET_BOARD_PLATFORM := mt6755
TARGET_BOOTLOADER_BOARD_NAME := k50sv1_64_bsp
# ro.product.device is intentionally presented to apps as coral. OTA/recovery
# compatibility must remain tied to this handset; ro.build.product also stays
# k50sv1_64_bsp, so the updater accepts this device and not a genuine Pixel.
TARGET_OTA_ASSERT_DEVICE := k50sv1_64_bsp
TARGET_NO_BOOTLOADER := true
# Inert in Android 10, kept as a statement of fact rather than a working flag.
# Its single occurrence in the build system is membership in
# board_config.mk's _board_strip_readonly_list, which only strips and marks it
# read-only; nothing consumes it. INSTALLED_RADIOIMAGE_TARGET is populated
# exclusively by definitions.mk's add-radio-file macros, which this tree never
# calls. Contrast TARGET_NO_BOOTLOADER on the next line, which IS live.
TARGET_NO_RADIOIMAGE := true
VENDOR_SECURITY_PATCH := 2020-08-05

# Verified LCD geometry. Lineage uses width/height to select the correctly
# sized boot animation (vendor/lineage/bootanimation/Android.mk:18-37);
# TARGET_SCREEN_DENSITY is what build/make/core/Makefile:517-519 turns into
# ro.sf.lcd_density in /vendor/build.prop. Setting the property by hand in
# device.mk worked only while this variable was unset -- with both, the vendor
# copy wins (property_service.cpp:727-734) and the two would fight silently.
# Logical density for the UI remains the overlay's business.
TARGET_SCREEN_WIDTH := 720
TARGET_SCREEN_HEIGHT := 1560
TARGET_SCREEN_DENSITY := 320

# Proprietary vendor compatibility contract
BOARD_VNDK_VERSION := current
# The System SDK level this device REQUIRES OF THE FRAMEWORK, and the level
# Soong lets vendor Java compile against. Not inert -- five consumers:
#   build/make/core/soong_config.mk:115      -> Soong DeviceSystemSdkVersions
#   build/make/core/local_systemsdk.mk:17,45 -> restricts vendor Java targets
#   build/make/core/board_config.mk:530-532  -> hard error if not in
#                                               PLATFORM_SYSTEMSDK_VERSIONS
#   build/make/core/config.mk:748-749        -> hard error if < PRODUCT_SHIPPING_API_LEVEL
#   system/libhidl/vintfdata/Android.mk:56   -> injected into the shipped
#                                               <system-sdk> of the vendor matrix
# compatibility_matrix.xml deliberately does NOT restate it -- assemble_vintf
# injects it from here, and a hardcoded copy would be merged as a UNION with no
# diagnostic, so this file is the single source. It does not have to match
# VNDK (29) or
# PRODUCT_SHIPPING_API_LEVEL (26, from product_launched_with_o.mk); it only has
# to be >= the latter and present in PLATFORM_SYSTEMSDK_VERSIONS.
BOARD_SYSTEMSDK_VERSIONS := 28
# PRODUCT_SHIPPING_API_LEVEL = 26 has a second, load-bearing consequence that is
# invisible here and would only surface as a boot-time init parse failure.
# config.mk:645-651 leaves PRODUCT_COMPATIBLE_PROPERTY false for any level <= 27
# (the gate is `math_lt,27,LEVEL`, so true only from 28 up), main.mk:232-236 then
# ships ro.actionable_compatible_property.enabled=false, and action_parser.cpp:
# 36-40 returns early from IsActionableProperty() whenever that is false --
# skipping the partner-prefix check that would otherwise reject a vendor
# `on property:` trigger with "unexported property trigger found".
#
# Two citations here were wrong and are corrected:
#   * main.mk. The literal `...enabled=false` is main.mk:233, but that is the
#     PRODUCT_ACTIONABLE_COMPATIBLE_PROPERTY_DISABLE branch, which this product
#     does not set. The line actually taken is main.mk:235,
#     `+= ro.actionable_compatible_property.enabled=${PRODUCT_COMPATIBLE_PROPERTY}`,
#     which expands to false for the reason above. Same outcome, different line;
#     anyone who went to :233 to change this would have edited a dead branch.
#   * kPartnerPrefixes is action_parser.cpp:43-47, not :45-48 (:49-53 is the
#     loop over it), and it has NINE entries, not the six listed before:
#       init.svc.vendor.  ro.vendor.  persist.vendor.  vendor.
#       init.svc.odm.     ro.odm.     persist.odm.     odm.     ro.boot.
#
# Four triggers in this tree's own rc files depend on that relaxation:
# ro.persistent_properties.ready, sys.boot_completed, sys.usb.config and
# vold.decrypt. None of the four is under ANY of those nine prefixes, so the
# conclusion is unchanged -- but it now rests on the whole list.
# Raising the shipping API level therefore requires re-homing those triggers or
# granting the property types first. Do not raise it as a cosmetic change.
DEVICE_MANIFEST_FILE := $(DEVICE_PATH)/manifest.xml
DEVICE_MATRIX_FILE := $(DEVICE_PATH)/compatibility_matrix.xml
# Do NOT add DEVICE_FRAMEWORK_COMPATIBILITY_MATRIX_FILE -- or
# DEVICE_PRODUCT_COMPATIBILITY_MATRIX_FILE, which trips the identical check:
# Makefile:2719-2723 tests the two together in one $(strip ...). Setting either
# is what turns on assemble_vintf's VINTF_ENFORCE_NO_UNUSED_HALS check, in the
# manifest->matrix direction, for the WHOLE device manifest. This tree declares
# 14 vendor.mediatek.* HALs that no compatibility matrix in
# hardware/interfaces/compatibility_matrices/ mentions, which is normal and
# correct for vendor-private interfaces -- and every one of them would fail that
# check at once. The other direction (matrix->manifest) already runs on every
# build and passes; PRODUCT_ENFORCE_VINTF_MANIFEST is true here, derived from
# PRODUCT_SHIPPING_API_LEVEL=26 (config.mk:658-665, :673-682).

# Kernel and boot image
# Read only by vendor/lineage/config/BoardConfigKernel.mk:48-52. The previous
# comment said that file "runs only when Lineage builds a kernel from source"
# and that the value is therefore inert. Both halves are wrong.
#
# BoardConfigKernel.mk is included unconditionally for this product:
#   build/make/core/config.mk:237-239   ifneq ($(LINEAGE_BUILD),) ->
#                                       include BoardConfigLineage.mk
#   BoardConfigLineage.mk:6             include BoardConfigKernel.mk
# LINEAGE_BUILD is set and exported by check_product() (build/make/envsetup.sh:
# 145-150) for any TARGET_PRODUCT beginning `lineage_`, which this one does, so
# the guard is always satisfied here. TARGET_PREBUILT_KERNEL only blanks
# TARGET_KERNEL_SOURCE (BoardConfigKernel.mk:44-46); it does not skip :48-52.
#
# What :48-52 actually does:
#   TARGET_KERNEL_ARCH := $(strip $(TARGET_KERNEL_ARCH))
#   ifeq ($(TARGET_KERNEL_ARCH),)
#   KERNEL_ARCH := $(TARGET_ARCH)      <- arm64 anyway, from line 5 of this file
#   else
#   KERNEL_ARCH := $(TARGET_KERNEL_ARCH)
#   endif
# So the line runs on every build and computes the same KERNEL_ARCH=arm64 that
# unsetting it would. It is REDUNDANT WITH TARGET_ARCH, not inert -- a real
# difference, because "inert" invites setting it to any value, and a wrong
# value here would silently pick a different KERNEL_TOOLCHAIN
# (BoardConfigKernel.mk:71-72,83) and a different dtbo path (:136), and is
# exported to Soong via BoardConfigSoong.mk:5. Kept for WI-019 as an explicit
# statement; it must keep matching TARGET_ARCH.
TARGET_KERNEL_ARCH := arm64
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/kernel
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb

BOARD_KERNEL_BASE := 0x40000000
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2

# Turn MediaTek's SLUB debugging back off.
#
# This is NOT ours to begin with: LK prepends its own arguments, and the live
# /proc/cmdline carries `slub_max_order=0 slub_debug=OFZPU` from there, ahead of
# everything this file contributes. OFZPU is F(sanity checks) + Z(red zones) +
# P(poisoning) + U(store-user, i.e. an allocation stack trace kept per object),
# with O meaning "skip caches whose minimum order would grow". That is a
# permanent tax on every kmalloc and kfree, plus per-object memory, on eight
# A53s and 4 GiB.
#
# We cannot edit LK's string -- lk is not in this project's flash set -- but we
# do not have to. The boot image's cmdline is appended AFTER it (confirmed on
# the handset: LK's arguments, then this file's `bootopt=`, then more LK
# arguments), mm/slub.c registers setup_slub_debug() with __setup, and
# obsolete_checksetup() runs the handler once per matching occurrence in
# left-to-right order. The handler's first act on "-" is `slub_debug = 0`. So
# the later assignment wins.
#
# Ordering is safe with respect to the caches: parse_args() runs before
# mm_init() in start_kernel(), so no SLUB cache exists yet when this is read.
# `disable_higher_order_debug` stays 1 from the earlier parse and is inert once
# slub_debug is 0.
#
# VERIFY AFTER FLASHING, because this is an argument-ordering claim about a
# bootloader we do not build:
#     grep -c 'red_zone' /sys/kernel/slab/*/red_zone   # expect all 0
#     cat /sys/kernel/slab/kmalloc-256/store_user      # expect 0
# If they still read 1, the appended argument is not reaching the parser and
# this line should come out rather than stay as decoration.
BOARD_KERNEL_CMDLINE += slub_debug=-

ifeq ($(K50SV1_SELINUX_PERMISSIVE),true)
# Tier 1 keeps policy/domain transitions active while logging denials without
# blocking first boot. Tiers 2 and 3 omit the argument and enforce policy.
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive
endif

ifneq ($(K50SV1_BUILD_TIER),3)
# Diagnostic tiers only. The kernel ring is CONFIG_LOG_BUF_SHIFT-sized and this
# kernel writes ~5.5 lines a second at idle, so `dmesg` on a long-running
# handset covers roughly the last quarter-hour: every boot-time message, and
# every init service-exit diagnostic (init logs to kmsg, not to logcat), is
# already gone by the time anyone looks. 1 MiB is free on a 4 GiB device and
# turns a post-hoc dmesg into evidence instead of a sample. Tier 3 keeps the
# kernel default.
BOARD_KERNEL_CMDLINE += log_buf_len=1M
endif
BOARD_MKBOOTIMG_ARGS += \
    --header_version 2 \
    --kernel_offset 0x00080000 \
    --ramdisk_offset 0x05000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x04000000 \
    --dtb_offset 0x04000000

# prebuilt/dtb contains one file: the exact Stock Android DT table container.
# Q concatenates that single input to PRODUCT_OUT/dtb.img and supplies --dtb.

# Recovery
BOARD_USES_RECOVERY_AS_BOOT := false
BOARD_INCLUDE_RECOVERY_DTBO := true
BOARD_PREBUILT_RECOVERY_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/recovery_dtbo
# 16 MiB, matching the GPT. HEADROOM IS 11%: the produced recovery.img is
# 14,970,156 bytes of the 16,777,216 available, with a 6,997,375-byte ramdisk.
# Makefile's assert-max-image-size is a hard error, so anything that grows the
# recovery ramdisk much -- a larger locale set, a font, an extra binary -- fails
# the build rather than degrading. Check `ls -l $(PRODUCT_OUT)/recovery.img`
# before adding to it.
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 16777216
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/rootdir/etc/fstab.mt6755

# MEASURED, not guessed. Makefile:188-191 turns this into ro.minui.pixel_format
# in /vendor/default.prop, which Makefile:1851 concatenates into the recovery
# ramdisk's /prop.default; minui/graphics.cpp:350-360 accepts only ABGR_8888,
# RGBX_8888 and BGRA_8888 and leaves PixelFormat::UNKNOWN for anything else,
# including unset. resources.cpp:201-320 then skips the channel swap when
# decoding PNGs, so every recovery graphic renders with red and blue exchanged.
# Neither this tree nor stock's recovery ramdisk set it.
#
# The value is per-device and cannot be inferred from the SoC -- MT6763 trees
# in the wild use both RGBX_8888 and BGRA_8888. So it was read off this
# handset's own recovery, booted on the running image
# (minui/graphics_fbdev.cpp:87-94 prints it into /tmp/recovery.log):
#
#     fb0 reports (possibly inaccurate):
#       vi.bits_per_pixel = 32
#       vi.red.offset   =   0   .length =   8
#       vi.green.offset =   8   .length =   8
#       vi.blue.offset  =  16   .length =   8
#
# red at bit 0 is red in the FIRST byte, i.e. R,G,B,X in memory -> RGBX_8888.
#
# It is not recovery-only. AOSP's own comment at Makefile:183 says these
# variables are "also needed under charger mode (via libminui)", which matters
# here because BOARD_CHARGER_ENABLE_SUSPEND is set below.
#
# If recovery ever comes up BLACK rather than mis-coloured, this is the wrong
# knob and TARGET_RECOVERY_UI_BLANK_UNBLANK_ON_INIT is the right one -- a
# LineageOS-only variable (core/Makefile:1813 ->
# ro.recovery.ui.blank_unblank_on_init, read at recovery_ui/screen_ui.cpp:381)
# that the official LineageOS 17.1 MediaTek tree sets. Recovery renders
# correctly today, so it is not set.
TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888"

# Physical A-only GPT layout
BOARD_BOOTIMAGE_PARTITION_SIZE := 16777216
BOARD_SYSTEMIMAGE_PARTITION_SIZE := 4294967296
BOARD_VENDORIMAGE_PARTITION_SIZE := 2147483648
BOARD_CACHEIMAGE_PARTITION_SIZE := 452984832
BOARD_USERDATAIMAGE_PARTITION_SIZE := 55373184512
BOARD_FLASH_BLOCK_SIZE := 131072

# Filesystems
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_COPY_OUT_VENDOR := vendor
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := ext4

# Android Q requires the XML audio policy format. The device supplies a
# physical-hardware-filtered audio_policy_configuration.xml.
USE_XML_AUDIO_POLICY_CONF := 1

# Off-mode charging must be allowed to suspend, or the SoC stays awake for the
# entire charge. init.mt6755.rc's charger block states that as the acceptance
# criterion, and it could not happen: system/core/healthd/Android.mk:38-39,67-68
# gate both -DCHARGER_ENABLE_SUSPEND and the libsuspend link on this variable,
# and without it healthd_mode_charger.cpp:274-276 compiles a no-op
# request_suspend() stub, so all seven call sites do nothing. AOSP's own
# BoardConfigMainlineCommon.mk:37 sets it true; this tree simply never did.
# No sepolicy needed: both /sys/power/state and /sys/power/wakeup_count are
# sysfs_power (private/genfs_contexts:135-136) and public/charger.te already has
# allow charger sysfs_power:file rw_file_perms.
BOARD_CHARGER_ENABLE_SUSPEND := true

# Android Q first-stage ramdisk + switch-root. Stock system/vendor mounts do
# not use AVB or dm-verity, despite those capabilities existing in the kernel.
#
# These two variables express the same intent and DO NOT behave the same way,
# which is why one of them is now empty and the other is not. Both were `false`;
# neither was the no-op that reads like.
#
# BOARD_AVB_ENABLE: the image-prop-dictionary generator tests it with
# $(if $(BOARD_AVB_ENABLE),...) -- Makefile:1489-1531, nineteen consecutive
# lines -- and $(if) is true for ANY non-empty value, `false` included. With it
# set to the string `false` the build emitted, into every per-image prop
# dictionary:
#     avb_avbtool=avbtool
#     avb_{system,system_other,vendor,product,product_services,odm}_hashtree_enable=false
#     avb_*_add_hashtree_footer_args=            (six empty keys)
# i.e. one tool path and six =false switches, where unset emits nothing at all.
# (The audit that found this said five hashtree keys; it is six -- system,
# system_other, vendor, product, product_services, odm.)
#
# Harmless today only because every consumer compares against the literal
# string "true": build_image.py:541,571,602,623,644,667 copy_prop into
# avb_hashtree_enable, add_img_to_target_files.py:343 and :592-594 both test
# `== "true"`. But "harmless because the reader happens to be strict" is not a
# reason to ship a switch that says the opposite of what it means, and this is
# the same class as HANDOFF trap 5 (LOCAL_ENFORCE_USES_LIBRARIES := false
# ENABLES enforcement). Empty is the only value that means "off" to $(if).
# The other AVB call sites -- Makefile:64, :738, :999, :1343, :1963, :1976,
# :3036, :3061, :4056, :4150 -- all use `ifeq (true,...)` or `filter true`, so
# they were and remain correctly off either way.
BOARD_AVB_ENABLE :=
#
# BOARD_BUILD_SYSTEM_ROOT_IMAGE: same trap shape, OPPOSITE conclusion, so it
# deliberately keeps the `false`. Every make-side consumer is
# `ifeq ($(...),true)` or `$(filter true,...)` -- board_config.mk:235,
# Makefile:956, :971, :1071, :1534, :1801, :1918, :2365, :3245 -- so `false`
# and unset are identical there, and the releasetools info-dict key
# system_root_image (Makefile:1534) is correctly NOT emitted.
#
# The one asymmetric reader is buildinfo.sh:25-27, which uses a shell
# `[ -n "$BOARD_BUILD_SYSTEM_ROOT_IMAGE" ]` and therefore ships
# ro.build.system_root_image=false into /system/build.prop where unset would
# omit the property entirely. That is a real difference -- and it is the one
# stock makes: stock's /system/build.prop:39 is literally
# ro.build.system_root_image=false, and stock's runtime getprop agrees. This
# build's handset reads back `false` too, so we are already at parity.
# Blanking it would silently drop a property stock ships and that recovery /
# root tooling reads. Kept as `false` on purpose; recorded here so nobody
# "fixes" it by symmetry with BOARD_AVB_ENABLE above.
BOARD_BUILD_SYSTEM_ROOT_IMAGE := false

# SELinux
#
# No BOARD_PLAT_PUBLIC_SEPOLICY_DIR: every device-specific HAL attribute is
# declared in the BOARD_VENDOR_SEPOLICY_DIRS entry that uses it. A plat_public
# declaration is emitted into /system/etc/selinux/plat_sepolicy.cil and, because
# version_policy only versions the frozen 29.0 API set, un-versioned into
# /vendor/etc/selinux/plat_pub_versioned.cil -- so a platform-only OTA or a GSI
# would drop the symbol and vendor_sepolicy.cil would fail to link at boot.
#
# sepolicy/private holds a rule only when BOTH of these are true:
#   (a) subject and object are core platform types, and
#   (b) the rule fixes an AOSP gap that would exist on a board with none of
#       this hardware -- it is not caused by a board fact.
# init x tmpfs:lnk_file (AOSP's own init.rc symlink), system_app x sysfs_zram
# (Settings' storage page) and ueventd's sys_nice all qualify. Anything that
# exists because of this device's fstab, its rc files or its .ko files stays in
# the vendor dirs even when both types happen to be core -- e.g.
# vendor_init x vold_prop, which is only needed because init.mt6755.rc does the
# setprop, and init x mnt_vendor_file, which is only needed because this fstab
# mounts /mnt/vendor. The one forced exception is service_contexts: Android Q
# has no vendor service_contexts for /dev/binder services (only
# vndservice_contexts), so a binder service label such as mtkIms must live in
# plat_private regardless of who registers it.
BOARD_PLAT_PRIVATE_SEPOLICY_DIR += \
    $(DEVICE_PATH)/sepolicy/private

# sepolicy/attributes MUST stay first: it declares every device attribute, and
# the types that join mtk_nvram_storage_file do so from their own `type`
# statement in connectivity/, nvram/vendor/ and radio/, which requires the
# attribute to already exist. Nothing else in this list is order-sensitive.
BOARD_VENDOR_SEPOLICY_DIRS += \
    $(DEVICE_PATH)/sepolicy/attributes \
    $(DEVICE_PATH)/sepolicy/connectivity \
    $(DEVICE_PATH)/sepolicy/drm \
    $(DEVICE_PATH)/sepolicy/gnss \
    $(DEVICE_PATH)/sepolicy/media \
    $(DEVICE_PATH)/sepolicy/nvram/vendor \
    $(DEVICE_PATH)/sepolicy/power \
    $(DEVICE_PATH)/sepolicy/radio \
    $(DEVICE_PATH)/sepolicy/vendor \
    $(DEVICE_PATH)/sepolicy/vowifi \
    $(DEVICE_PATH)/sepolicy/safety

-include vendor/xsh/k50sv1_64_bsp/BoardConfigVendor.mk
