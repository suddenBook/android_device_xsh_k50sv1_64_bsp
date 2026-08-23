# Three explicit build tiers for this private device port. This file is
# included from both product and board configuration, so keep it idempotent.
ifndef K50SV1_BUILD_TIERS_INCLUDED
K50SV1_BUILD_TIERS_INCLUDED := true

K50SV1_BUILD_TIER ?= 1

K50SV1_SELINUX_PERMISSIVE := false
K50SV1_ADB_ENABLED := false
K50SV1_ADB_ROOT := false
K50SV1_ADB_INSECURE := false
K50SV1_RELEASE_SIGNING := false

ifeq ($(K50SV1_BUILD_TIER),1)
K50SV1_BUILD_VARIANT := userdebug
K50SV1_SELINUX_PERMISSIVE := true
K50SV1_ADB_ENABLED := true
K50SV1_ADB_ROOT := true
K50SV1_ADB_INSECURE := true
else ifeq ($(K50SV1_BUILD_TIER),2)
K50SV1_BUILD_VARIANT := userdebug
K50SV1_ADB_ENABLED := true
K50SV1_ADB_ROOT := true
K50SV1_ADB_INSECURE := true
else ifeq ($(K50SV1_BUILD_TIER),3)
K50SV1_BUILD_VARIANT := user
K50SV1_RELEASE_SIGNING := true
else
$(error Unsupported K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER); expected 1, 2, or 3)
endif

endif

# Validate on every include. Some Android build entry points parse product and
# board configuration in different orders, and TARGET_BUILD_VARIANT may only
# be populated by the later include.
ifneq ($(strip $(TARGET_BUILD_VARIANT)),)
ifneq ($(TARGET_BUILD_VARIANT),$(K50SV1_BUILD_VARIANT))
$(error K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER) requires $(K50SV1_BUILD_VARIANT), not $(TARGET_BUILD_VARIANT))
endif
endif
