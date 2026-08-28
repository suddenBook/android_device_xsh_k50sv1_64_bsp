LOCAL_PATH := $(call my-dir)

ifneq ($(filter k50sv1_64_bsp,$(TARGET_DEVICE)),)

# Validate every hand-written XML in this device tree, at build time.
#
# An earlier version of this comment said PRODUCT_COPY_FILES "copies bytes and
# checks nothing". That is false on Android 10 and it was the whole stated
# reason for this module: Makefile:35-36 routes every copy whose DESTINATION
# ends in .xml through copy-xml-file-checked, and definitions.mk:2581-2586
# runs $(XMLLINT) on it. A doubled hyphen in a copied XML is already a build
# error without this rule. The overlays and RROs are parsed by aapt2, and
# manifest.xml / compatibility_matrix.xml by assemble_vintf.
#
# After adding the APN fragment, this tree has 22 ordinary XML documents plus
# one intentional one-element-per-line fragment. The ordinary documents are
# handled below with xmllint. The fragment cannot be parsed as one XML document
# and instead gets a stricter APN/TelephonyProvider semantic validator.
# Among the ordinary files, the accounting leaves exactly one residual file:
#
#   permissions/org.lineageos.platform.xml
#
# It is installed by the Soong prebuilt_etc in permissions/Android.bp, and
# prebuilt_etc is a plain copy rule -- there is no xmllint anywhere in the
# Soong etc module. Every other file is already covered:
#   configs/*.xml (8) + permissions/privapp-permissions-mtk-ims.xml +
#   permissions/handheld_core_hardware.xml + permissions/
#   android.software.nfc.beam.xml  -> PRODUCT_COPY_FILES with a .xml
#                                     destination -> copy-xml-file-checked
#   manifest.xml, compatibility_matrix.xml -> assemble_vintf
#   overlay/**.xml (4), rro/HarmonyOSSansFont/**.xml (3) -> aapt2
#
# So this module is not the broad safety net the old comment described. It is
# a one-file backstop plus a cheap re-check of the rest, and it validates on
# SOURCE path rather than destination suffix, so a file later copied to a
# non-.xml destination stays covered. That is worth one xmllint invocation;
# it is not worth believing a claim this comment can no longer support. If
# permissions/ ever grows a second prebuilt_etc XML, this module is what
# catches it.
#
# The failure it guards against is real and has happened once here: for
# permissions/handheld_core_hardware.xml a parse error means SystemConfig
# abandons the file and the device declares NO hardware features at all.
include $(CLEAR_VARS)
LOCAL_MODULE := k50sv1-xml-validation
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
# Not a shipped file. Without this, base_rules.mk:204/:292 give the module an
# installed path under $(TARGET_OUT_ETC) and the build stages a zero-byte
# /system/etc/k50sv1-xml-validation.
LOCAL_UNINSTALLABLE_MODULE := true
include $(BUILD_SYSTEM)/base_rules.mk

# ...but the sentence that used to end the comment above -- "PRODUCT_PACKAGES
# still forces $(LOCAL_BUILT_MODULE) to be built, so the gate keeps working" --
# was false, and this module had therefore NEVER RUN.
#
# base_rules.mk:848-857 wraps the ALL_MODULES.<m>.INSTALLED assignment in
# `ifneq (true,$(LOCAL_UNINSTALLABLE_MODULE))`, so for this module that
# variable stays empty. main.mk's product-installed-files (:1098-1126) turns
# PRODUCT_PACKAGES into files with `$(call module-installed-files, ...)`, and
# definitions.mk:660-662 defines that as exactly
# `$(ALL_MODULES.$(module).INSTALLED)` -- empty here. The result feeds
# modules_to_install (main.mk:1414) and thence droidcore (main.mk:1590).
# An uninstallable module contributes nothing at any step, so listing it in
# PRODUCT_PACKAGES asks for nothing to be built.
#
# Measured, not deduced: a completed build's
# out/target/product/k50sv1_64_bsp/obj/ETC/ holds 714 module directories and
# no k50sv1-xml-validation_intermediates. Zero XML has ever been linted here.
#
# The fix is to name the built file as a prerequisite of a goal the build
# actually walks. droidcore is that goal (main.mk:1589-1590; droid ->
# droid_targets -> droidcore, main.mk:1768), it is the same hook AOSP uses for
# its own non-installable build-time checks -- see
# build/make/target/product/gsi/Android.mk:38 `droidcore: check-vndk-list` and
# build/make/core/tasks/module-info.mk:25 -- and it must come AFTER
# base_rules.mk, which is what defines LOCAL_BUILT_MODULE.
#
# PRODUCT_PACKAGES still lists the module in device.mk. That is deliberate and
# it is not the build trigger: it is what makes PRODUCT_ENFORCE_PACKAGES_EXIST
# (BoardConfig.mk) fail the build if this Android.mk ever stops being parsed.
droidcore: $(LOCAL_BUILT_MODULE)

