LOCAL_PATH := $(call my-dir)

# HarmonyOS Sans, as a selectable font in Settings -> Styles.
#
# The .ttf files go to /product/fonts because that is the directory
# SystemFonts.java:313 passes as customFontsDir alongside
# /product/etc/fonts_customization.xml. Both are hardcoded.
#
# BUILD_PREBUILT rather than PRODUCT_COPY_FILES so the module can be named in
# LOCAL_REQUIRED_MODULES and so the file participates in the module graph,
# matching how external/google-fonts/*/Android.mk installs Lato and Rubik.

define k50sv1-font
$(eval include $(CLEAR_VARS)) \
$(eval LOCAL_MODULE := $(1)) \
$(eval LOCAL_SRC_FILES := $(1)) \
$(eval LOCAL_MODULE_CLASS := ETC) \
$(eval LOCAL_MODULE_TAGS := optional) \
$(eval LOCAL_MODULE_PATH := $(TARGET_OUT_PRODUCT)/fonts) \
$(eval LOCAL_PRODUCT_MODULE := true) \
$(eval include $(BUILD_PREBUILT))
endef

$(foreach f,HarmonyOSSans-Regular.ttf HarmonyOSSans-Italic.ttf,$(call k50sv1-font,$(f)))

# The replacement for vendor/lineage/prebuilt/common/etc/fonts_customization.xml.
# BoardConfig.mk removes Lineage's module from PRODUCT_PACKAGES so that this one
# is the only writer of that path; see the comment there.
include $(CLEAR_VARS)
LOCAL_MODULE := k50sv1-fonts_customization.xml
LOCAL_MODULE_STEM := fonts_customization.xml
LOCAL_SRC_FILES := fonts_customization.xml
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_PATH := $(TARGET_OUT_PRODUCT)/etc
LOCAL_PRODUCT_MODULE := true
LOCAL_REQUIRED_MODULES := \
    HarmonyOSSans-Regular.ttf \
    HarmonyOSSans-Italic.ttf
include $(BUILD_PREBUILT)
