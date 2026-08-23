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

# framework-res' resource table, and where the assertion records that it ran.
ims_framework_resources := \
    $(call intermediates-dir-for,APPS,framework-res,,COMMON)/package-export.apk
ims_resource_id_stamp := \
    $(call intermediates-dir-for,APPS,ImsService)/framework-resource-ids.stamp

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

# The APK carries raw com.android.internal.R integers that extract-files.sh
# rewrote to Lineage's values. Nothing inside the APK records which resource an
# integer was supposed to name, so a frameworks/base sync that adds or removes
# any bool/ resource shifts them and the IMS stack starts reading unrelated
# flags -- with no error, just a feature that never works. Fail the build
# instead. See ims/framework-resource-ids.txt.
#
# LOCAL_ADDITIONAL_DEPENDENCIES is added before BUILD_PREBUILT so the stamp is
# ordered ahead of the APK's own install rule.
LOCAL_ADDITIONAL_DEPENDENCIES += $(ims_resource_id_stamp)

include $(BUILD_PREBUILT)

# Every path the recipe needs goes through a target-local variable: the recipe
# runs long after this makefile is parsed, and the file clears its own
# ims_* variables at the end.
$(ims_resource_id_stamp): PRIVATE_SCRIPT := $(LOCAL_PATH)/verify-framework-resource-ids.sh
$(ims_resource_id_stamp): PRIVATE_TABLE := $(LOCAL_PATH)/framework-resource-ids.txt
$(ims_resource_id_stamp): PRIVATE_RESOURCES := $(ims_framework_resources)
$(ims_resource_id_stamp): \
        $(LOCAL_PATH)/verify-framework-resource-ids.sh \
        $(LOCAL_PATH)/framework-resource-ids.txt \
        $(ims_framework_resources) \
        $(AAPT2)
	@mkdir -p $(dir $@)
	$(hide) $(PRIVATE_SCRIPT) $(AAPT2) $(PRIVATE_RESOURCES) $(PRIVATE_TABLE)
	$(hide) touch $@

endif

IMS_PREBUILT_APK :=
ims_framework_resources :=
ims_resource_id_stamp :=
