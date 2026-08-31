# k50sv1 icon pack.
#
# Trebuchet on LineageOS 17.1 has first-class icon-pack support -- an
# IconPackStore backed by the com.android.launcher3.prefs shared preference
# `pref_iconPackPackage`, a picker at Home settings -> Icon pack, and a
# BUILD-TIME DEFAULT in R.string.icon_pack_default_pkg. So there is nothing to
# fork: a pack only has to be installed and named. The default is pointed at
# this package by overlay/packages/apps/Trebuchet/quickstep/res/values/
# lineage_config.xml, which is the one path that reaches the launcher APK
# without also changing SystemUI and PermissionController (both link the same
# iconloaderlib).
#
# WHY THIS IS BUILT HERE RATHER THAN SHIPPED AS THE VENDOR APK. The two icon
# packs the owner supplied carry the same 239-entry appfilter, and it maps
# exactly ONE of this ROM's 20 launcher activities -- it is a mapping for
# Chinese consumer apps. Installing either APK as-is themes Contacts and nothing
# else. The art is good; the mapping was the missing half, and a mapping cannot
# be edited inside someone else's signed APK. This module carries the art for
# the icons actually used plus a hand-authored appfilter.
#
# ART PROVENANCE. The 161 adaptive icons and the handful of legacy PNGs come
# from com.origin.adaptive.icon 0.5.3 and com.origin.icon.pack 0.5.3, two APKs
# the owner supplied, both signed by CN=WeiJun and both built on Jahir
# Fiquitiva's Blueprint dashboard with Play Billing and licence-check code --
# i.e. a paid icon application. The owner asked for this artwork on their own
# handset and accepted that framing; THIS IMAGE IS A PERSONAL BUILD AND IS NOT
# FOR REDISTRIBUTION. If that ever changes, the artwork has to be replaced or
# licensed, and this module is the only thing that would need to change.
#
# Resource-only, so: no LOCAL_SRC_FILES, no LOCAL_CERTIFICATE override (it is
# signed with the build's own key like any other in-tree package), no dex, and
# nothing for dexopt to do.
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)

LOCAL_MODULE_TAGS := optional
LOCAL_PACKAGE_NAME := K50sv1IconPack
LOCAL_SDK_VERSION := current
LOCAL_USE_AAPT2 := true
LOCAL_RESOURCE_DIR := $(LOCAL_PATH)/res
LOCAL_PRODUCT_MODULE := true

include $(BUILD_PACKAGE)
