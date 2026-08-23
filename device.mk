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
# Not listed, because an inherited AOSP product already provides them and a
# second listing only rots when AOSP drops one:
#   android.hardware.configstore@1.1-service  base_vendor.mk:43
#   vibrator.default                          handheld_vendor.mk:28
#   libvisualizer                             base_vendor.mk:62
PRODUCT_PACKAGES += \
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
    android.hardware.audio.common-util.vendor \
    android.hardware.audio.common@5.0-util.vendor \
    libeffectsconfig.vendor \
    libkeystore-engine-wifi-hidl \
    libkeystore-wifi-hidl \
    librilutils \
    sensors.k50sv1_64_bsp

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/agps_profiles_conf2.xml:$(TARGET_COPY_OUT_VENDOR)/etc/agps_profiles_conf2.xml \
    $(LOCAL_PATH)/configs/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(LOCAL_PATH)/configs/media_codecs.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs.xml \
    $(LOCAL_PATH)/configs/media_profiles_V1_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_profiles_V1_0.xml \
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
    $(LOCAL_PATH)/rootdir/etc/init/init.mediadrm.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.mediadrm.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.volte_imcb.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.volte_imcb.rc \
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
    system/ca-certificates/files/111e6273.0:$(TARGET_COPY_OUT_VENDOR)/etc/security/cacerts_supl/111e6273.0 \
    system/ca-certificates/files/3ad48a91.0:$(TARGET_COPY_OUT_VENDOR)/etc/security/cacerts_supl/3ad48a91.0 \
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
#
# ro.telephony.iwlan_operation_mode=legacy matches Stock and states the contract
# explicitly. TransportManager.isInLegacyMode() is
#     mode.equals("legacy") || mPhone.getHalVersion().less(RADIO_HAL_VERSION_1_4)
# and this RIL registers android.hardware.radio@1.0::IRadio/slot1, so the second
# clause already forces legacy mode today and the property changes nothing right
# now. It is set anyway because the alternative is a latent trap: without it, the
# behaviour depends entirely on which IRadio version the blob happens to
# register, and in AP-assisted mode TransportManager constructs an
# AccessNetworksManager that then finds no IQualifiedNetworksService --
# config_qualified_networks_service_package is empty in AOSP and this tree ships
# no QNS. Legacy is also the architecturally correct answer here: MediaTek runs
# the ePDG tunnel in Android userspace (strongSwan), not as an Android data
# connection, so IWLAN must not be modelled as a separate transport.
# Partition ownership follows
# https://source.android.com/docs/core/architecture/configuration/add-system-properties:
# a property that describes THIS HARDWARE belongs on /vendor, so that a
# system-only OTA or a GSI boot cannot contradict it. Everything hardware-facing
# in this block therefore moved to vendor.prop, which Q appends to
# /vendor/build.prop automatically (build/make/core/Makefile:486-490):
#   ro.hardware.egl, ro.frp.pst, ro.opengles.version,
#   persist.radio.multisim.config, ro.telephony.{sim.count,default_network,
#   iwlan_operation_mode}
# ro.sf.lcd_density is gone entirely -- TARGET_SCREEN_DENSITY in BoardConfig.mk
# is the first-class hook for it.
#
# What stays here is what adbd reads, and adbd lives on /system.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.adb.nonblocking_ffs=0 \
    sys.usb.ffs.aio_compat=1
