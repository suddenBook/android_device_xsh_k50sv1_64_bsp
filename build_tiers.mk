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
K50SV1_SELINUX_PERMISSIVE := true
K50SV1_ADB_ENABLED := true
K50SV1_ADB_ROOT := true
K50SV1_ADB_INSECURE := true
else ifeq ($(K50SV1_BUILD_TIER),2)
K50SV1_ADB_ENABLED := true
K50SV1_ADB_ROOT := true
K50SV1_ADB_INSECURE := true
else ifeq ($(K50SV1_BUILD_TIER),3)
K50SV1_RELEASE_SIGNING := true
else
$(error Unsupported K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER); expected 1, 2, or 3)
endif

endif

# Do not reject TARGET_BUILD_VARIANT here. Lineage's lunch discovery parses
# each product once with a temporary eng variant before selecting the requested
# combo. The authoritative wrapper validates the real post-lunch variant.

# There is deliberately no K50SV1_BUILD_VARIANT here. Nothing in the device
# tree or vendor/lineage read it, and tools/run-lineage-build.sh derives the
# variant from K50SV1_BUILD_TIER itself -- two copies of one tier->variant
# table that can silently diverge. The wrapper is the single source; it then
# asserts TARGET_BUILD_VARIANT after lunch.
