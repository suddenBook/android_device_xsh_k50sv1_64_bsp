LOCAL_PATH := device/xsh/k50sv1_64_bsp
include $(LOCAL_PATH)/build_tiers.mk

# PRODUCT_SOONG_NAMESPACES is only a FILTER on namespaces that already exist:
# build/soong/android/namespace.go:110-127 creates one only where an Android.bp
# declares `soong_namespace {}`. This directory has no root Android.bp, so an
# entry for it would match nothing, and vendor/xsh/k50sv1_64_bsp declares its own
# in vendor/xsh/k50sv1_64_bsp/Android.bp:19 -- the generated
# k50sv1_64_bsp-vendor.mk only carries the matching PRODUCT_SOONG_NAMESPACES
# filter line, which is the FILTER described above and not the declaration.
# Listing this directory here just duplicated that filter.
# k50sv1_perfd and sensors.mt6755 therefore live in the root namespace and
# are global module names; add a soong_namespace{} here if that ever needs to
# change, rather than re-adding a line that advertises isolation the tree does
# not have.

$(call inherit-product-if-exists, vendor/xsh/k50sv1_64_bsp/k50sv1_64_bsp-vendor.mk)

# Google's Android System WebView in place of AOSP's. Optional by construction:
# without vendor/google_webview the product falls back to external/
# chromium-webview's `webview`, which is what media_product.mk asks for.
$(call inherit-product-if-exists, vendor/google_webview/webview.mk)

# The Stock IMS APK directly references the first two MTK contracts. Its
# absolute-path extension plugin imports ims-common plus MTK telephony/telecom
# classes. These six are the complete MTK type closure and must be boot jars so
# the shared phone-UID process and plugin parent loader resolve them before IMS
# initialization.
PRODUCT_BOOT_JARS += \
    mediatek-common \
    mediatek-ims-base \
    mediatek-ims-common \
    mediatek-telecom-common \
    mediatek-telephony-base \
    mediatek-telephony-common

# The Styles entry that makes HarmonyOS Sans selectable. The .ttf files come
# from fonts/Android.mk; the family that names them is registered in
# vendor/lineage/prebuilt/common/etc/fonts_customization.xml, which is an
# upstream file because SystemFonts.java:313 reads exactly one hardcoded path
# and a second writer of it is a ckati "overriding commands for target" ERROR
# (dep.cc:186-201), which build/soong/ui/build/kati.go:134-136 turns on for the
# main pass unless BUILD_BROKEN_DUP_RULES is set -- it is not set here, and
# board_config.mk:90 is where it would go. base_rules.mk:506-513 is only the
# ordinary install rule; its one "already defined" error, at :324, is a
# duplicate MODULE NAME check, not a duplicate install path. See
# work/k50sv1-bringup/upstream/README.md.
# The .ttf modules are named explicitly. They used to be pulled in by
# LOCAL_REQUIRED_MODULES on the fonts_customization.xml module, and when that
# module moved upstream the requirement went with it -- the fonts then built and
# were never installed, while fonts_customization.xml still named them. A font
# family whose files are absent is dropped at parse time, so the failure would
# have been a missing Styles entry and nothing in the log.
PRODUCT_PACKAGES += \
    HarmonyOSSans-Italic.ttf \
    HarmonyOSSans-Regular.ttf \
    K50sv1HarmonyOSSansFont

# Prefer AOSP Q service shells and complete-architecture platform helpers.
# Proprietary legacy implementations are supplied by the vendor tree and
# loaded through the standard HIDL wrappers. Stock has only 64-bit Wi-Fi
# keystore helpers, so build both variants from source for Soong consistency.
# Not listed, because an inherited AOSP product already provides them and a
# second listing only rots when AOSP drops one:
#   android.hardware.configstore@1.1-service  base_vendor.mk:43
#   vibrator.default                          handheld_vendor.mk:28
#   libvisualizer                             base_vendor.mk:62
#
# The seven modules migrated from prebuilt to AOSP source in the same change as
# the seven added below are NOT listed either, for the same reason. The full
# chain that pre-declares them is unconditional:
#   lineage_k50sv1_64_bsp.mk -> aosp_base.mk -> full_base.mk ->
#   generic_no_telephony.mk -> handheld_vendor.mk -> media_vendor.mk ->
#   base_vendor.mk
#   libbundlewrapper libdownmix libdynproc libldnhncr libreverbwrapper
#                                             base_vendor.mk:51,53,55,58,60
#   libaudiopreprocessing libwebrtc_audio_preprocessing
#                                             media_vendor.mk:25,26
PRODUCT_PACKAGES += \
    android.hardware.audio.effect@5.0-impl \
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
    audio.r_submix.default \
    audio.usb.default \
    libalsautils \
    libeffectsconfig.vendor \
    libkeystore-engine-wifi-hidl \
    libkeystore-wifi-hidl \
    libnbaio_mono \
    librilutils \
    libsensorndkbridge \
    libtinyxml \
    sensors.mt6755

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
    $(LOCAL_PATH)/configs/media_codecs_mediatek_audio.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_mediatek_audio.xml \
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
    $(LOCAL_PATH)/rootdir/etc/init/init.wfca.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.wfca.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.epdg_wod.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.epdg_wod.rc \
    $(LOCAL_PATH)/rootdir/etc/init/lbs_hidl_service.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/lbs_hidl_service.rc \
    $(LOCAL_PATH)/rootdir/etc/init/netdagent.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/netdagent.rc \
    $(LOCAL_PATH)/rootdir/etc/init/init.wmt.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.wmt.rc \
    $(LOCAL_PATH)/rootdir/etc/init/zz_vendor.media.omx.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/zz_vendor.media.omx.rc \
    $(LOCAL_PATH)/rootdir/vendor/ueventd.rc:$(TARGET_COPY_OUT_VENDOR)/ueventd.rc \
    $(LOCAL_PATH)/keylayout/ACCDET.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/ACCDET.kl \
    $(LOCAL_PATH)/keylayout/fts_ts.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/fts_ts.kl \
    $(LOCAL_PATH)/keylayout/HALL_DEV.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/HALL_DEV.kl \
    $(LOCAL_PATH)/keylayout/mtk-kpd.kl:$(TARGET_COPY_OUT_VENDOR)/usr/keylayout/mtk-kpd.kl \
    $(LOCAL_PATH)/permissions/privapp-permissions-mtk-ims.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/privapp-permissions-mtk-ims.xml

