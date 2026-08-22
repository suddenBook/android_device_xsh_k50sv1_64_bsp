LOCAL_PATH := device/xsh/k50sv1_64_bsp

PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH) \
    vendor/xsh/k50sv1_64_bsp

$(call inherit-product-if-exists, vendor/xsh/k50sv1_64_bsp/k50sv1_64_bsp-vendor.mk)

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
    android.hardware.power@1.0-impl \
    android.hardware.power@1.0-service \
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
    libvisualizer \
    power.default

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/configs/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(LOCAL_PATH)/configs/mtk_bt_fw.conf:$(TARGET_COPY_OUT_SYSTEM)/etc/bluetooth/mtk_bt_fw.conf \
    $(LOCAL_PATH)/configs/mtk_bt_stack.conf:$(TARGET_COPY_OUT_SYSTEM)/etc/bluetooth/mtk_bt_stack.conf \
    $(LOCAL_PATH)/configs/mtk_omx_core.cfg:$(TARGET_COPY_OUT_VENDOR)/etc/mtk_omx_core.cfg \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6755:$(TARGET_COPY_OUT_RAMDISK)/fstab.mt6755 \
    $(LOCAL_PATH)/rootdir/etc/fstab.mt6755:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.mt6755 \
    $(LOCAL_PATH)/rootdir/etc/fstab.enableswap:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.enableswap \
    $(LOCAL_PATH)/rootdir/etc/init/hw/init.mt6755.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.mt6755.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.connectivity.modules.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.connectivity.modules.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.gnss.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.gnss.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.wmt.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.wmt.rc \
    $(LOCAL_PATH)/rootdir/vendor/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/ueventd.rc \
    $(LOCAL_PATH)/keylayout/HALL_DEV.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/HALL_DEV.kl \
    frameworks/native/data/etc/android.hardware.camera.flash-autofocus.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.flash-autofocus.xml \
    frameworks/native/data/etc/android.hardware.camera.front.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.camera.front.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.location.gps.xml \
    frameworks/native/data/etc/android.hardware.telephony.gsm.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.telephony.gsm.xml \
    frameworks/native/data/etc/android.hardware.touchscreen.multitouch.jazzhand.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.touchscreen.multitouch.jazzhand.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml

DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay

PRODUCT_AAPT_CONFIG := normal
PRODUCT_AAPT_PREF_CONFIG := xhdpi
PRODUCT_CHARACTERISTICS := default

PRODUCT_DEFAULT_PROPERTY_OVERRIDES += \
    persist.sys.usb.config=adb

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.radio.multisim.config=dsds \
    ro.hardware.egl=mali \
    ro.frp.pst=/dev/block/platform/mtk-msdc.0/11230000.msdc0/by-name/frp \
    ro.opengles.version=196610 \
    ro.sf.lcd_density=320 \
    ro.telephony.default_network=9,9,9,9 \
    ro.telephony.sim.count=2

PRODUCT_VENDOR_PROPERTIES += \
    persist.vendor.connsys.coredump.mode=0 \
    ro.vendor.mtk_audio_alac_support=1 \
    ro.vendor.mtk_audio_ape_support=1 \
    ro.vendor.mtk_audio_tuning_tool_ver=V2.2 \
    ro.vendor.mtk_besloudness_support=1 \
    ro.vendor.mtk_camera_app_version=1 \
    ro.vendor.mtk_emmc_support=1 \
    ro.vendor.mtk_fd_support=1 \
    ro.vendor.mtk_gps_support=1 \
    ro.vendor.mtk_pq_color_mode=1 \
    ro.vendor.mtk_pq_support=2 \
    ro.vendor.md_apps.load_gencfg=GEN91_USER \
    ro.vendor.md_apps.load_type=user \
    ro.vendor.md_apps.load_verno=MOLY.LR11.W1630.MD.MP.V191.4 \
    ro.vendor.md_apps.support=1 \
    ro.vendor.mediatek.platform=MT6755 \
    ro.vendor.mtk_protocol1_rat_config=Lf/Lt/W/T/G \
    ro.vendor.mtk_f2fs_enable=0 \
    ro.vendor.mtk_ril_mode=c6m_3rild \
    ro.vendor.mtk_rild_read_imsi=1 \
    ro.vendor.mtk_zsdhdr_support=1 \
    ro.vendor.radio.max.multisim=dsds \
    ro.vendor.wlan.gen=gen2
