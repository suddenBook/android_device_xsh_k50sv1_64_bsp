# 64-bit primary userspace with a 32-bit compatibility runtime.
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# Full telephony base, then the device-specific truthful feature contract.
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base_telephony.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_o.mk)
$(call inherit-product, device/xsh/k50sv1_64_bsp/device.mk)
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_NAME := lineage_k50sv1_64_bsp
PRODUCT_DEVICE := k50sv1_64_bsp
PRODUCT_BRAND := XSH
PRODUCT_MODEL := F212
PRODUCT_MANUFACTURER := XSH
