# 64-bit primary userspace with a 32-bit compatibility runtime.
include device/xsh/k50sv1_64_bsp/build_tiers.mk

ifeq ($(K50SV1_ADB_INSECURE),true)
WITH_ADB_INSECURE := true
else
WITH_ADB_INSECURE :=
endif

# Product copy rules keep the first source for a duplicate destination
# (build/make/core/Makefile:22-42), so these must precede the inherits below.
#
# For the Beam contract that is still live: vendor/lineage/config/common.mk
# contributes a generic android.software.nfc.beam.xml and this device has no
# NFC, so the empty override has to be seen first.
#
# For handheld_core_hardware.xml the ordering argument no longer applies. With
# go_defaults_common.mk gone, NO other product in this inherit graph provides
# that destination -- full_base_telephony.mk, the other AOSP provider, is not
# inherited. The line is now the ONLY source of the file rather than merely the
# winning one; see permissions/handheld_core_hardware.xml's own header.
PRODUCT_COPY_FILES += \
    device/xsh/k50sv1_64_bsp/permissions/handheld_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/handheld_core_hardware.xml \
    device/xsh/k50sv1_64_bsp/permissions/android.software.nfc.beam.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.software.nfc.beam.xml

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# NOT Android Go. An earlier revision inherited go_defaults_common.mk to buy
# back CPU and storage on a weak SoC. The owner has since asked for full
# Android, and the trade was the wrong one anyway: this handset is short of CPU,
# not of RAM. Measured on the running Go build, MemAvailable is 2.5 GiB, zram is
# 0% used and the in-kernel lowmemorykiller has never fired.
#
# Removing that one inherit is the whole change; low_ram has exactly one setter
# (go_defaults_common.mk:22) and everything downstream reverts by itself. What
# comes back: picture-in-picture, voice recognizers, managed users/work
# profiles, activities on secondary displays, SYSTEM_ALERT_WINDOW, full-scale
# task snapshots, bubbles, notification listeners, and ram.low -> ram.normal.
# What goes away: pm.dexopt.shared=quicken (back to AOSP's `speed`, which AOSP's
# own comment in go_defaults_common.prop:29-36 says costs storage but SAVES cpu
# and battery -- the right direction here), speed-profile for system_server
# (back to `speed`, fully AOT, no JIT warm-up), and persist.traced.enable=1.
# Perfetto is runtime-enableable when a capture is needed:
#   adb shell setprop persist.traced.enable 1
# perfetto.rc:47-60 starts both daemons on that property edge.
#
# It also repairs a live defect. PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD is a
# product variable, so inherit-product CONCATENATES it; go_defaults_common.mk:38
# and vendor/lineage/config/common.mk:99 both set `false`, the value resolved to
# the two-word string `false false`, and art/Android.mk:346's exact
# `ifneq (false,...)` test therefore selected com.android.runtime.DEBUG on every
# userdebug tier -- 130 MB of libartd/dex2oatd nothing here uses, against
# Lineage's explicit request for the release APEX. One setter left, one word,
# release module. See E-042.
#
# MALLOC_SVELTE stays unset, stated so nobody adds it back with the Go comment
# it used to live under: tree-wide it appears only in board_config.mk:139's
# error text and soong_config.mk:117, so unset is the AOSP default. It trades
# CPU for RAM, which is the wrong direction here.

# The Dalvik heap. AOSP's per-RAM profile for this device: 4 GiB physical
# (MemTotal 3,925,620 kB), xhdpi (TARGET_SCREEN_DENSITY 320), normal screen ->
# phone-xhdpi-4096. 8m/192m/512m at 0.6 target utilization; it is the only
# phone-* profile with 0.6, and the larger free window means fewer GC pauses,
# which is what a weak CPU needs.
#
# This inherit is NOT optional and is unrelated to Go. It is the only source of
# dalvik.vm.heap* in the tree; without it every app falls back to
# AndroidRuntime.cpp's -Xms4m/-Xmx16m (E-019).
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
# vendor/lineage/config/partner_gms.mk:6-9 would route it to products/gms_go.mk,
# which does not exist here. No GMS Go substitution has ever been active, so the
# low_ram removal above changes nothing about the payload. The explicit guard
# prevents the optional product inherit from silently producing a GMS-free
# image.
WITH_GMS := true
ifeq ($(wildcard vendor/partner_gms/products/gms.mk),)
$(error Missing vendor/partner_gms/products/gms.mk; import the pinned NikGapps omni payload first)
endif
$(call inherit-product, vendor/lineage/config/common_full_phone.mk)