# SUPL TLS trust store. Its own block because it needs a comment, and a `#`
# inside a backslash-continued list would silently swallow every entry after it.
#
# This is a real OpenSSL CApath, not decoration: /vendor/bin/mtk_agpsd contains
# both the literal "/vendor/etc/security/cacerts_supl" and
# "SSL_CTX_load_verify_locations() error: 0x%x", configs/agps_profiles_conf2.xml
# sets tls="true" on both SUPL profiles and cert_from_sdcard="false", so this
# directory is the only place the daemon can find a root. The `.0` filenames are
# OpenSSL's OLD (MD5) subject hash, not the modern SHA-1 one -- verified against
# stock, whose own /vendor/etc/security/cacerts_supl uses the same convention --
# so these names are correct for the lookup and must not be "fixed".
#
# TWO OF THE THREE ROOTS THAT USED TO BE HERE WERE EXPIRED, and are removed:
#   111e6273.0  GlobalSign Root CA - R2      notAfter 2021-12-15   REMOVED
#   3ad48a91.0  Baltimore CyberTrust Root    notAfter 2025-05-12   REMOVED
#   f013ecaf.0  GTS Root R1                  notAfter 2036-06-22   kept
# (openssl x509 -noout -enddate on system/ca-certificates/files/*.)
#
# An expired root sitting in a CApath is the AddTrust / DST-Root-X3 failure
# class: the path builder can select the expired anchor and fail the handshake
# even though a valid alternative path exists. Nothing was broken yet because
# the only configured profile is supl.google.com:7275, whose chain terminates at
# GTS Root R1 -- the one that is still valid -- but the two dead roots were pure
# downside and 3ad48a91.0 had already been dead for fifteen months.
#
# DELIBERATELY NOT ADDED: b0f3e76e.0, GlobalSign Root CA (R1, notAfter
# 2028-01-28), the current cross-signer of GTS Root R1. It would only matter if
# the server presented a chain that terminates at GlobalSign rather than at GTS
# Root R1, and it cannot, because the self-signed GTS Root R1 is in this store
# and the builder stops there. Adding it would re-create exactly the hazard just
# removed -- an older, sooner-expiring anchor for the same subject -- with a
# 2028 fuse, and would widen the trust surface of a network-facing daemon for no
# measured gain. Stock ships six roots here (plus a `lab` subdirectory) and none
# of them is GTS Root R1; stock's set is carrier SUPL, not Google's.
#
# REVISIT IF: a non-Google SUPL profile is configured in
# agps_profiles_conf2.xml, or mtk_agpsd starts logging
# "SSL_CTX_load_verify_locations() error" or a verify failure against
# supl.google.com. Add that server's root then, and check its notAfter.
PRODUCT_COPY_FILES += \
    system/ca-certificates/files/f013ecaf.0:$(TARGET_COPY_OUT_VENDOR)/etc/security/cacerts_supl/f013ecaf.0

