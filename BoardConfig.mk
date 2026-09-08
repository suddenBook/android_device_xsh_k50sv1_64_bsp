# board_config.mk derives this path before including BoardConfig.mk. Product
# makefiles are parsed earlier and must calculate their own paths.
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
TARGET_USES_64_BIT_BINDER := true

# Platform and verified 720x1560 LCD geometry
TARGET_BOARD_PLATFORM := mt6755
TARGET_BOOTLOADER_BOARD_NAME := k50sv1_64_bsp
TARGET_OTA_ASSERT_DEVICE := k50sv1_64_bsp
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true
VENDOR_SECURITY_PATCH := 2020-08-05

TARGET_SCREEN_WIDTH := 720
TARGET_SCREEN_HEIGHT := 1560
TARGET_SCREEN_DENSITY := 320

# Legacy vendor contract: VNDK 29, system SDK 28, shipping API 26. Raising the
# shipping API also changes property-trigger enforcement; review vendor init first.
BOARD_VNDK_VERSION := current
BOARD_SYSTEMSDK_VERSIONS := 28
# Fix the vendor Power HAL's scalar HICA initialization through its exported ABI.
TARGET_LD_SHIM_LIBS += /vendor/lib64/libpowerhal.so|libpowerhal-k50sv1-shim.so
# Do not add a framework compatibility matrix solely for private MTK HALs:
# Q would enforce that every manifest entry has a corresponding matrix entry.
DEVICE_MANIFEST_FILE := $(DEVICE_PATH)/manifest.xml
DEVICE_MATRIX_FILE := $(DEVICE_PATH)/compatibility_matrix.xml

# Build the kernel and modules together with GCC 4.9. Only the stock DT table
# and recovery DTBO are used in boot images; the stored stock kernel is a reference.
TARGET_KERNEL_ARCH := arm64
TARGET_KERNEL_SOURCE := kernel/xsh/k50sv1_64_bsp
TARGET_KERNEL_CONFIG := k50sv1_64_bsp_stock_defconfig
TARGET_KERNEL_ADDITIONAL_CONFIG := k50sv1_64_bsp_source.fragment
TARGET_KERNEL_CLANG_COMPILE := false
# MTK DCT needs Python 2. Use pinned lexer/parser tools under Soong's restricted PATH.
K50_DCT_PYTHON := $(abspath prebuilts/python/linux-x86/2.7.5/bin/python2.7)
TARGET_KERNEL_ADDITIONAL_FLAGS := LOCALVERSION= KBUILD_SYMTYPES=1 \
    python=$(K50_DCT_PYTHON) \
    HOSTLEX=$(abspath prebuilts/build-tools/linux-x86/bin/flex) \
    HOSTYACC=$(abspath prebuilts/build-tools/linux-x86/bin/bison) \
    BISON_PKGDATADIR=$(abspath prebuilts/build-tools/common/bison)
BOARD_KERNEL_IMAGE_NAME := Image.gz
BOARD_INCLUDE_DTB_IN_BOOTIMG := true
BOARD_PREBUILT_DTBIMAGE_DIR := $(DEVICE_PATH)/prebuilt/dtb

BOARD_KERNEL_BASE := 0x40000000
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_CMDLINE := bootopt=64S3,32N2,64N2

# Tier 1 keeps policy transitions active and records denials without blocking.
ifeq ($(K50SV1_SELINUX_PERMISSIVE),true)
BOARD_KERNEL_CMDLINE += androidboot.selinux=permissive
endif

# A larger diagnostic ring retains early boot messages. LK's slub_debug option
# is inert with CONFIG_SLUB_DEBUG unset; an override would have no effect.
ifneq ($(K50SV1_BUILD_TIER),3)
BOARD_KERNEL_CMDLINE += log_buf_len=1M
endif
BOARD_MKBOOTIMG_ARGS += \
    --header_version 2 \
    --kernel_offset 0x00080000 \
    --ramdisk_offset 0x05000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x04000000 \
    --dtb_offset 0x04000000

BOARD_USES_RECOVERY_AS_BOOT := false
BOARD_INCLUDE_RECOVERY_DTBO := true
BOARD_PREBUILT_RECOVERY_DTBOIMAGE := $(DEVICE_PATH)/prebuilt/recovery_dtbo
BOARD_RECOVERYIMAGE_PARTITION_SIZE := 16777216
# Recovery and Android share the F2FS userdata contract.
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/rootdir/etc/fstab.mt6755

# Full recovery avoids Q's inconsistent bsdiff/imgdiff choice for recovery DTBO.
# Leave TARGET_RECOVERY_UI_SCREEN_WIDTH unset: all-locale graphics exceed the
# 16 MiB recovery partition. The built-in text menu remains usable.
BOARD_USES_FULL_RECOVERY_IMAGE := true

# Measured fb0 channel offsets are R=0, G=8, B=16. This also applies to charger UI.
TARGET_RECOVERY_PIXEL_FORMAT := "RGBX_8888"

# Physical A-only GPT limits. Check expanded sparse-image sizes before flashing.
BOARD_BOOTIMAGE_PARTITION_SIZE := 16777216
BOARD_SYSTEMIMAGE_PARTITION_SIZE := 4294967296
BOARD_VENDORIMAGE_PARTITION_SIZE := 2147483648
BOARD_CACHEIMAGE_PARTITION_SIZE := 452984832
BOARD_USERDATAIMAGE_PARTITION_SIZE := 55373184512
BOARD_FLASH_BLOCK_SIZE := 131072

# Filesystems
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_COPY_OUT_VENDOR := vendor
BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_CACHEIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs

# Q requires XML audio policy; the device policy filters absent hardware.
USE_XML_AUDIO_POLICY_CONF := 1

# Permit healthd charger mode to call libsuspend.
BOARD_CHARGER_ENABLE_SUSPEND := true

# No AVB/dm-verity. Empty disables Make's non-empty conditionals as well as
# strict boolean consumers. Keep system_root_image=false for its build property.
BOARD_AVB_ENABLE :=
BOARD_BUILD_SYSTEM_ROOT_IMAGE := false

# Core-platform rules and binder service labels live in private policy. Device
# HAL attributes stay in vendor policy; keep their declarations first.
BOARD_PLAT_PRIVATE_SEPOLICY_DIR += \
    $(DEVICE_PATH)/sepolicy/private

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
