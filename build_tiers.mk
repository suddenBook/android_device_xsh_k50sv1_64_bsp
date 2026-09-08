# Shared by product and board configuration; initialize tier booleans once.
ifndef K50SV1_BUILD_TIERS_INCLUDED
K50SV1_BUILD_TIERS_INCLUDED := true

# Tier 2 is a discovery placeholder. Every real build must select a tier.
K50SV1_BUILD_TIER_EXPLICIT := $(if $(strip $(K50SV1_BUILD_TIER)),true,false)
K50SV1_BUILD_TIER := $(if $(strip $(K50SV1_BUILD_TIER)),$(strip $(K50SV1_BUILD_TIER)),2)

K50SV1_SELINUX_PERMISSIVE := false
K50SV1_ADB_ENABLED := false
K50SV1_ADB_ROOT := false
K50SV1_ADB_INSECURE := false
K50SV1_RELEASE_SIGNING := false

ifeq ($(K50SV1_BUILD_TIER),1)
K50SV1_SELINUX_PERMISSIVE := true
K50SV1_ADB_ENABLED := true
K50SV1_ADB_ROOT := true
K50SV1_ADB_INSECURE := true
else ifeq ($(K50SV1_BUILD_TIER),2)
K50SV1_ADB_ENABLED := true
K50SV1_ADB_ROOT := true
K50SV1_ADB_INSECURE := true
else ifeq ($(K50SV1_BUILD_TIER),3)
ifneq ($(K50SV1_RELEASE_PIPELINE_ACTIVE),true)
$(error Tier 3 is wrapper-only: use K50SV1_BUILD_TIER=3 work/k50sv1-bringup/tools/run-lineage-build.sh so target-files are release-signed and verified)
endif
K50SV1_RELEASE_SIGNING := true
else
$(error Unsupported K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER); expected 1, 2, or 3)
endif

endif

# Lunch sets CALLED_FROM_SETUP; a real product-config pass also sets
# WRITE_SOONG_VARIABLES. An eng default during lunch must not authorize an eng build.
K50SV1_LUNCH_DISCOVERY :=
ifeq ($(CALLED_FROM_SETUP),true)
ifneq ($(WRITE_SOONG_VARIABLES),true)
K50SV1_LUNCH_DISCOVERY := true
endif
endif

ifeq ($(K50SV1_BUILD_TIER_EXPLICIT),false)
ifeq ($(K50SV1_LUNCH_DISCOVERY),)
$(error K50SV1_BUILD_TIER is required for every real build. Select 1 (permissive/root diagnostics), 2 (enforcing/root diagnostics), or 3 (wrapper-only release-signed user build); there is no insecure default)
endif
endif

# Diagnostic tiers require userdebug; the release tier requires user.
ifeq ($(TARGET_BUILD_VARIANT),eng)
ifeq ($(K50SV1_LUNCH_DISCOVERY),)
$(error TARGET_BUILD_VARIANT=eng is not one of this device's build tiers. Tier 1 and 2 are userdebug, tier 3 is user; an eng image adds ro.secure=0, ro.adb.secure=0, permissive SELinux and ro.allow.mock.location=1 that no tier asks for. Use lineage_k50sv1_64_bsp-userdebug for tiers 1 and 2, or K50SV1_BUILD_TIER=3 work/k50sv1-bringup/tools/run-lineage-build.sh for tier 3. This check does not fire during lunch discovery)
endif
else ifeq ($(TARGET_BUILD_VARIANT),user)
ifneq ($(K50SV1_BUILD_TIER),3)
$(error K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER) with TARGET_BUILD_VARIANT=user. Only tier 3 is a user build; tiers 1 and 2 would ship unauthenticated root adb on a release image)
endif
else ifeq ($(K50SV1_BUILD_TIER),3)
$(error K50SV1_BUILD_TIER=3 requires TARGET_BUILD_VARIANT=user, got $(TARGET_BUILD_VARIANT))
endif

# Prevent staged files crossing tiers. The current wrapper uses one OUT_DIR per tier.
ifeq ($(K50SV1_LUNCH_DISCOVERY),)
ifndef K50SV1_TIER_STAMP_CHECKED
K50SV1_TIER_STAMP_CHECKED := true
K50SV1_TIER_STAMP_FILE := $(if $(strip $(OUT_DIR)),$(strip $(OUT_DIR))/k50sv1_build_tier)
ifneq ($(K50SV1_TIER_STAMP_FILE),)
K50SV1_TIER_STAMP_PREV := $(strip $(shell cat $(K50SV1_TIER_STAMP_FILE) 2>/dev/null))
ifneq ($(K50SV1_TIER_STAMP_PREV),)
ifneq ($(K50SV1_TIER_STAMP_PREV),$(K50SV1_BUILD_TIER))
$(error This output tree was last built as tier $(K50SV1_TIER_STAMP_PREV) and you are asking for tier $(K50SV1_BUILD_TIER). A tier switch is not incremental: PRODUCT_COPY_FILES entries that a later tier removes stay staged in $(OUT_DIR), so a tier-3 image built this way would still contain the legacy ePDG/strongSwan closure. Remove $(OUT_DIR) and build again -- work/k50sv1-bringup/tools/run-lineage-build.sh does this for you)
endif
endif
$(shell mkdir -p $(dir $(K50SV1_TIER_STAMP_FILE)) && echo $(K50SV1_BUILD_TIER) > $(K50SV1_TIER_STAMP_FILE))
endif
endif
endif
