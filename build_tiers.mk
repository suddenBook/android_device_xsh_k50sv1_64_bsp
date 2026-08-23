# Three explicit build tiers for this private device port. This file is
# included from both product and board configuration, so keep it idempotent.
ifndef K50SV1_BUILD_TIERS_INCLUDED
K50SV1_BUILD_TIERS_INCLUDED := true

# The default DERIVES from the variant rather than being a constant. A constant
# default of 1 made `lunch lineage_k50sv1_64_bsp-user && m` -- a combo this tree
# advertises in COMMON_LUNCH_CHOICES -- build a `user` image with Tier 1's
# unauthenticated root adb, by doing nothing wrong. Deriving it means the
# advertised combo does the safe thing, and the assertion below still catches
# anyone who sets a tier that contradicts the variant on purpose.
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
K50SV1_RELEASE_SIGNING := true
else
$(error Unsupported K50SV1_BUILD_TIER=$(K50SV1_BUILD_TIER); expected 1, 2, or 3)
endif

endif

# Tier and variant must agree, and the default must not be able to produce a
# permissive-tier `user` image.
#
# K50SV1_BUILD_TIER defaults to 1, which is the RIGHT default for convenience
# and the WRONG one for safety: `lunch lineage_k50sv1_64_bsp-user && m` with the
# variable unset used to build a `user` image carrying WITH_ADB_INSECURE
# (ro.adb.secure=0), service.adb.root=1, persist.sys.usb.config=adb and
# ro.control_privapp_permissions=log. That is precisely the state Tier 3 exists
# to prevent, arrived at by doing nothing wrong. (The permissive cmdline token
# is the one Tier-1 artifact that is inert on a `user` build --
# system/core/init compiles ALLOW_PERMISSIVE_SELINUX=0 unless debuggable -- but
# every other one is live.)
#
# The eng skip is what keeps lunch working: Lineage's lunch discovery parses
# each product once with a temporary eng variant before selecting the requested
# combo, and build/make/core/envsetup.mk defaults an unset variant to eng. The
# wrapper still asserts the real post-lunch variant; this is the second gate, at
# the only place that sees both values.
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
