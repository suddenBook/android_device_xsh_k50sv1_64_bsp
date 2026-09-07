#!/usr/bin/env bash
#
# Re-apply the one change this device needs in vendor/lineage.
#
# fonts_customization.xml really is read from ONE hardcoded path,
# SystemFonts.java:313, so a device copy cannot sit alongside upstream's.
#
# APNs are mostly different. Lineage's existing APN module has a
# CUSTOM_APNS_FILE merge hook, so the device owns its ten IMS rows as an
# ADDITIVE fragment while Lineage's file stays the base. Do not reintroduce the
# historical whole-file APN replacement here.
#
# Seven rows of that base still have to be patched, because the merge hook can
# only append. In apns-conf.xml an <apn> with no type= attribute becomes
# TYPE_ALL, which includes ims, and TelephonyProvider UNIONS the type columns
# of rows that share an APN identity (mergeFieldsAndUpdateDb, "Merge the 2
# types"). So the untyped China Mobile/Unicom WAP rows made cmwap, 3gwap and
# uniwap claim the ims type, and they sort ahead of the appended ims row, so
# DcTracker.buildWaitingApns() handed the IMS PDN a WAP APN with an HTTP proxy.
# Measured on the handset: every IMS PDN setup went out as APN 3gwap and came
# back mFailCause=31, forever; the device's own ims APN was never once used
# (E-181). The fix is one type= attribute on each of the seven rows, matching
# the already-typed sibling row for the same APN. It cannot be done from the
# device tree: custom_apns.py only replaces by carrier NAME, and the offending
# rows share a name with each other.
#
# There is still no device-tree-only replacement for the font file:
# base_rules.mk:505-512 emits an install rule for every parsed module, so a
# second writer of the same output path is a ckati "overriding commands" hard
# error. The measured failure was:
#
#   base_rules.mk:510: error: overriding commands for target
#     `.../product/etc/fonts_customization.xml'   (module vs module)
#
# Filtering PRODUCT_PACKAGES does not help: it removes the module from the
# install SET, which is computed later, and the rule is already emitted.
# LOCAL_OVERRIDES_MODULES is rejected for ETC (base_rules.mk:342-352), and a
# same-named module is a duplicate-definition error.
#
# `repo sync` will revert the font change. Run this afterwards. Pass --check to
# assert the font delta, the clean Lineage APN base, and the device APN merge
# without changing either checkout; the build wrapper uses that mode as a
# mandatory source preflight.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM="${HERE}/../upstream"
LINEAGE="${HERE}/../../../lineage-17.1"
VENDOR_LINEAGE="${LINEAGE}/vendor/lineage"
DEVICE="${LINEAGE}/device/xsh/k50sv1_64_bsp"
APN_DEFAULT_RELATIVE="prebuilt/common/etc/apns-conf.xml"
APN_DEFAULT="${VENDOR_LINEAGE}/${APN_DEFAULT_RELATIVE}"
APN_FRAGMENT="${DEVICE}/configs/apns-conf.xml"
APN_VALIDATOR="${DEVICE}/tools/validate-custom-apns.py"
APN_INTERNAL="${LINEAGE}/frameworks/base/core/res/res/xml/apns.xml"
APN_MERGE_TOOL="${VENDOR_LINEAGE}/tools/custom_apns.py"
APN_MERGE_TOOL_RELATIVE="vendor/lineage/tools/custom_apns.py"
PYTHON2="${LINEAGE}/prebuilts/python/linux-x86/2.7.5/bin/python2.7"
APN_DEFAULT_PATCH="${UPSTREAM}/apns-conf.xml.patch"
FONT_PATCH="${UPSTREAM}/fonts_customization.xml.patch"
FONT_RELATIVE="prebuilt/common/etc/fonts_customization.xml"
FONT_TARGET="${VENDOR_LINEAGE}/${FONT_RELATIVE}"

usage() {
    printf 'Usage: %s [--check]\n' "$0" >&2
    exit 2
}

die() {
    printf 'vendor/lineage input check failed: %s\n' "$*" >&2
    exit 1
}

CHECK_ONLY=false
case "$#" in
    0) ;;
    1)
        [[ "$1" == --check ]] || usage
        CHECK_ONLY=true
        ;;
    *) usage ;;
esac

# The source-replacement device uses a clean, locally committed Tinycompress
# integration. Its repo revision is captured normally; allow no untracked edits.
python3 "${HERE}/check-tinycompress-kernel-headers.py" --lineage-root "${LINEAGE}" \
    || die "Tinycompress source integration does not match the recorded patch"
