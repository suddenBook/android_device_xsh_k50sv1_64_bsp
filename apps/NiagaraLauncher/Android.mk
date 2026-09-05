LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := NiagaraLauncher
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
LOCAL_SRC_FILES := NiagaraLauncher.apk
LOCAL_CERTIFICATE := PRESIGNED
LOCAL_PRIVILEGED_MODULE := true
LOCAL_DEX_PREOPT := false

# Q's ordinary PRESIGNED path can rewrite the ZIP while handling JNI or
# alignment, invalidating the v2 signature. This supported path copies it
# unchanged. The APK already stores page-aligned JNI with extractNativeLibs=false.
LOCAL_REPLACE_PREBUILT_APK_INSTALLED := $(LOCAL_PATH)/NiagaraLauncher.apk
include $(BUILD_PREBUILT)