k50sv1_apn_fragment := $(LOCAL_PATH)/configs/apns-conf.xml
k50sv1_apn_validator := $(LOCAL_PATH)/tools/validate-custom-apns.py
k50sv1_default_apns := vendor/lineage/prebuilt/common/etc/apns-conf.xml
k50sv1_internal_apns := frameworks/base/core/res/res/xml/apns.xml
k50sv1_xml_files := $(filter-out $(k50sv1_apn_fragment), \
    $(shell find $(LOCAL_PATH) -name '*.xml' -not -path '*/.git/*'))

# The same module also runs host_init_verifier over every hand-written init rc
# in this tree, and that is NOT redundant with the build's own check.
#
# Makefile:39 gates that check on
#     $(filter init%rc,$(notdir $(_dest)))$(filter %/etc/init,$(dir $(_dest)))
# and $(dir) returns a path WITH a trailing slash, so `%/etc/init` can never
# match. Only the basename half ever fires. Measured in the generated ninja:
# init.sensors.rc gets "Copy init script:" plus host_init_verifier, while
# android.hardware.sensors@2.0-service.rc, vendor.mediatek.hardware.mtkpower@
# 1.0-service.rc, lbs_hidl_service.rc, netdagent.rc and zz_vendor.media.omx.rc
# get a plain "Copy:" and no syntax check at all. This device tree owns five rc
# files whose names do not start with "init", which is exactly the class the
# upstream filter misses.
#
# rootdir/vendor/ueventd.rc is excluded on purpose: it is a ueventd config, not
# an init script, and host_init_verifier would reject every line of it.
#
# The passwd file is the same intermediate copy-init-script-file-checked uses
# (definitions.mk:2557-2558); host_init_verifier needs it to resolve the
# user/group names in `service` blocks.
k50sv1_init_rc_files := $(shell find $(LOCAL_PATH)/rootdir -name '*.rc' \
    -not -name 'ueventd.rc' -not -path '*/.git/*')
k50sv1_passwd_file := $(call intermediates-dir-for,ETC,passwd)/passwd

$(LOCAL_BUILT_MODULE): PRIVATE_XML_FILES := $(k50sv1_xml_files)
$(LOCAL_BUILT_MODULE): PRIVATE_APN_FRAGMENT := $(k50sv1_apn_fragment)
$(LOCAL_BUILT_MODULE): PRIVATE_APN_VALIDATOR := $(k50sv1_apn_validator)
$(LOCAL_BUILT_MODULE): PRIVATE_DEFAULT_APNS := $(k50sv1_default_apns)
$(LOCAL_BUILT_MODULE): PRIVATE_INTERNAL_APNS := $(k50sv1_internal_apns)
$(LOCAL_BUILT_MODULE): PRIVATE_INIT_RC_FILES := $(k50sv1_init_rc_files)
$(LOCAL_BUILT_MODULE): PRIVATE_PASSWD_FILE := $(k50sv1_passwd_file)
$(LOCAL_BUILT_MODULE): $(k50sv1_xml_files) $(XMLLINT) \
                       $(k50sv1_apn_fragment) $(k50sv1_apn_validator) \
                       $(k50sv1_default_apns) $(k50sv1_internal_apns) \
                       $(k50sv1_init_rc_files) $(HOST_INIT_VERIFIER) \
                       $(k50sv1_passwd_file)
	@echo "Validating $(words $(PRIVATE_XML_FILES)) device-tree XML files"
	$(hide) $(XMLLINT) --noout $(PRIVATE_XML_FILES)
	@echo "Validating the device APN fragment and merged database identities"
	$(hide) python $(PRIVATE_APN_VALIDATOR) $(PRIVATE_DEFAULT_APNS) \
	    $(PRIVATE_APN_FRAGMENT) $(PRIVATE_INTERNAL_APNS)
	@echo "Validating $(words $(PRIVATE_INIT_RC_FILES)) device-tree init rc files"
	$(hide) for rc in $(PRIVATE_INIT_RC_FILES); do \
	    $(HOST_INIT_VERIFIER) $$rc $(PRIVATE_PASSWD_FILE) || exit 1; \
	done
	$(hide) mkdir -p $(dir $@) && touch $@

k50sv1_xml_files :=
k50sv1_apn_fragment :=
k50sv1_apn_validator :=
k50sv1_default_apns :=
k50sv1_internal_apns :=
k50sv1_init_rc_files :=
k50sv1_passwd_file :=

include $(call all-makefiles-under,$(LOCAL_PATH))
endif
