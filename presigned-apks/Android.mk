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

k50-install-presigned-jni :=