python3 "${HERE}/check-home-role-source.py" --lineage-root "${LINEAGE}" \
    || die "HOME role sources or launcher removal policy do not match the recorded baseline"

[[ -d "${VENDOR_LINEAGE}" ]] \
    || { echo "Not found: ${VENDOR_LINEAGE}" >&2; exit 1; }
command -v python >/dev/null 2>&1 || die "missing host python"
for required_file in "${APN_DEFAULT}" "${APN_FRAGMENT}" \
                     "${APN_VALIDATOR}" "${APN_INTERNAL}" \
                     "${APN_MERGE_TOOL}" "${APN_DEFAULT_PATCH}" \
                     "${FONT_PATCH}" "${FONT_TARGET}"; do
    [[ -f "${required_file}" && ! -L "${required_file}" && \
       -r "${required_file}" ]] \
        || die "missing, unreadable, or symlinked input: ${required_file}"
done
[[ -x "${PYTHON2}" && ! -L "${PYTHON2}" ]] \
    || die "missing prebuilt python2.7 for the APN merge: ${PYTHON2}"

validate_outcome() {
    local apn_validation apn_default_diff font_diff lineage_status
    local merge_check_dir merged_actual merged_actual_sha

    # Requiring an EXACT dirty set proves no unrelated managed input is being
    # smuggled into the build. Both files are then compared against their
    # approved patch below, so "dirty" never means "unreviewed".
    #
    # git status sorts by path, so apns-conf.xml precedes fonts_customization.xml.
    lineage_status="$(git -C "${VENDOR_LINEAGE}" status \
        --porcelain=v1 --untracked-files=all)" \
        || die "cannot inspect vendor/lineage status"
    [[ "${lineage_status}" == \
       " M ${APN_DEFAULT_RELATIVE}"$'\n'" M ${FONT_RELATIVE}" ]] \
        || die "vendor/lineage must be dirty at exactly ${APN_DEFAULT_RELATIVE} and ${FONT_RELATIVE}"

    # Same treatment the font change gets, and for the same reason: compare the
    # whole HEAD-to-worktree diff, so the 3822 rows this does NOT touch are
    # proved untouched rather than assumed.
    apn_default_diff="$(mktemp)" || die "cannot create a temporary APN diff"
    if ! git -c core.abbrev=8 -C "${VENDOR_LINEAGE}" \
            diff --no-ext-diff --binary HEAD -- \
            "${APN_DEFAULT_RELATIVE}" >"${apn_default_diff}"; then
        rm -f -- "${apn_default_diff}"
        die "cannot calculate the APN type-attribute diff"
    fi
    if ! cmp -s "${APN_DEFAULT_PATCH}" "${apn_default_diff}"; then
        rm -f -- "${apn_default_diff}"
        die "Lineage's apns-conf.xml does not exactly match the approved patch outcome"
    fi
    rm -f -- "${apn_default_diff}"

    # The outcome that actually matters, stated independently of the diff: no
    # row for a carrier this device ships an ims APN for may reach TYPE_ALL.
    if grep -nE '<apn [^>]*mcc="460"[^>]*mnc="(00|01|02|04|06|07|08|09)"' \
            "${APN_DEFAULT}" | grep -qv 'type="'; then
        die "a China Mobile/Unicom APN row still has no type= and would claim ims"
    fi

    # Do not accept a grep-only approximation of the font change. Comparing
    # the complete HEAD-to-worktree diff proves the base content was retained,
    # the approved family was added exactly once, and no adjacent XML changed.
    font_diff="$(mktemp)" || die "cannot create a temporary font diff"
    # The approved patch was written with eight-character abbreviated object
    # IDs. Pin that presentation detail so a caller's core.abbrev setting does
    # not turn an identical XML outcome into a false mismatch.
    if ! git -c core.abbrev=8 -C "${VENDOR_LINEAGE}" \
            diff --no-ext-diff --binary HEAD -- \
            "${FONT_RELATIVE}" >"${font_diff}"; then
        rm -f -- "${font_diff}"
        die "cannot calculate the HarmonyOS font diff"
    fi
    if ! cmp -s "${FONT_PATCH}" "${font_diff}"; then
        rm -f -- "${font_diff}"
        die "fonts_customization.xml does not exactly match the approved patch outcome"
    fi
    rm -f -- "${font_diff}"

    xmllint --noout "${APN_DEFAULT}" "${FONT_TARGET}" \
        || die "the approved Lineage APN/font inputs are not valid XML"
    apn_validation="$(python "${APN_VALIDATOR}" "${APN_DEFAULT}" \
        "${APN_FRAGMENT}" "${APN_INTERNAL}")" \
        || die "the device APN fragment or merged database identities are invalid"
    [[ "$(grep -Fxc status=PASS <<<"${apn_validation}")" -eq 1 && \
       "$(grep -Fxc custom_rows=10 <<<"${apn_validation}")" -eq 1 && \
       "$(grep -Ec '^merged_sha256=[0-9a-f]{64}$' \
            <<<"${apn_validation}")" -eq 1 ]] \
        || die "the APN validator returned an incomplete result"

    # The validator computes merged_sha256 from its OWN model of the merge.
    # Nothing above proves that model matches vendor/lineage/tools/custom_apns.py,
    # which is the program the build actually runs (CUSTOM_APNS_FILE hook), and
    # which is not the validator's code. Run the real merge tool here and
    # require byte identity, so a divergence between the validator's model and
    # the build's merge is a preflight failure rather than an image that ships
    # a database nobody validated. Folded in from the retired
    # test-apn-merge-contract.sh, which was the only place this ran.
    merge_check_dir="$(mktemp -d /tmp/k50-apn-merge.XXXXXX)" \
        || die "cannot create a temporary APN merge directory"
    merged_actual="${merge_check_dir}/actual-merged.xml"
    # custom_apns.py hardcodes the default list as a path relative to the build
    # top, so it must run with the Lineage checkout as its working directory.
    discard_merge_check() {
        [[ -d "${merge_check_dir}" && ! -L "${merge_check_dir}" && \
           "${merge_check_dir}" == /tmp/k50-apn-merge.* ]] || return 0
        find "${merge_check_dir}" -mindepth 1 -depth -delete
        rmdir "${merge_check_dir}"
    }
    if ! ( cd "${LINEAGE}" && "${PYTHON2}" "${APN_MERGE_TOOL_RELATIVE}" \
                "${merged_actual}" "${APN_FRAGMENT}" ); then
        discard_merge_check
        die "vendor/lineage's own APN merge tool failed on the device fragment"
    fi
    merged_actual_sha="$(sha256sum "${merged_actual}" | awk '{ print $1 }')"
    discard_merge_check
    [[ "${merged_actual_sha}" == \
       "$(sed -n 's/^merged_sha256=//p' <<<"${apn_validation}")" ]] \
        || die "the validated merged APN digest is not what custom_apns.py produces"

    printf 'vendor/lineage carries exactly the approved font and APN-type patches; device APNs validate\n%s\n' \
        "${apn_validation}"
}

