LOCAL_PATH := $(call my-dir)

ifneq ($(filter k50sv1_64_bsp,$(TARGET_DEVICE)),)

# Validate every hand-written XML in this device tree, at build time.
#
# An earlier version of this comment said PRODUCT_COPY_FILES "copies bytes and
# checks nothing". That is false on Android 10 and it was the whole stated
# reason for this module: Makefile:34-35 routes every copy whose DESTINATION
# ends in .xml through copy-xml-file-checked, and definitions.mk:2581-2586
# runs $(XMLLINT) on it. A doubled hyphen in a copied XML is already a build
# error without this rule. The overlays and RROs are parsed by aapt2, and
# manifest.xml / compatibility_matrix.xml by assemble_vintf.
#
# Enumerated against the 21 XML files this tree actually contains, that
# accounting leaves EXACTLY ONE residual file:
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

k50sv1_xml_files := $(shell find $(LOCAL_PATH) -name '*.xml' -not -path '*/.git/*')

$(LOCAL_BUILT_MODULE): PRIVATE_XML_FILES := $(k50sv1_xml_files)
$(LOCAL_BUILT_MODULE): $(k50sv1_xml_files) $(XMLLINT)
	@echo "Validating $(words $(PRIVATE_XML_FILES)) device-tree XML files"
	$(hide) $(XMLLINT) --noout $(PRIVATE_XML_FILES)
	$(hide) mkdir -p $(dir $@) && touch $@

k50sv1_xml_files :=

include $(call all-makefiles-under,$(LOCAL_PATH))
endif
