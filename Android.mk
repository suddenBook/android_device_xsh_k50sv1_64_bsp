LOCAL_PATH := $(call my-dir)

ifneq ($(filter k50sv1_64_bsp,$(TARGET_DEVICE)),)

# Validate device XML, the complete APN table, init scripts and retained DT payloads.
include $(CLEAR_VARS)
LOCAL_MODULE := k50sv1-xml-validation
LOCAL_MODULE_CLASS := ETC
LOCAL_MODULE_TAGS := optional
# This stamp is a build prerequisite, not an installed system file.
LOCAL_UNINSTALLABLE_MODULE := true
include $(BUILD_SYSTEM)/base_rules.mk

# Image builds do not visit droidcore, so attach the stamp to each image goal.
droidcore systemimage vendorimage bootimage recoveryimage: $(LOCAL_BUILT_MODULE)

# Makefile defines the upstream variable later; use its stable output path.
systemimage: $(PRODUCT_OUT)/verified_assembled_framework_manifest.xml

k50sv1_default_apns := vendor/lineage/prebuilt/common/etc/apns-conf.xml
# Follow the command-line device directory when it is linked into Android.
k50sv1_xml_files := $(shell find -H $(LOCAL_PATH) -name '*.xml' -not -path '*/.git/*') \
    $(k50sv1_default_apns)

# ueventd uses a different syntax; recovery init files need checking too.
k50sv1_init_rc_files := $(shell find $(LOCAL_PATH)/rootdir $(LOCAL_PATH)/recovery \
    -name '*.rc' -not -name 'ueventd.rc' -not -path '*/.git/*')
k50sv1_passwd_file := $(call intermediates-dir-for,ETC,passwd)/passwd

k50sv1_prebuilt_dir := $(LOCAL_PATH)/prebuilt
k50sv1_prebuilt_files := $(k50sv1_prebuilt_dir)/SHA256SUMS \
    $(k50sv1_prebuilt_dir)/kernel $(k50sv1_prebuilt_dir)/dtb/stock.dtb \
    $(k50sv1_prebuilt_dir)/recovery_dtbo

k50sv1_fonts_customization := vendor/lineage/prebuilt/common/etc/fonts_customization.xml

$(LOCAL_BUILT_MODULE): PRIVATE_XML_FILES := $(k50sv1_xml_files)
$(LOCAL_BUILT_MODULE): PRIVATE_INIT_RC_FILES := $(k50sv1_init_rc_files)
$(LOCAL_BUILT_MODULE): PRIVATE_PASSWD_FILE := $(k50sv1_passwd_file)
$(LOCAL_BUILT_MODULE): PRIVATE_PREBUILT_DIR := $(k50sv1_prebuilt_dir)
$(LOCAL_BUILT_MODULE): PRIVATE_FONTS_CUSTOMIZATION := $(k50sv1_fonts_customization)
$(LOCAL_BUILT_MODULE): $(k50sv1_xml_files) $(XMLLINT) \
                       $(k50sv1_init_rc_files) $(HOST_INIT_VERIFIER) \
                       $(k50sv1_passwd_file) $(k50sv1_prebuilt_files) \
                       $(k50sv1_fonts_customization)
	@echo "Validating $(words $(PRIVATE_XML_FILES)) device-tree XML files"
	$(hide) $(XMLLINT) --noout $(PRIVATE_XML_FILES)
	@echo "Validating $(words $(PRIVATE_INIT_RC_FILES)) device-tree init rc files"
	$(hide) for rc in $(PRIVATE_INIT_RC_FILES); do \
	    $(HOST_INIT_VERIFIER) $$rc $(PRIVATE_PASSWD_FILE) || exit 1; \
	done
	@echo "Verifying the prebuilt boot artefacts against prebuilt/SHA256SUMS"
	$(hide) (cd $(PRIVATE_PREBUILT_DIR) && sha256sum -c SHA256SUMS)
	@echo "Verifying the upstream fonts_customization.xml carries the harmonyos family"
	$(hide) grep -q 'name="harmonyos"' $(PRIVATE_FONTS_CUSTOMIZATION) || { \
	    echo "$(PRIVATE_FONTS_CUSTOMIZATION) has no harmonyos family; re-run" >&2; \
	    echo "bringup/k50sv1-bringup/tools/apply-upstream-patches.sh" >&2; exit 1; }
	$(hide) mkdir -p $(dir $@) && touch $@

k50sv1_xml_files :=
k50sv1_apn_fragment :=
k50sv1_apn_validator :=
k50sv1_default_apns :=
k50sv1_internal_apns :=
k50sv1_init_rc_files :=
k50sv1_passwd_file :=
k50sv1_prebuilt_dir :=
k50sv1_prebuilt_files :=
k50sv1_fonts_customization :=

include $(call all-makefiles-under,$(LOCAL_PATH))
endif
