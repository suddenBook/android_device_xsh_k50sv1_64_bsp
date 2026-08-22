LOCAL_PATH := device/xsh/k50sv1_64_bsp

PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH) \
    vendor/xsh/k50sv1_64_bsp

$(call inherit-product-if-exists, vendor/xsh/k50sv1_64_bsp/k50sv1_64_bsp-vendor.mk)

# full_base_telephony installs the CTS handheld core file, which falsely
# requires a compass. Replace it with the verified device-specific contract.
PRODUCT_COPY_FILES := $(filter-out \
    %:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml, \
    $(PRODUCT_COPY_FILES))

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/permissions/handheld_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml \
    frameworks/native/data/etc/android.hardware.camera.flash-autofocus.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.flash-autofocus.xml \
    frameworks/native/data/etc/android.hardware.camera.front.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.front.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.location.gps.xml \
    frameworks/native/data/etc/android.hardware.telephony.gsm.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.telephony.gsm.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.touchscreen.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml

DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xhdpi
PRODUCT_CHARACTERISTICS := default

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.sf.lcd_density=320

PRODUCT_VENDOR_PROPERTIES += \
    ro.vendor.mediatek.platform=MT6755 \
    ro.vendor.mtk_f2fs_enable=0
