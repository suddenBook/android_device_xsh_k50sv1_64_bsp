# 64-bit primary userspace with a 32-bit compatibility runtime.
include device/xsh/k50sv1_64_bsp/build_tiers.mk

ifeq ($(K50SV1_ADB_INSECURE),true)
WITH_ADB_INSECURE := true
else
WITH_ADB_INSECURE :=
endif

# Product copy rules keep the first source for a duplicate destination. Add
# the verified no-compass handheld contract and empty no-NFC Beam contract
# before inherited common products contribute their generic versions.
PRODUCT_COPY_FILES += \
    device/xsh/k50sv1_64_bsp/permissions/handheld_core_hardware.xml:vendor/etc/permissions/handheld_core_hardware.xml \
    device/xsh/k50sv1_64_bsp/permissions/android.software.nfc.beam.xml:system/etc/permissions/android.software.nfc.beam.xml

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# Android Go. The SoC is an 8x Cortex-A53 at 1.5 GHz with a Mali-T860 MP2 and
# an eMMC that tops out around 150 MB/s; 3.74 GiB of usable RAM is the one
# resource this device is not short of. Inheriting AOSP's canonical Go product
# defaults (ro.config.low_ram, speed-profile system server, profile-guided boot
# image, always-preopt extracted APKs, in-process network stack, minimized Java
# debug info) buys back CPU and storage. See the two deliberate deviations
# below.
$(call inherit-product, $(SRC_TARGET_DIR)/product/go_defaults_common.mk)

# Deviation 1: heap. go_defaults_common.prop sizes the Dalvik heap for a 1 GiB
# handset (128m/256m). AOSP's own per-RAM profile for this device is the 4096
# one, whose 0.6 target utilization and larger free window also mean fewer GC
# pauses, which is what a weak CPU needs. PRODUCT_PROPERTY_OVERRIDES lands in
# vendor/build.prop, which init loads after system/build.prop, so these values
# are the ones that take effect.
#
# Deviation 2: MALLOC_SVELTE is deliberately NOT set. It trades CPU for RAM,
# which is the wrong direction here.
$(call inherit-product, frameworks/native/build/phone-xhdpi-4096-dalvik-heap.mk)

# Build the full phone userspace without AOSP's generic vendor rild. The MTK
# radio stack supplies mtkrild and rilproxy, so installing a second rild would
# create a competing init service for the same modem contract.
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_o.mk)
$(call inherit-product, device/xsh/k50sv1_64_bsp/device.mk)

# Select LineageOS's partner-GMS Go path. The explicit guard prevents its
# optional product inherit from silently producing a GMS-free image.
WITH_GMS := true
WITH_GMS_GO := true
ifeq ($(wildcard vendor/partner_gms/products/gms_go.mk),)
$(error Missing vendor/partner_gms/products/gms_go.mk; import the pinned NikGapps Go payload first)
endif
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_PROPERTY_OVERRIDES += \
    keyguard.no_require_sim=true

# The 3.18 kernel has neither CONFIG_MEMCG nor PSI, so per-app memory cgroups
# do not exist and lmkd cannot run its userspace/PSI killer. lmkd auto-detects
# /sys/module/lowmemorykiller and drives the in-kernel driver instead, taking
# its thresholds from ActivityManager. ro.config.low_ram itself comes from
# go_defaults_common.mk.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.config.per_app_memcg=false

# Stock's boot contract requires the legacy Android BootSignature. Tiers 1 and
# 2 use the AOSP verity test key; Tier 3's final images use the committed verity
# key. This does not enable dm-verity or AVB for system/vendor.
PRODUCT_SUPPORTS_BOOT_SIGNER := true
ifeq ($(K50SV1_RELEASE_SIGNING),true)
# Keep the target-files input on AOSP's normal test-key layout. The Tier 3
# wrapper performs the canonical post-build mapping to the committed release
# key set, with explicit overrides for both APEX container and payload keys.
PRODUCT_OTA_PUBLIC_KEYS := build/make/target/product/security/testkey.x509.pem
# The default certificate is already accepted by recovery; clear Lineage's
# inherited extra key so the final recovery trusts only the remapped key.
PRODUCT_EXTRA_RECOVERY_KEYS :=
PRODUCT_VERITY_SIGNING_KEY := device/xsh/k50sv1_64_bsp/security/verity
else
PRODUCT_VERITY_SIGNING_KEY := build/make/target/product/security/verity
endif

PRODUCT_NAME := lineage_k50sv1_64_bsp
PRODUCT_DEVICE := k50sv1_64_bsp
PRODUCT_BRAND := XSH
PRODUCT_MODEL := F212
PRODUCT_MANUFACTURER := XSH
