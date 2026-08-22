# 64-bit primary userspace with a 32-bit compatibility runtime.
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

# Stock boot and recovery carry the legacy Android BootSignature with the AOSP
# verity test key. This does not enable dm-verity or AVB for system/vendor.
PRODUCT_SUPPORTS_BOOT_SIGNER := true
PRODUCT_VERITY_SIGNING_KEY := build/make/target/product/security/verity

PRODUCT_NAME := lineage_k50sv1_64_bsp
PRODUCT_DEVICE := k50sv1_64_bsp
PRODUCT_BRAND := XSH
PRODUCT_MODEL := F212
PRODUCT_MANUFACTURER := XSH