if [[ "${CHECK_ONLY}" == true ]]; then
    validate_outcome
    exit 0
fi

# Seven type= attributes on rows that had none. Additive in the same sense as
# the font family: every other row must survive, and a rejected hunk is the
# signal that upstream changed the file and this needs looking at.
if grep -q 'mnc="01" apn="3gwap" proxy="10.0.0.172" port="80" type="default,supl"' \
        "${APN_DEFAULT}"; then
    echo "apns-conf.xml already carries the type attributes"
else
    git -C "${VENDOR_LINEAGE}" apply "${APN_DEFAULT_PATCH}"
    # Assert the OUTCOME, not that git apply returned 0.
    if grep -nE '<apn [^>]*mcc="460"[^>]*mnc="(00|01|02|04|06|07|08|09)"' \
            "${APN_DEFAULT}" | grep -qv 'type="'; then
        echo "apns-conf.xml still has an untyped China Mobile/Unicom row after the patch" >&2
        exit 1
    fi
    echo "apns-conf.xml patched"
fi

# The font family is additive, so patch: lato and rubik must survive, and a
# rejected hunk is the signal that upstream changed the file and this needs
# looking at.
if grep -q 'name="harmonyos"' "${FONT_TARGET}"; then
    echo "fonts_customization.xml already carries the harmonyos family"
else
    git -C "${VENDOR_LINEAGE}" apply "${FONT_PATCH}"
    # Assert the OUTCOME, not that git apply returned 0: the whole reason this
    # file exists is that the change silently disappears, and "the patch ran"
    # is not the same claim as "the family is in the file".
    grep -q 'name="harmonyos"' "${FONT_TARGET}" \
        || { echo "fonts_customization.xml still has no harmonyos family after the patch" >&2; exit 1; }
    echo "fonts_customization.xml patched"
fi

validate_outcome