# Hardware feature declarations. Separate block for the same comment reason.
#
# This list is the device's hardware contract and it is deliberately SHORTER
# than stock's /vendor/etc/permissions: stock also ships
# android.hardware.fingerprint.xml, android.hardware.sensor.light.xml and
# android.hardware.sensor.proximity.xml, and this handset has none of those
# three. Stock's list is not authoritative here; the verified hardware is.
#
# android.hardware.wifi.passpoint.xml is ADDED (stock ships it; this tree had
# dropped it). It is a framework gate only, and everything behind it is already
# present:
#   * /vendor/bin/hw/wpa_supplicant is built with CONFIG_INTERWORKING and
#     CONFIG_HS20 -- 203 ANQP / "HS 2.0" strings, including the GAS query and
#     NAI Home Realm paths.
#   * manifest.xml:156-160 declares android.hardware.wifi.supplicant@1.2, served
#     by that same binary.
#   * frameworks/opt/net/wifi WifiInjector.java:291,295 constructs
#     PasspointManager and PasspointNetworkEvaluator UNCONDITIONALLY; the
#     feature flag at :355 only decides whether the evaluator is registered with
#     WifiNetworkSelector. Eleven further sites in WifiServiceImpl.java gate the
#     public Passpoint API on it.
# So without the file the objects are built and then never used, and every
# Passpoint API returns unsupported -- a silent capability loss, and the failure
# mode is invisible because nothing logs it. Adding it cannot crash a device
# that lacks the capability, because the capability is not missing.
#
# Passpoint is a Wi-Fi protocol feature, not a separate piece of hardware, so
# this does not contradict the verified hardware list.
PRODUCT_COPY_FILES += \
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
    frameworks/native/data/etc/android.hardware.wifi.passpoint.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.passpoint.xml \
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

# Log buffer sizing, diagnostic tiers only.
#
# liblog's default is 256 KiB per buffer. That was 64 KiB while this product was
# Android Go, and a runtime sweep found every non-empty buffer at 95-98% of
# capacity with only the last FIVE MINUTES of a 70-minute uptime still present.
# The vendor drivers are extraordinarily chatty -- the shipped prebuilt kernel
# still contains a vendor developer's `zhengqiongtest` and `cfsucc @@@` printks --
# so 256 KiB is not enough to hold a boot plus a reproduction.
#
# 1 MiB is still not enough for the RADIO buffer, and that is the one that
# matters. HANDOFF trap 28 is the whole reason: MediaTek's IMSM retry loop runs
# at ~42 Hz and writes ~640 lines a second, which wraps even a 16 MiB radio ring
# in ninety seconds, and three sessions of VoLTE diagnosis were performed on
# windows that no longer contained the cause.
#
# The standing workaround is `adb shell logcat -b all -G 64M` plus
# `setprop persist.logd.size 64M`. Neither survives the userdata wipe that every
# flash performs, so the FIRST BOOT after a flash -- the one boot nobody can
# repeat -- has always been captured at the default size. That is how this
# session lost the RIL shim's own "attach-APN re-send armed" line: the fix was
# working and the line proving it had already scrolled.
#
# liblog resolves per-buffer keys first: `ro.logd.size.<name>` and
# `persist.logd.size.<name>` before the global (properties.cpp:589-621,
# __android_logger_get_buffer_size). So raise only the two that need it rather
# than multiplying every buffer by 32. The cap is a maximum, not a
# preallocation -- logd grows into it -- and this handset has 3.7 GiB.
#
# Not set on tier 3: a release image should not spend this on log buffers, and
# nobody is reading them there.
ifneq ($(K50SV1_BUILD_TIER),3)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.logd.size=1M \
    ro.logd.size.main=8M \
    ro.logd.size.radio=32M
endif

# Silence one vendor tag that carries no information and 21% of the main buffer.
#
# /vendor/bin/fuelgauged tries to open /dev/kmsg for its own logging, which is
# crw------- root root while the daemon runs as `system`, so the open fails and
# it logs the failure -- "fd < 0, init first!" / "init failed, return!" -- about
# 17 times a second, forever. The gauge itself works fine; dmesg shows its ADC
# reads and dumpsys battery is correct. What is lost is only its kmsg logging.
#
# Measured: 346 lines in 20 s, the largest single tag in the buffer, ahead of
# the camera HAL's 3A tags.
#
# The obvious fix is not the fix. /sys/devices/platform/battery_meter/
# FG_daemon_log_level looks like the gate and is not: writing 0 changed the rate
# from 346 to 344 lines per 20 s, i.e. not at all. Stock's answer -- `chmod 0666
# /dev/kmsg` in its charger block -- world-writes the kernel log to buy back a
# log line, which is a bad trade in both directions.
#
# liblog's own tag gate does work, measured 0 lines per 20 s.
# `log.tag.` rather than `persist.log.tag.` deliberately: both work, and this
# one involves no /data state that survives a wipe or diverges from the build.
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    log.tag.MTK_FG=S

# Screen-on maximum performance. One leaf daemon; see perfd/k50sv1_perfd.c for
# why it exists, what it measured, and the six-site recipe to remove it.
PRODUCT_PACKAGES += \
    k50sv1_perfd

# Build-time xmllint over every XML in this device tree. Not installed; it exists
# so that an unparseable hand-written XML is a build failure instead of a
# runtime one. See Android.mk.
PRODUCT_PACKAGES += \
    k50sv1-xml-validation

# RIL shim: makes GET_RADIO_CAPABILITY fail so the framework uses a single
# static RAF for both phones and never starts an MTK SIM-switch transaction.
# rilproxy.rc is patched to load this instead of mtk-rilproxy.so; the shim
# dlopens the blob and forwards everything else. Full reasoning, with the
# vendor-blob addresses it is derived from, is in ril-shim/k50sv1_ril_shim.c.
PRODUCT_PACKAGES += \
    libril-k50sv1-shim
