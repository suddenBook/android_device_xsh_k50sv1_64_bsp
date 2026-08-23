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
TARGET_NO_RADIOIMAGE := true
VENDOR_SECURITY_PATCH := 2020-08-05

# Verified LCD geometry. Lineage uses these values to select the correctly
# sized boot animation; logical density remains configured by the overlay.
TARGET_SCREEN_WIDTH := 720
TARGET_SCREEN_HEIGHT := 1560

# Proprietary vendor compatibility contract
BOARD_VNDK_VERSION := current
BOARD_SYSTEMSDK_VERSIONS := 28
DEVICE_MANIFEST_FILE := $(DEVICE_PATH)/manifest.xml
DEVICE_MATRIX_FILE := $(DEVICE_PATH)/compatibility_matrix.xml

# Kernel and boot image
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
# sepolicy/private holds only rules whose subject and object are both core
# types (init, system_app) -- board facts never belong there.
BOARD_PLAT_PRIVATE_SEPOLICY_DIR += \
    $(DEVICE_PATH)/sepolicy/private

BOARD_VENDOR_SEPOLICY_DIRS += \
    $(DEVICE_PATH)/sepolicy/connectivity \
    $(DEVICE_PATH)/sepolicy/gnss \
    $(DEVICE_PATH)/sepolicy/media \
    $(DEVICE_PATH)/sepolicy/nvram/vendor \
    $(DEVICE_PATH)/sepolicy/power \
    $(DEVICE_PATH)/sepolicy/radio \
    $(DEVICE_PATH)/sepolicy/vendor \
    $(DEVICE_PATH)/sepolicy/safety

-include vendor/xsh/k50sv1_64_bsp/BoardConfigVendor.mk
