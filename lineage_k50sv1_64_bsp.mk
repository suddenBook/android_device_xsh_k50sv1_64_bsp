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

# Build the full phone userspace without AOSP's generic vendor rild. The MTK
# radio stack supplies mtkrild and rilproxy, so installing a second rild would
# create a competing init service for the same modem contract.
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_o.mk)
$(call inherit-product, device/xsh/k50sv1_64_bsp/device.mk)
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_PROPERTY_OVERRIDES += \
    keyguard.no_require_sim=true

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
