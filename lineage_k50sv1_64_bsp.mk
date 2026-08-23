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
    device/xsh/k50sv1_64_bsp/permissions/handheld_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml \
    device/xsh/k50sv1_64_bsp/permissions/android.software.nfc.beam.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.software.nfc.beam.xml

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# Android Go. The SoC is an 8x Cortex-A53 at 1.5 GHz with a Mali-T860 MP2 and
# an eMMC that tops out around 150 MB/s; 3.74 GiB of usable RAM is the one
# resource this device is not short of. Inheriting AOSP's canonical Go product
# defaults (ro.config.low_ram, speed-profile system server, profile-guided boot
# image, always-preopt extracted APKs, in-process network stack, minimized Java
# debug info) buys back CPU and storage. See the two deliberate deviations
# below.
$(call inherit-product, $(SRC_TARGET_DIR)/product/go_defaults_common.mk)

# Deviation 1: heap. go_defaults_common.prop sizes the Dalvik heap for a 1 GiB
# handset (128m/256m). AOSP's own per-RAM profile for this device is the 4096
# one, whose 0.6 target utilization and larger free window also mean fewer GC
# pauses, which is what a weak CPU needs. PRODUCT_PROPERTY_OVERRIDES lands in
# vendor/build.prop, which init loads after system/build.prop, so these values
# are the ones that take effect.
#
# Not a deviation, stated so nobody adds it: MALLOC_SVELTE is left unset. No
# Go defaults file sets it either (tree-wide it appears only in
# board_config.mk:139's error text and soong_config.mk:117), so unset is the
# AOSP default. It trades CPU for RAM, which is the wrong direction here.
$(call inherit-product, frameworks/native/build/phone-xhdpi-4096-dalvik-heap.mk)

# Build the full phone userspace without AOSP's generic vendor rild. The MTK
# radio stack supplies mtkrild and rilproxy, so installing a second rild would
# create a competing init service for the same modem contract.
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/telephony_product.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/product_launched_with_o.mk)
$(call inherit-product, device/xsh/k50sv1_64_bsp/device.mk)

# Tier 1 only, and it must be declared before common_full_phone.mk is
# inherited: FINAL_DEFAULT_PROPERTIES runs through uniq-pairs-by-first-component
# (build/make/core/Makefile:245-246), which is first-wins, so a later assignment
# would lose to Lineage's.
#
# Use PRODUCT_SYSTEM_DEFAULT_PROPERTIES, the same variable Lineage uses at
# vendor/lineage/config/common.mk:79-80. An earlier revision used
# PRODUCT_PROPERTY_OVERRIDES and explained the ordering in terms of that
# variable's dedup. That reasoning did not hold: the two variables land in
# different files (/system/etc/prop.default vs /vendor/build.prop), so
# uniq-pairs-by-first-component never saw both keys and the ordering constraint
# it described did not exist. What made "log" win was init's file order --
# property_service.cpp:901 then :910, last file wins even for ro. -- which is
# accidental, and would silently invert if Lineage ever moved its enforce.
#
# LineageOS sets ro.control_privapp_permissions=enforce, under
# which a privileged app requesting a signature|privileged permission that is
# missing from its allowlist makes PermissionManagerService throw and
# system_server boot-loop. The MTK IMS allowlist is derived by hand, so on the
# diagnostic tier downgrade to "log": a wrong entry then costs one grep instead
# of one flash cycle. Tiers 2 and 3 keep Lineage's enforce.
ifeq ($(K50SV1_BUILD_TIER),1)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += ro.control_privapp_permissions=log
endif

# Select LineageOS's partner-GMS path. WITH_GMS_GO is deliberately not set:
# partner_gms.mk would route it to products/gms_go.mk, which no longer exists.
# This is independent of go_defaults_common.mk above -- Android Go platform
# mode stays on; only the GMS payload changed from the Go set to the full one.
# The explicit guard prevents the optional product inherit from silently
# producing a GMS-free image.
WITH_GMS := true
ifeq ($(wildcard vendor/partner_gms/products/gms.mk),)
$(error Missing vendor/partner_gms/products/gms.mk; import the pinned NikGapps omni payload first)
endif
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    keyguard.no_require_sim=true

# VoLTE availability. ImsManager.isVolteEnabledByPlatform() ANDs
# config_device_volte_available with CarrierConfig's
# KEY_CARRIER_VOLTE_AVAILABLE_BOOL, which defaults to false and is only set
# true by the ~24 carrier assets AOSP ships -- Stock papers over that with its
# own MtkCarrierConfig APK carrying ~473 per-MCCMNC assets, which is not
# something to port. persist.dbg.volte_avail_ovr short-circuits both the
# overlay and CarrierConfig (ImsManager.java:622-637), which is the supported
# way to enable VoLTE on a device whose operator has no AOSP carrier asset.
# The other two are stated explicitly so the voice-only contract is not left
# to a default.
# These four are framework knobs -- ImsManager and Keyguard read them, both on
# /system -- so they go in PRODUCT_SYSTEM_DEFAULT_PROPERTIES rather than
# PRODUCT_PROPERTY_OVERRIDES, which on a Treble device lands in
# /vendor/build.prop (build/make/core/Makefile:492-497).
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    persist.dbg.volte_avail_ovr=1 \
    persist.dbg.vt_avail_ovr=0 \
    persist.dbg.wfc_avail_ovr=0

# The 3.18 kernel has neither CONFIG_MEMCG nor PSI, so per-app memory cgroups
# do not exist and lmkd cannot run its userspace killer. lmkd probes
# /sys/module/lowmemorykiller/parameters/minfree for write access
# (system/core/lmkd/lmkd.c:1968), finds it, and takes the in-kernel path
# unconditionally -- every ro.lmk.* is read and then never consumed, including
# the four go_defaults_common.prop drags in. The only tuning with any effect is
# config_lowMemoryKillerMinFreeKbytesAdjust/Absolute, left at defaults.
#
# per_app_memcg states what the kernel already forces: processgroup.cpp:402-409
# gates on isMemoryCgroupSupported() first, which is false here regardless. It
# is belt and braces, kept so the value is not silently inferred from low_ram.
# ro.config.low_ram itself comes from go_defaults_common.mk.
# NOTE (PSI): lmkd needs the *writable trigger* interface, which is upstream
# 5.2 -- not the read-only /proc/pressure of 4.20. Neither exists here.
PRODUCT_PROPERTY_OVERRIDES += \
    ro.config.per_app_memcg=false

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

# Google's client-id base for this product. Consumed by
# vendor/lineage/config/common.mk to set ro.com.google.clientidbase; never set
# the property by hand.
PRODUCT_GMS_CLIENTID_BASE := android-xsh

PRODUCT_NAME := lineage_k50sv1_64_bsp
PRODUCT_DEVICE := k50sv1_64_bsp
PRODUCT_BRAND := XSH
PRODUCT_MODEL := F212
PRODUCT_MANUFACTURER := XSH