# Huawei AppGallery and HMS Core, at the owner's request. Guarded the same way
# as the GMS payload above: the tree carries the makefile, the binaries live in
# their own repository, and a missing import should fail the build loudly rather
# than silently produce an image without them.
ifeq ($(wildcard vendor/huawei/hms/products/huawei.mk),)
$(error Missing vendor/huawei/hms/products/huawei.mk; import the Huawei payload first)
endif
$(call inherit-product, vendor/huawei/hms/products/huawei.mk)

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

# The 3.18 kernel has neither CONFIG_MEMCG nor PSI, so per-app memory cgroups do
# not exist and lmkd cannot run its userspace killer. lmkd probes
# /sys/module/lowmemorykiller/parameters/minfree for write access
# (system/core/lmkd/lmkd.c:1968) -- an access(W_OK) test that always succeeds
# here -- and takes the in-kernel path, so every ro.lmk.* is read and then never
# consumed. Do not add any.
# NOTE (PSI): lmkd needs the *writable trigger* interface, upstream 5.2, not the
# read-only /proc/pressure of 4.20. Neither exists here.
#
# The minfree table itself is NOT affected by low_ram either way.
# ProcessList.updateOomLevels() computes it purely from total RAM and display
# area with no low-RAM term, and pushes it through LMK_TARGET, which is one of
# the few lmkd commands with no in-kernel-interface early return. Measured
# before this change and expected unchanged after:
#   minfree 18432,23040,27648,32256,55296,80640
#   adj     0,100,200,250,900,950
# If those move, something other than this edit moved them.
#
# per_app_memcg states what the kernel already forces twice over:
# processgroup.cpp:404 gates on isMemoryCgroupSupported() first, which is false
# with no memory controller mounted, and with low_ram gone the native default
# that both processgroup.cpp and lmkd.c infer from it is already false. Kept as
# documentation of an immutable kernel fact, not as a working override.
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

# Google's client-id base. Deliberately NOT set: vendor/lineage/config/common.mk
# :8-13 falls back to `android-google` when this is empty, and that is the right
# value here. The client ID is a partner attribution string Google recognises
# from a registered OEM agreement; `android-xsh` named a partner that does not
# exist, so every Play Store search referral reported an unknown one. There is
# no upside to inventing a value, and the property must never be set by hand --
# common.mk owns it.
# PRODUCT_GMS_CLIENTID_BASE := android-xsh

# Pin the ART runtime APEX, after every inherit-product above so the `:=` wins.
#
# This variable is in _product_var_list (build/make/core/product.mk:268), so
# inherit-product CONCATENATES it. Two inherited products each setting `false`
# resolved to the two-word string `false false`, and art/Android.mk:346's exact
# string test then selected com.android.runtime.DEBUG on every userdebug tier --
# 130 MB of libartd and dex2oatd, against both setters' intent (E-042). Dropping
# the Android Go inherit removed one setter and fixed it, but incidentally:
# Android 10 has no single-value check for product variables (that landed after
# Q), so any future second setter would silently restore it with no warning.
# State it here once, and the outcome stops depending on who else sets it.
PRODUCT_ART_TARGET_INCLUDE_DEBUG_BUILD := false

PRODUCT_NAME := lineage_k50sv1_64_bsp
PRODUCT_DEVICE := k50sv1_64_bsp
PRODUCT_BRAND := XSH
PRODUCT_MODEL := F212
PRODUCT_MANUFACTURER := XSH
