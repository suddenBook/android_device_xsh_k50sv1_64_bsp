LOCAL_PATH := device/xsh/k50sv1_64_bsp
include $(LOCAL_PATH)/build_tiers.mk

PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH) \
    vendor/xsh/k50sv1_64_bsp

$(call inherit-product-if-exists, vendor/xsh/k50sv1_64_bsp/k50sv1_64_bsp-vendor.mk)

# The Stock IMS APK directly references these two MTK framework contracts.
# They must be real boot jars, not ordinary /system/framework copies, so ART
# resolves the shared phone-UID process before its Application is created.
PRODUCT_BOOT_JARS += \
    mediatek-common \
    mediatek-ims-base

# Prefer AOSP Q service shells and complete-architecture platform helpers.
# Proprietary legacy implementations are supplied by the vendor tree and
# loaded through the standard HIDL wrappers. Stock has only 64-bit Wi-Fi
# keystore helpers, so build both variants from source for Soong consistency.
PRODUCT_PACKAGES += \
    android.hardware.configstore@1.1-service \
    android.hardware.drm@1.0-impl \
    android.hardware.drm@1.0-service \
    android.hardware.gatekeeper@1.0-impl \
    android.hardware.gatekeeper@1.0-service \
    android.hardware.graphics.allocator@2.0-service \
    android.hardware.graphics.composer@2.1-service \
    android.hardware.health@2.0-service \
    android.hardware.keymaster@3.0-impl \
    android.hardware.keymaster@3.0-service \
    android.hardware.light@2.0-impl \
    android.hardware.light@2.0-service \
    android.hardware.memtrack@1.0-impl \
    android.hardware.memtrack@1.0-service \
    android.hardware.thermal@1.0-impl \
    android.hardware.thermal@1.0-service \
    android.hardware.vibrator@1.0-impl \
    android.hardware.vibrator@1.0-service \
    vibrator.default \
    android.hardware.audio.common-util.vendor \
    android.hardware.audio.common@5.0-util.vendor \
    libeffectsconfig.vendor \
    libkeystore-engine-wifi-hidl \
    libkeystore-wifi-hidl \
    librilutils \
    libvisualizer \
    sensors.k50sv1_64_bsp

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/agps_profiles_conf2.xml:$(TARGET_COPY_OUT_VENDOR)/etc/agps_profiles_conf2.xml \
    $(LOCAL_PATH)/configs/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(LOCAL_PATH)/configs/mtk_omx_core.cfg:$(TARGET_COPY_OUT_VENDOR)/etc/mtk_omx_core.cfg \
    $(LOCAL_PATH)/configs/powerscntbl.xml:$(TARGET_COPY_OUT_VENDOR)/etc/powerscntbl.xml \
    $(LOCAL_PATH)/configs/powercontable.xml:$(TARGET_COPY_OUT_VENDOR)/etc/powercontable.xml \
    $(LOCAL_PATH)/configs/power_whitelist_cfg.xml:$(TARGET_COPY_OUT_VENDOR)/etc/power_whitelist_cfg.xml \
    $(LOCAL_PATH)/configs/seccomp_policy/mediacodec.policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/mediacodec.policy \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6755:$(TARGET_COPY_OUT_RAMDISK)/fstab.mt6755 \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6755:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.mt6755 \
    $(LOCAL_PATH)/rootdir/etc/fstab.enableswap:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.enableswap \
    $(LOCAL_PATH)/rootdir/etc/init/android.hardware.sensors@2.0-service.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/android.hardware.sensors@2.0-service.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.sensors.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.sensors.rc \
    $(LOCAL_PATH)/rootdir/etc/init/vendor.mediatek.hardware.mtkpower@1.0-service.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/vendor.mediatek.hardware.mtkpower@1.0-service.rc \
    $(LOCAL_PATH)/rootdir/etc/init/hw/init.mt6755.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.mt6755.rc \
    $(LOCAL_PATH)/rootdir/etc/init/hw/init.mt6755.usb.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.mt6755.usb.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.connectivity.modules.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.connectivity.modules.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.gnss.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.gnss.rc \
    $(LOCAL_PATH)/rootdir/etc/init/lbs_hidl_service.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/lbs_hidl_service.rc \
    $(LOCAL_PATH)/rootdir/etc/init/netdagent.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/netdagent.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.wmt.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.wmt.rc \
    $(LOCAL_PATH)/rootdir/etc/init/zz_vendor.media.omx.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/zz_vendor.media.omx.rc \
    $(LOCAL_PATH)/rootdir/vendor/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/ueventd.rc \
    $(LOCAL_PATH)/keylayout/ACCDET.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/ACCDET.kl \
    $(LOCAL_PATH)/keylayout/fts_ts.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/fts_ts.kl \
    $(LOCAL_PATH)/keylayout/HALL_DEV.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/HALL_DEV.kl \
    $(LOCAL_PATH)/keylayout/mtk-kpd.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/mtk-kpd.kl \
    $(LOCAL_PATH)/permissions/privapp-permissions-mtk-ims.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/privapp-permissions-mtk-ims.xml \
    system/ca-certificates/files/f013ecaf.0:$(TARGET_COPY_OUT_VENDOR)/etc/security/cacerts_supl/f013ecaf.0 \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.camera.flash-autofocus.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.flash-autofocus.xml \
    frameworks/native/data/etc/android.hardware.camera.front.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.front.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.location.gps.xml \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.hardware.telephony.gsm.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.telephony.gsm.xml \
    frameworks/native/data/etc/android.hardware.telephony.ims.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.telephony.ims.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.touchscreen.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.accessory.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.software.midi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.midi.xml

DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xhdpi
PRODUCT_CHARACTERISTICS := default

ifeq ($(K50SV1_ADB_ENABLED),true)
PRODUCT_DEFAULT_PROPERTY_OVERRIDES += persist.sys.usb.config=adb
ifeq ($(K50SV1_ADB_ROOT),true)
PRODUCT_DEFAULT_PROPERTY_OVERRIDES += service.adb.root=1
endif
else
# Production tier retains USB file transfer without exposing adbd.
PRODUCT_DEFAULT_PROPERTY_OVERRIDES += persist.sys.usb.config=mtp
endif

# Q's asynchronous/nonblocking FunctionFS paths fail on this 3.18 gadget.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.adb.nonblocking_ffs=0 \
    persist.radio.multisim.config=dsds \
    ro.hardware.egl=mali \
    ro.frp.pst=/dev/block/platform/mtk-msdc.0/11230000.msdc0/by-name/frp \
    ro.opengles.version=196610 \
    ro.sf.lcd_density=320 \
    ro.telephony.default_network=9,9,9,9 \
    ro.telephony.sim.count=2 \
    sys.usb.ffs.aio_compat=1
