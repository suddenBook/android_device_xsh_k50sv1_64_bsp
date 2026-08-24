# Three explicit build tiers for this private device port. This file is
# included from both product and board configuration, so keep it idempotent.
ifndef K50SV1_BUILD_TIERS_INCLUDED
K50SV1_BUILD_TIERS_INCLUDED := true

# Derive the diagnostic/release shape from the variant when no wrapper supplied
# a tier. This prevents a direct user build from inheriting Tier 1 root adb, but
# does not make it a signed release: the wrapper-only guard below is separate.
K50SV1_BUILD_TIER ?= $(if $(filter user,$(TARGET_BUILD_VARIANT)),3,1)

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

# Tier, variant and release pipeline must agree.
#
# Variant-derived Tier 3 prevents debug properties on a direct user build, but
# Android's ordinary build still uses test/dev keys. The real release mapping,
# APEX payload resigning and OTA-trust verification live only in
# tools/run-lineage-build.sh. K50SV1_RELEASE_PIPELINE_ACTIVE is exported only by
# that wrapper; without it a user/Tier-3 parse fails before any build target.
# The user combo is also not advertised in COMMON_LUNCH_CHOICES. Both gates are
# intentional: removing the menu entry alone does not stop an explicit lunch.
#
# The eng skip is what keeps lunch working: Lineage's lunch discovery parses
# each product once with a temporary eng variant before selecting the requested
# combo, and build/make/core/envsetup.mk defaults an unset variant to eng. The
# wrapper asserts the real post-lunch product, variant and device too.
ifneq ($(TARGET_BUILD_VARIANT),eng)
ifeq ($(TARGET_BUILD_VARIANT),user)
ifneq ($(K50SV1_BUILD_TIER),3)
$(error K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER) with TARGET_BUILD_VARIANT=user. Only tier 3 is a user build; tiers 1 and 2 would ship unauthenticated root adb on a release image)
endif
else ifeq ($(K50SV1_BUILD_TIER),3)
$(error K50SV1_BUILD_TIER=3 requires TARGET_BUILD_VARIANT=user, got $(TARGET_BUILD_VARIANT))
endif
endif

# There is deliberately no K50SV1_BUILD_VARIANT here. Nothing in the device
# tree or vendor/lineage read it, and tools/run-lineage-build.sh derives the
# variant from K50SV1_BUILD_TIER itself -- two copies of one tier->variant
# table that can silently diverge. The wrapper is the single source; it then
# asserts TARGET_BUILD_VARIANT after lunch.
