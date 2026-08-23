# Android Q's Soong `android_app_import` installs every prebuilt APK under
# <partition>/app, ignoring `privileged: true` (fixed upstream only in R).
# A privileged app installed outside priv-app silently loses every privileged
# permission, so the MTK IMS APK is defined here with the Make prebuilt rules
# instead, which honour LOCAL_PRIVILEGED_MODULE. This keeps the fix inside the
# device tree; build/soong is left untouched.
#
# setup-makefiles.sh deletes the generated Soong module of the same name.

LOCAL_PATH := $(call my-dir)

IMS_PREBUILT_APK := \
    vendor/xsh/k50sv1_64_bsp/proprietary/system/priv-app/ImsService/ImsService.apk

ifneq ($(wildcard $(IMS_PREBUILT_APK)),)

include $(CLEAR_VARS)
LOCAL_MODULE := ImsService
LOCAL_MODULE_OWNER := xsh
LOCAL_MODULE_TAGS := optional
LOCAL_MODULE_CLASS := APPS
LOCAL_MODULE_SUFFIX := $(COMMON_ANDROID_PACKAGE_SUFFIX)
LOCAL_PREBUILT_MODULE_FILE := $(IMS_PREBUILT_APK)
# extract-files.sh strips META-INF; the phone-UID app is re-signed here with
# the tier's platform certificate so it shares android.uid.phone.
LOCAL_CERTIFICATE := platform
LOCAL_PRIVILEGED_MODULE := true
LOCAL_DEX_PREOPT := true
LOCAL_ENFORCE_USES_LIBRARIES := false
include $(BUILD_PREBUILT)

endif

IMS_PREBUILT_APK :=
