LOCAL_PATH := device/xsh/k50sv1_64_bsp
include $(LOCAL_PATH)/build_tiers.mk

# PRODUCT_SOONG_NAMESPACES is only a FILTER on namespaces that already exist:
# build/soong/android/namespace.go:110-127 creates one only where an Android.bp
# declares `soong_namespace {}`. This directory has no root Android.bp, so an
# entry for it would match nothing, and vendor/xsh/k50sv1_64_bsp declares its own
# in the generated k50sv1_64_bsp-vendor.mk -- listing it here just duplicated it.
# k50sv1_perfd and sensors.k50sv1_64_bsp therefore live in the root namespace and
# are global module names; add a soong_namespace{} here if that ever needs to
# change, rather than re-adding a line that advertises isolation the tree does
# not have.

$(call inherit-product-if-exists, vendor/xsh/k50sv1_64_bsp/k50sv1_64_bsp-vendor.mk)

# Google's Android System WebView in place of AOSP's. Optional by construction:
# without vendor/google_webview the product falls back to external/
# chromium-webview's `webview`, which is what media_product.mk asks for.
$(call inherit-product-if-exists, vendor/google_webview/webview.mk)

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
    frameworks/av/services/audiopolicy/config/a2dp_in_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/a2dp_in_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/usb_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/usb_audio_policy_configuration.xml \
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

# PRODUCT_SYSTEM_DEFAULT_PROPERTIES, not PRODUCT_DEFAULT_PROPERTY_OVERRIDES.
# On a full-Treble device BOARD_PROPERTY_OVERRIDES_SPLIT_ENABLED is true
# (build/make/core/config.mk:706-708), and PRODUCT_DEFAULT_PROPERTY_OVERRIDES
# then lands in /VENDOR/default.prop (Makefile:156-157, :268-281) -- not in
# /system/etc/prop.default. Both keys are read only by /system code: adbd for
# service.adb.root, system_server's UsbDeviceManager for
# persist.sys.usb.config. Putting them on /vendor worked solely because init
# loads /vendor/default.prop last and LoadProperties() uses insert_or_assign,
# i.e. by the same accidental file-order mechanism this tree already refused to
# rely on for ro.control_privapp_permissions.
#
# It bit in two places. At Tier 3, post_process_props.py writes
# persist.sys.usb.config=none into /system/etc/prop.default because the key is
# empty there, and the intended `mtp` won only by file order. And the debug
# tiers' root-adb switch was persisted on the partition a system-only OTA does
# not replace.
ifeq ($(K50SV1_ADB_ENABLED),true)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.usb.config=adb
ifeq ($(K50SV1_ADB_ROOT),true)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += service.adb.root=1
endif
else
# Production tier retains USB file transfer without exposing adbd.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.usb.config=mtp
endif

# Q's asynchronous/nonblocking FunctionFS paths fail on this 3.18 gadget.
#
# ro.telephony.iwlan_operation_mode=legacy matches Stock and is LOAD-BEARING --
# do not remove it. TransportManager.isInLegacyMode() is
#     mode.equals("legacy") || mPhone.getHalVersion().less(RADIO_HAL_VERSION_1_4)
# An earlier revision of this comment claimed the RIL registers
# android.hardware.radio@1.0::IRadio/slot1, so that the second clause forced
# legacy mode by itself and the property "changes nothing right now". That is
# false and would have invited someone to delete it. `lshal` on the handset
# reports the interfaceChain up to @1.4, and manifest.xml:103-113 in this same
# repository declares @1.4::IRadio/slot1 -- so less(1.4) is FALSE and the
# property is the only thing selecting legacy mode. Without it the device goes
# straight to AP-assisted mode, where TransportManager constructs an
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
# What stays on /system is what /system code reads: adbd and UsbDeviceManager.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.adb.nonblocking_ffs=0 \
    sys.usb.ffs.aio_compat=1

# Screen-on maximum performance. One leaf daemon; see perfd/k50sv1_perfd.c for
# why it exists, what it measured, and the six-site recipe to remove it.
PRODUCT_PACKAGES += \
    k50sv1_perfd

# Build-time xmllint over every XML in this device tree. Not installed; it exists
# so that an unparseable hand-written XML is a build failure instead of a
# runtime one. See Android.mk.
PRODUCT_PACKAGES += \
    k50sv1-xml-validation
