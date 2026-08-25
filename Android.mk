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
# What this module still buys, and the only thing it buys: it validates XML in
# the tree that NOTHING has wired into a build rule yet, and it validates on
# SOURCE path rather than on destination suffix, so a file copied to a
# non-.xml destination is still checked. It is one xmllint over the tree and it
# fires before the copy rules do, which makes the error name the source file.
# Keep it, but do not restate the false premise.
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
# /system/etc/k50sv1-xml-validation. PRODUCT_PACKAGES still forces
# $(LOCAL_BUILT_MODULE) to be built, so the gate keeps working.
LOCAL_UNINSTALLABLE_MODULE := true
include $(BUILD_SYSTEM)/base_rules.mk

k50sv1_xml_files := $(shell find $(LOCAL_PATH) -name '*.xml' -not -path '*/.git/*')

$(LOCAL_BUILT_MODULE): PRIVATE_XML_FILES := $(k50sv1_xml_files)
$(LOCAL_BUILT_MODULE): $(k50sv1_xml_files) $(XMLLINT)
	@echo "Validating $(words $(PRIVATE_XML_FILES)) device-tree XML files"
	$(hide) $(XMLLINT) --noout $(PRIVATE_XML_FILES)
	$(hide) mkdir -p $(dir $@) && touch $@

k50sv1_xml_files :=

include $(call all-makefiles-under,$(LOCAL_PATH))
endif
