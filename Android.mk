LOCAL_PATH := $(call my-dir)

ifneq ($(filter k50sv1_64_bsp,$(TARGET_DEVICE)),)

# Validate every hand-written XML in this device tree, at build time.
#
# Most of them ship through PRODUCT_COPY_FILES, which copies bytes and checks
# nothing. That is fine until a comment picks up a doubled hyphen, which is
# illegal inside an XML comment, and then the file still installs, XmlPullParser throws at runtime,
# and the failure surfaces somewhere unrecognisable. For
# permissions/handheld_core_hardware.xml that means SystemConfig aborts the file
# and the device declares NO hardware features at all.
#
# This has already happened once, in an edit that looked purely editorial. One
# xmllint over the tree costs nothing and turns it into a build error.
include $(CLEAR_VARS)
LOCAL_MODULE := k50sv1-xml-validation
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
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
