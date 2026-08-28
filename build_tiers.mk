# Three explicit build tiers for this private device port. This file is
# included from both product and board configuration, so keep it idempotent.
ifndef K50SV1_BUILD_TIERS_INCLUDED
K50SV1_BUILD_TIERS_INCLUDED := true

# A real build must name its tier explicitly. The value 2 below is only a safe
# placeholder while lunch/get_build_var discovers the product; a guard after
# K50SV1_LUNCH_DISCOVERY is derived rejects it before any real Soong/Kati build
# when the caller omitted K50SV1_BUILD_TIER. Never silently default to Tier 1:
# that tier deliberately enables permissive SELinux and unauthenticated root
# ADB. `:=`, not `?=`, keeps the first include and all derived booleans stable.
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
# The eng skip is what keeps lunch working. The mechanism, corrected -- the old
# comment said "Lineage's lunch discovery parses each product once", and it
# parses exactly ONE, the requested one (product_config.mk:217-229 imports
# $(current_product_makefile); the all-products branch needs the product-graph
# or dump-products goal). What is true is the variant: check_product()
# (build/make/envsetup.sh:152-156) re-invokes get_build_var with
# TARGET_BUILD_VARIANT= forced EMPTY, and envsetup.mk:93-94 then defaults an
# unset variant to eng. So this file is parsed with variant=eng during every
# lunch, whatever combo was actually asked for.
#
# That skip was an UNDECLARED FOURTH TIER. `lunch lineage_k50sv1_64_bsp-eng` is
# a legal combo, it reaches this file with TARGET_BUILD_VARIANT=eng, the whole
# agreement check was skipped, and the build succeeded -- producing ro.secure=0,
# ro.adb.secure=0, permissive SELinux and ro.allow.mock.location=1 from AOSP's
# own eng defaults. None of tiers 1-3 describes that shape, nothing chose it,
# and nothing said so. Worse, it also swallowed the tier-3 check: an eng build
# with K50SV1_BUILD_TIER=3 and the pipeline flag set passed silently.
#
# Discovery IS distinguishable from a real build, but NOT by CALLED_FROM_SETUP
# alone -- that was the obvious answer and it is wrong. Verified in
# build/soong/ui/build/:
#   dumpvars.go:83      cmd.Environment.Set("CALLED_FROM_SETUP", "true")
#   dumpvars.go:84-86   ...Set("WRITE_SOONG_VARIABLES", "true") -- only when the
#                       caller passed write_soong_vars
#   dumpvars.go:55      dumpMakeVars(..., false)  <- DumpMakeVars, i.e. lunch /
#                       get_build_var / TAB completion
#   dumpvars.go:219     dumpMakeVars(..., true)   <- runMakeProductConfig, i.e.
#                       the product-config phase of a REAL build (build.go:
#                       165-168, run on every `m`)
#   kati.go:120-153     the actual build pass, -f main.mk, envFunc is empty --
#                       neither variable is set
# So CALLED_FROM_SETUP=true is ALSO set on every `m`, and guarding on it alone
# would have moved the error from parse time to the kati pass, after Soong had
# already run to completion. The pair is what separates the three cases:
#
#   pass                                CALLED_FROM_SETUP  WRITE_SOONG_VARIABLES
#   lunch / get_build_var / TAB              true                 unset
#   real build, product-config phase         true                 true
#   real build, kati phase (main.mk)         unset                unset
#
# CALLED_FROM_SETUP is .KATI_READONLY (config.mk:28-29) so a makefile cannot
# fake it; WRITE_SOONG_VARIABLES is read only by soong_config.mk:18 and
# dex_preopt_config.mk:85, both included at config.mk:1170, long after this
# file, so it is still pristine here.
#
# Rejected alternative: $(origin TARGET_BUILD_VARIANT), which is `file` in the
# check_product pass (envsetup.mk:94 assigns it) and `environment` in an
# explicit -eng lunch. It would fail at lunch rather than at `m`, which is
# nicer, but it depends on ckati reproducing GNU make's $(origin) for a
# variable exported EMPTY, which is undocumented in kati. Not worth it.
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

# There is deliberately no K50SV1_BUILD_VARIANT here. Nothing in the device
# tree or vendor/lineage read it, and tools/run-lineage-build.sh derives the
# variant from K50SV1_BUILD_TIER itself -- two copies of one tier->variant
# table that can silently diverge. The wrapper is the single source; it then
# asserts TARGET_BUILD_VARIANT after lunch.
