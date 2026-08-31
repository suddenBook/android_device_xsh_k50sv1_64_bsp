PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lineage_k50sv1_64_bsp.mk

# Tiers 1 and 2 are userdebug; tier 3 is user. Both belong in the lunch menu.
# -eng is deliberately absent: build_tiers.mk:39-42 hard-errors on it, because an
# eng image adds ro.secure=0, ro.adb.secure=0, permissive SELinux and
# ro.allow.mock.location=1 that no tier asks for. Listing it here would only
# offer a choice that fails at the next command.
COMMON_LUNCH_CHOICES := \
    lineage_k50sv1_64_bsp-userdebug \
    lineage_k50sv1_64_bsp-user
