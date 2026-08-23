LOCAL_PATH := $(call my-dir)

# all-makefiles-under is ONE level deep -- `$(wildcard $(1)/*/Android.mk)`,
# definitions.mk:179-181 -- so the device root's call reaches this file and no
# further. Without this line every overlay under rro/ is invisible to the build,
# and because PRODUCT_ENFORCE_PACKAGES_EXIST is opt-in, naming one in
# PRODUCT_PACKAGES fails SILENTLY: the package simply never installs. That is
# how the HarmonyOS Sans Styles entry was missing from a build that reported
# success. BoardConfig.mk now sets PRODUCT_ENFORCE_PACKAGES_EXIST so a repeat is
# a build error, but this is the line that makes the overlays exist at all.
include $(call all-makefiles-under,$(LOCAL_PATH))
