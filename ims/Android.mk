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
# LOCAL_ENFORCE_USES_LIBRARIES is deliberately left UNSET, not set to
# "false". build/make/core/clear_vars.mk:86 initialises it empty and
# dex_preopt_odex_install.mk:108 treats empty as "auto"; the literal string
# false is non-empty, and add_json_bool emits JSON true for any non-empty
# value. Setting it to false therefore ENABLES uses-library enforcement,
# after which Soong asks for a class-loader-context path for
# org.apache.http.legacy.impl that Make never puts in LibraryPaths (it only
# adds org.apache.http.legacy), and dexpreopt_gen dies with
#   error: unknown library path for "org.apache.http.legacy.impl"
# The APK's five <uses-library> entries are all required="false" and none of
# them is shipped, so the runtime class-loader context is empty and matches
# an odex built without one.
include $(BUILD_PREBUILT)

endif

IMS_PREBUILT_APK :=
