# 64-bit primary userspace with a 32-bit compatibility runtime.
# Product copy rules keep the first source for a duplicate destination. Add
# the verified no-compass handheld contract before inherited common products
# contribute AOSP's generic version.
PRODUCT_COPY_FILES += \
    device/xsh/k50sv1_64_bsp/permissions/handheld_core_hardware.xml:vendor/etc/permissions/handheld_core_hardware.xml

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# Full telephony base, then the device-specific truthful feature contract.
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_o.mk)
$(call inherit-product, device/xsh/k50sv1_64_bsp/device.mk)
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Stock boot and recovery carry the legacy Android BootSignature with the AOSP
# verity test key. This does not enable dm-verity or AVB for system/vendor.
PRODUCT_SUPPORTS_BOOT_SIGNER := true
PRODUCT_VERITY_SIGNING_KEY := build/make/target/product/security/verity

PRODUCT_NAME := lineage_k50sv1_64_bsp
PRODUCT_DEVICE := k50sv1_64_bsp
PRODUCT_BRAND := XSH
PRODUCT_MODEL := F212
PRODUCT_MANUFACTURER := XSH
