DEVICE_PATH := device/xsh/k50sv1_64_bsp
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
TARGET_USES_64_BIT_BINDER := true

# Platform
TARGET_BOARD_PLATFORM := mt6755
TARGET_BOOTLOADER_BOARD_NAME := k50sv1_64_bsp
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
#   build/make/core/board_config.mk:529-532  -> hard error if not in
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
DEVICE_MANIFEST_FILE := $(DEVICE_PATH)/manifest.xml
DEVICE_MATRIX_FILE := $(DEVICE_PATH)/compatibility_matrix.xml

# Kernel and boot image
# Read only by vendor/lineage/config/BoardConfigKernel.mk:48-52, which runs only
# when Lineage builds a kernel from source. This tree ships a prebuilt, so the
# value is inert today; it is kept for WI-019.
TARGET_KERNEL_ARCH := arm64
TARGET_PREBUILT_KERNEL := $(DEVICE_PATH)/prebuilt/kernel
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb

BOARD_KERNEL_BASE := 0x40000000
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2
ifeq ($(K50SV1_SELINUX_PERMISSIVE),true)
# Tier 1 keeps policy/domain transitions active while logging denials without
# blocking first boot. Tiers 2 and 3 omit the argument and enforce policy.
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive
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
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 16777216
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/rootdir/etc/fstab.mt6755

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
BOARD_BUILD_SYSTEM_ROOT_IMAGE := false
BOARD_AVB_ENABLE := false

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
    $(DEVICE_PATH)/sepolicy/safety

# Make a PRODUCT_PACKAGES entry that names a module the build cannot see a BUILD
# ERROR rather than silence.
#
# main.mk:1291-1304 already has the check; it is opt-in and nothing had opted in.
# Without it, a package listed in PRODUCT_PACKAGES whose Android.mk was never
# parsed simply does not install, the build reports success, and the first
# symptom is a missing feature on the handset. That is exactly what happened to
# the HarmonyOS Sans Styles overlay: its Android.mk sits two levels under the
# device root, and all-makefiles-under is one level deep
# (definitions.mk:179-181), so the module never existed and nobody was told.
PRODUCT_ENFORCE_PACKAGES_EXIST := true

# Turning it on found thirteen entries that had been missing from every build so
# far, silently. All thirteen come from LineageOS's own product makefiles and
# none is a defect in this port, so they are whitelisted rather than chased --
# but they are listed individually, because a whitelist that says "these are
# fine" without saying WHY is the next silent failure.
#
#   Browser2 Calendar Launcher3QuickStep LineageDarkTheme LockClock Music
#   MusicFX QuickSearchBox WeatherProvider powertop
#       Optional apps and tools whose repositories are not in this checkout.
#       Nothing depends on them; HOME resolves to com.android.launcher3 and the
#       GApps payload supplies the rest.
#
#   org.lineageos.platform.xml
#       Named by vendor/lineage/config/lineage_sdk_common.mk:15, but this
#       checkout's lineage-sdk ships it as a raw FILE with no module around it.
#       Harmless: the SDK is complete on the device anyway --
#       /system/framework/org.lineageos.platform.jar is installed, and the
#       permission XML arrives as org.lineageos.android.xml through
#       vendor/lineage/config/common.mk:76's PRODUCT_COPY_FILES.
#
#   product_manifest.xml
#       A product-partition VINTF fragment. This device declares everything in
#       the device manifest and has no /product/etc/vintf at all.
#
# The point of the flag is what it catches NEXT. If it fires on something new,
# fix the module; do not add it here.
PRODUCT_ENFORCE_PACKAGES_EXIST_WHITELIST := \
    Browser2 \
    Calendar \
    Launcher3QuickStep \
    LineageDarkTheme \
    LockClock \
    Music \
    MusicFX \
    QuickSearchBox \
    WeatherProvider \
    org.lineageos.platform.xml \
    powertop \
    product_manifest.xml

-include vendor/xsh/k50sv1_64_bsp/BoardConfigVendor.mk
