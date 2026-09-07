LOCAL_PATH := $(call my-dir)

# Q does not extract JNI from bundled system apps at boot. Install each entry
# beside its unchanged APK, with normal build dependencies and file accounting.
# $(1): instruction set; $(2): path inside LOCAL_PREBUILT_MODULE_FILE.
define k50-install-presigned-jni
$(dir $(LOCAL_INSTALLED_MODULE))lib/$(1)/$(notdir $(2)): $(LOCAL_PREBUILT_MODULE_FILE)
	@echo "Extract presigned JNI: $$@"
	$$(hide) mkdir -p $$(dir $$@)
	$$(hide) if unzip -p "$$<" "$(2)" >"$$@.tmp"; then \
	    mv -f "$$@.tmp" "$$@"; \
	else \
	    rm -f "$$@.tmp"; exit 1; \
	fi
$(LOCAL_INSTALLED_MODULE): $(dir $(LOCAL_INSTALLED_MODULE))lib/$(1)/$(notdir $(2))
ALL_MODULES.$(LOCAL_MODULE).INSTALLED += $(dir $(LOCAL_INSTALLED_MODULE))lib/$(1)/$(notdir $(2))
endef

include $(CLEAR_VARS)
LOCAL_MODULE := K50CtsShimPrivPrebuilt
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_SUFFIX := .apk
LOCAL_MODULE_TAGS := optional
LOCAL_PRIVILEGED_MODULE := true
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_DEX_PREOPT := false
LOCAL_MULTILIB := both
LOCAL_OVERRIDES_PACKAGES := CtsShimPrivPrebuilt
LOCAL_PREBUILT_MODULE_FILE := frameworks/base/packages/CtsShim/apk/arm/CtsShimPriv.apk
LOCAL_REPLACE_PREBUILT_APK_INSTALLED := $(LOCAL_PREBUILT_MODULE_FILE)
include $(BUILD_PREBUILT)
$(eval $(call k50-install-presigned-jni,arm64,lib/arm64-v8a/libshim_jni.so))
$(eval $(call k50-install-presigned-jni,arm,lib/armeabi-v7a/libshim_jni.so))

# These wrappers exist only with the inherited MindTheGapps payload. Once the
# payload is present, a missing source APK remains a build error.
ifneq ($(wildcard vendor/gapps/arm64/arm64-vendor.mk),)
include $(CLEAR_VARS)
LOCAL_MODULE := K50SetupWizardPrebuilt
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_SUFFIX := .apk
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_OWNER := gapps
LOCAL_PRIVILEGED_MODULE := true
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_DEX_PREOPT := false
LOCAL_MULTILIB := 64
LOCAL_OVERRIDES_PACKAGES := SetupWizardPrebuilt Provision
LOCAL_PREBUILT_MODULE_FILE := vendor/gapps/arm64/proprietary/priv-app/SetupWizardPrebuilt/SetupWizardPrebuilt.apk
LOCAL_REPLACE_PREBUILT_APK_INSTALLED := $(LOCAL_PREBUILT_MODULE_FILE)
include $(BUILD_PREBUILT)
$(eval $(call k50-install-presigned-jni,arm64,lib/arm64-v8a/libbarhopper.so))

include $(CLEAR_VARS)
LOCAL_MODULE := K50Velvet
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_SUFFIX := .apk
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_OWNER := gapps
LOCAL_PRIVILEGED_MODULE := true
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_DEX_PREOPT := false
LOCAL_MULTILIB := both
LOCAL_OVERRIDES_PACKAGES := Velvet
LOCAL_PREBUILT_MODULE_FILE := vendor/gapps/arm64/proprietary/priv-app/Velvet/Velvet.apk
LOCAL_REPLACE_PREBUILT_APK_INSTALLED := $(LOCAL_PREBUILT_MODULE_FILE)
include $(BUILD_PREBUILT)
$(foreach lib, \
    libagsa-annotations.so \
    libbrotli.so \
    libcronet.72.0.3626.14.so \
    libframesequence.so \
    libgoogle_speech_jni.so \
    libgoogle_speech_micro_jni.so \
    liblens_vision.so \
    libnativecrashreporter.so \
    liboffline_actions_jni.so \
    libsbcdecoder_jni.so, \
    $(eval $(call k50-install-presigned-jni,arm64,lib/arm64-v8a/$(lib))))
# The signed APK puts an AArch64 placeholder in this ABI directory. Preserve
# its original path and bytes; it is not an ARM32 library (see README.md).
$(eval $(call k50-install-presigned-jni,arm,lib/armeabi-v7a/libmultiarch_dummy.so))
endif

k50-install-presigned-jni :=
