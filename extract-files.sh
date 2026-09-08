#!/bin/bash
# Failed extraction or fixups restore the previous vendor data and makefiles.
# Usage: extract-files.sh [--android-root ROOT] [-n] [-k] [-s SECTION] [SOURCE]

set -e

DEVICE=k50sv1_64_bsp
VENDOR=xsh

ANDROID_ROOT_ARG="${ANDROID_BUILD_TOP:-}"
CLEAN_VENDOR=true
SECTION=
KANG=
SRC=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --android-root | -s | --section)
            [[ $# -ge 2 && -n "$2" ]] || {
                echo "Missing value for $1" >&2
                exit 2
            }
            if [[ "$1" == --android-root ]]; then
                ANDROID_ROOT_ARG="$2"
            else
                SECTION="$2"
                CLEAN_VENDOR=false
            fi
            shift
            ;;
        -n | --no-cleanup) CLEAN_VENDOR=false ;;
        -k | --kang) KANG="--kang" ;;
        -h | --help)
            echo "Usage: $0 [--android-root ROOT] [-n] [-k] [-s SECTION] [SOURCE]"
            exit 0
            ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)
            [[ -z "${SRC}" ]] || { echo "Only one extraction source is accepted" >&2; exit 2; }
            SRC="$1"
            ;;
    esac
    shift
done

# Keep the invocation path while locating the checkout: it may pass through
# device/xsh/<device> in a different checkout than the physical repository.
MY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${ANDROID_ROOT_ARG}" ]]; then
    ROOT_CANDIDATES=("${ANDROID_ROOT_ARG}")
else
    ROOT_CANDIDATES=("${MY_DIR}/../../.." "${MY_DIR}/../../lineage-17.1")
fi
LINEAGE_ROOT=
for candidate in "${ROOT_CANDIDATES[@]}"; do
    if candidate="$(cd -L "${candidate}" 2>/dev/null && pwd -P)" &&
            [[ -f "${candidate}/vendor/lineage/build/tools/extract_utils.sh" ]]; then
        LINEAGE_ROOT="${candidate}"
        break
    fi
done
if [[ -z "${LINEAGE_ROOT}" ]]; then
    echo "Unable to find extract_utils.sh; pass an Android source root or set ANDROID_BUILD_TOP." >&2
    exit 2
fi
MY_DIR="$(cd "${MY_DIR}" && pwd -P)"
HELPER="${LINEAGE_ROOT}/vendor/lineage/build/tools/extract_utils.sh"

# shellcheck source=/dev/null
source "${HELPER}"

function patch_ims_apk() {
    local apk="$1"
    local expected_apk_sha="06e62235bc7b30655f5dfcd2efaa7ab6a9b4c6f1efd6a6f8ce49ce1e62da3ff5"
    local expected_dex_sha="6aa7926e7974420e7fc5ea6e96c5287617a6a826dc60a46a7996f793bd986deb"
    local patched_apk_sha="ff55365eb8e9727312e00f8570c4eb88c8345e50bf11b94224d98d102efba9a0"
    local patched_dex_sha="2bae8ed5350cb1be05d68b3671f2a98912e62200af10ef2b61bd1d812bc24315"
    local baksmali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/baksmali.jar"
    local smali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/smali.jar"
    local apk_sha
    local dex_sha
    local patch_dir

    apk_sha="$(sha256sum "${apk}" | awk '{ print $1 }')"
    if [[ "${apk_sha}" == "${patched_apk_sha}" ]]; then
        return 0
    fi
    if [[ "${apk_sha}" != "${expected_apk_sha}" ]]; then
        echo "Refusing ImsService.apk ${apk_sha}; re-extract from Stock" >&2
        return 1
    fi
    for tool in java python3 unzip zip; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            echo "Missing IMS patch dependency: ${tool}" >&2
            return 1
        fi
    done
    if [[ ! -r "${baksmali_jar}" || ! -r "${smali_jar}" ]]; then
        echo "Missing bundled smali tools for ImsService.apk" >&2
        return 1
    fi

    # Keep the temporary and final APK on the same filesystem so publication
    # is atomic. The output is unsigned because Android signs this phone-UID
    # app with the selected tier's platform certificate during the build.
    patch_dir="$(mktemp -d "${apk}.patch.XXXXXX")"
    (
        trap 'find "${patch_dir}" -depth -delete 2>/dev/null || true' EXIT

        unzip -p "${apk}" classes.dex >"${patch_dir}/classes.dex"
        dex_sha="$(sha256sum "${patch_dir}/classes.dex" | awk '{ print $1 }')"
        if [[ "${dex_sha}" != "${expected_dex_sha}" ]]; then
            echo "Unexpected Stock IMS classes.dex: ${dex_sha}" >&2
            exit 1
        fi

        java -jar "${baksmali_jar}" disassemble -j 1 \
            "${patch_dir}/classes.dex" -o "${patch_dir}/smali"

        local ims_service="${patch_dir}/smali/com/mediatek/ims/ImsService.smali"

        # Rewrite the com.android.internal.R integers the APK was compiled
        # against. The mapping lives in ims/framework-resource-ids.txt rather
        # than here, because ims/Android.mk asserts the same table against the
        # framework this build actually produces -- keeping the two in one file
        # is what stops them drifting apart.
        local resource_ids="${MY_DIR}/ims/framework-resource-ids.txt"
        if [[ ! -r "${resource_ids}" ]]; then
            echo "Missing IMS framework resource table: ${resource_ids}" >&2
            exit 1
        fi
        local rewrites=0
        local name stock lineage smali_class target
        while read -r name stock lineage smali_class; do
            [[ -z "${name}" || "${name}" == \#* ]] && continue
            target="${patch_dir}/smali/com/mediatek/ims/${smali_class}.smali"
            if [[ ! -f "${target}" ]]; then
                echo "IMS resource table names a missing class: ${smali_class}" >&2
                exit 1
            fi
            # Exactly one reference, and it must be in the class the table names.
            if [[ "$(grep -R -F -h -c "${stock}" \
                    "${patch_dir}/smali/com/mediatek" \
                    | awk '{ n += $1 } END { print n + 0 }')" -ne 1 ]] || \
               [[ "$(grep -F -c "${stock}" "${target}")" -ne 1 ]]; then
                echo "Unexpected IMS reference to ${name} (${stock})" >&2
                exit 1
            fi
            sed -i -e "s/${stock}/${lineage}/" "${target}"
            rewrites=$((rewrites + 1))
        done <"${resource_ids}"
        if [[ "${rewrites}" -ne 4 ]]; then
            echo "IMS resource table rewrote ${rewrites} of the expected 4 IDs" >&2
            exit 1
        fi

        # ImsService.<init> calls WfoService.getInstance(ctx).makeWfoService(),
        # which publishes the "wfo" binder service. That call is KEPT, and this
        # assertion exists so that an unexpected upstream APK is a hard failure
        # rather than a silent behaviour change.
        #
        # An earlier revision deleted the call here, describing it as "the full
        # Wi-Fi offload service even when WFC is disabled" that a no-video
        # voice-MMTEL port does not need. That is the wrong reading of what the service
        # does, and removing it is one half of why VoLTE never registered:
        # WifiOffloadService is the only caller of nativeSetWosProfile, which is
        # what reaches libmal.so's rds_set_ui_param, which is the ONLY writer of
        # MediaTek's RDS "Epdgs ready" flag. With that flag clear, RDS refuses to
        # assign an IMS RAT ("MDmngr(1) or Epdgs(0) is not ready", every ~5 s),
        # MAL reports assigned_rat=0, mtk-ril's configEpdg turns that into
        # eran_type=0, and MAL's IMSM aborts the IMS PDN with "rat error!!".
        # See E-087, and vendor.prop's note on persist.vendor.mtk_wfc_support,
        # which is the other half.
        if [[ "$(grep -F -c \
                'Lcom/mediatek/wfo/impl/WfoService;->makeWfoService()V' \
                "${ims_service}")" -ne 1 ]]; then
            echo "Unexpected Stock WFO call count in ImsService.apk" >&2
            exit 1
        fi

        # mtkIms is a separate Binder endpoint from WFO. Enforce standard phone
        # permissions in its concrete class before the bootclasspath Stub
        # unmarshals requests. Controller-returning getters and SMS-listener
        # replacement require MODIFY; ordinary state queries/observers use READ.
        # Keep the existing setCallIndication check and all direct IMS paths.
        python3 - "${patch_dir}/smali/com/mediatek/ims/MtkImsService.smali" <<'IMSAUTHEOF'
import re
import sys

path = sys.argv[1]
src = open(path).read()
# IMtkImsService.Stub transaction order in the selected mediatek-ims-base.jar.
methods = [
    'setCallIndication(ILjava/lang/String;Ljava/lang/String;ILjava/lang/String;ZI)V',
    'createMtkCallSession(ILandroid/telephony/ims/ImsCallProfile;Landroid/telephony/ims/aidl/IImsCallSessionListener;Lcom/android/ims/internal/IImsCallSession;)Lcom/mediatek/ims/internal/IMtkImsCallSession;',
    'getPendingMtkCallSession(ILjava/lang/String;)Lcom/mediatek/ims/internal/IMtkImsCallSession;',
    'getImsState(I)I',
    'getImsRegUriType(I)I',
    'hangupAllCall(I)V',
    'deregisterIms(I)V',
    'updateRadioState(II)V',
    'UpdateImsState(I)V',
    'getConfigInterfaceEx(I)Lcom/mediatek/ims/internal/IMtkImsConfig;',
    'getMtkUtInterface(I)Lcom/mediatek/ims/internal/IMtkImsUt;',
    'runGbaAuthentication(Ljava/lang/String;[BZII)Lcom/mediatek/gba/NafSessionKey;',
    'getModemMultiImsCount()I',
    'getCurrentCallCount(I)I',
    'getImsNetworkState(I)[I',
    'addImsSmsListener(ILandroid/telephony/ims/aidl/IImsSmsListener;)V',
    'sendSms(IIILjava/lang/String;Ljava/lang/String;Z[B)V',
    'registerProprietaryImsListener(ILcom/android/ims/internal/IImsRegistrationListener;Lcom/mediatek/ims/internal/IMtkImsRegistrationListener;Z)V',
    'isCameraAvailable()Z',
    'setMTRedirect(IZ)V',
    'fallBackAospMTFlow(I)V',
    'setSipHeader(ILjava/util/Map;Ljava/lang/String;)V',
    'changeEnabledCapabilities(ILandroid/telephony/ims/feature/CapabilityChangeRequest;)V',
    'setImsPreCallInfo(IILjava/lang/String;Ljava/lang/String;Ljava/util/Map;[Ljava/lang/String;)V',
]
actual_methods = re.findall(r'^\.method public (\w+\([^\n]+)$', src, re.M)
if len(methods) != 24 or sorted(actual_methods) != sorted(methods):
    raise SystemExit('unexpected MtkImsService method signatures')
read_codes = {4, 5, 13, 14, 15, 18, 19}
field = '.field private mImsService:Lcom/mediatek/ims/ImsService;'
constructor = '.method public constructor <init>(Landroid/content/Context;Lcom/mediatek/ims/ImsService;)V'
super_init = '    invoke-direct {p0}, Lcom/mediatek/ims/internal/IMtkImsService$Stub;-><init>()V'
for declaration in (
    '.class public Lcom/mediatek/ims/MtkImsService;',
    '.super Lcom/mediatek/ims/internal/IMtkImsService$Stub;',
    field, constructor, super_init,
):
    if src.splitlines().count(declaration) != 1:
        raise SystemExit('unexpected MtkImsService declaration: ' + declaration)
if 'mContext:' in src or 'onTransact(' in src:
    raise SystemExit('MtkImsService already has context/transaction handling')
src = src.replace(field, '.field private final mContext:Landroid/content/Context;\n\n' + field, 1)
src = src.replace(super_init, super_init + '\n\n    iput-object p1, p0, Lcom/mediatek/ims/MtkImsService;->mContext:Landroid/content/Context;', 1)

guard = r'''.method public onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z
    .locals 3
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Landroid/os/RemoteException;
        }
    .end annotation

    packed-switch p1, :pswitch_data_k50sv1_ims_permission

    goto :goto_k50sv1_ims_dispatch

    :pswitch_k50sv1_ims_read
    const-string v1, "android.permission.READ_PRIVILEGED_PHONE_STATE"

    goto :goto_k50sv1_ims_enforce

    :pswitch_k50sv1_ims_modify
    const-string v1, "android.permission.MODIFY_PHONE_STATE"

    :goto_k50sv1_ims_enforce
    iget-object v0, p0, Lcom/mediatek/ims/MtkImsService;->mContext:Landroid/content/Context;

    const-string v2, "MtkImsService"

    invoke-virtual {v0, v1, v2}, Landroid/content/Context;->enforceCallingOrSelfPermission(Ljava/lang/String;Ljava/lang/String;)V

    :goto_k50sv1_ims_dispatch
    invoke-super {p0, p1, p2, p3, p4}, Lcom/mediatek/ims/internal/IMtkImsService$Stub;->onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z

    move-result v0

    return v0

    :pswitch_data_k50sv1_ims_permission
    .packed-switch 0x1
'''
guard += ''.join('        :pswitch_k50sv1_ims_' +
                 ('read' if code in read_codes else 'modify') + '\n'
                 for code in range(1, len(methods) + 1))
guard += '    .end packed-switch\n.end method\n'
open(path, 'w').write(src.rstrip() + '\n\n' + guard)
IMSAUTHEOF

        java -jar "${smali_jar}" assemble -j 1 \
            "${patch_dir}/smali" -o "${patch_dir}/classes.dex"

        while read -r name stock lineage smali_class; do
            [[ -z "${name}" || "${name}" == \#* ]] && continue
            if grep -R -F -q "${stock}" "${patch_dir}/smali/com/mediatek"; then
                echo "Stale IMS framework resource reference: ${name} (${stock})" >&2
                exit 1
            fi
        done <"${resource_ids}"

        cp -- "${apk}" "${patch_dir}/ImsService.apk"
        # Do not rely on ZIP's timestamp-based update decision: the Stock and
        # deterministic rebuilt dex intentionally share the 2009 timestamp.
        zip -q -d "${patch_dir}/ImsService.apk" classes.dex 'META-INF/*'
        touch -d '2009-01-01 00:00:00 UTC' "${patch_dir}/classes.dex"
        (
            cd "${patch_dir}"
            zip -q -X ImsService.apk classes.dex
        )
        unzip -tq "${patch_dir}/ImsService.apk" >/dev/null
        # Output pins keep the resource rewrites, WFO startup and Binder guard
        # reproducible with the selected smali toolchain.
        dex_sha="$(unzip -p "${patch_dir}/ImsService.apk" classes.dex \
            | sha256sum | awk '{ print $1 }')"
        if [[ "${dex_sha}" != "${patched_dex_sha}" ]]; then
            echo "Non-reproducible patched IMS classes.dex: ${dex_sha}" >&2
            exit 1
        fi
        apk_sha="$(sha256sum "${patch_dir}/ImsService.apk" | awk '{ print $1 }')"
        if [[ "${apk_sha}" != "${patched_apk_sha}" ]]; then
            echo "Non-reproducible patched ImsService.apk: ${apk_sha}" >&2
            exit 1
        fi
        chmod 0644 "${patch_dir}/ImsService.apk"
        mv -f -- "${patch_dir}/ImsService.apk" "${apk}"
    )
}

# Blob fixups.
#
# extract_utils runs the extraction loop with errexit disabled so it can retry
# alternate source paths, and it ignores blob_fixup's exit status. A fixup that
# merely returned non-zero would therefore publish the original or a partially
# rewritten blob and still report success, so every failure path below aborts
# the whole script instead. Keeping the abort here means vendor/lineage does
# not have to be patched.
#
# The Wi-Fi fixups keep MTK's Wi-Fi HAL ABI without colliding with the AOSP
# library that uses the same filename. The replacement SONAME is exactly the
# same length, so the ELF dynamic string table layout is unchanged.
function patch_wfo_jar() {
    local jar="$1"
    local expected_jar_sha="18fe7a0a3c72ba07e487ed9ac40538bdff8dfc3d2baf33784148f553128f4f7b"
    local expected_dex_sha="b0a961ffcc71ba2c0909ce2111b0bdc26adaf816c8652d60dd83b4d9aa729449"
    local patched_jar_sha="56639a07068b462e657c3239af32d5cda9024dd8a88c7674ebcb1b32d1d2c317"
    local patched_dex_sha="29596dd5b5fb8c2b543171ccf4616efd86939b7cbf8bb896e6c9e03047e59137"
    local baksmali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/baksmali.jar"
    local smali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/smali.jar"
    local jar_sha
    local dex_sha
    local patch_dir

    jar_sha="$(sha256sum "${jar}" | awk '{ print $1 }')"
    if [[ "${jar_sha}" == "${patched_jar_sha}" ]]; then
        return 0
    fi
    if [[ "${jar_sha}" != "${expected_jar_sha}" ]]; then
        echo "Refusing mediatek-wfo-legacy.jar ${jar_sha}; re-extract from Stock" >&2
        return 1
    fi
    for tool in java python3 unzip zip; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            echo "Missing WFO patch dependency: ${tool}" >&2
            return 1
        fi
    done
    if [[ ! -r "${baksmali_jar}" || ! -r "${smali_jar}" ]]; then
        echo "Missing bundled smali tools for mediatek-wfo-legacy.jar" >&2
        return 1
    fi

    patch_dir="$(mktemp -d "${jar}.patch.XXXXXX")"
    (
        trap 'find "${patch_dir}" -depth -delete 2>/dev/null || true' EXIT

        unzip -p "${jar}" classes.dex >"${patch_dir}/classes.dex"
        dex_sha="$(sha256sum "${patch_dir}/classes.dex" | awk '{ print $1 }')"
        if [[ "${dex_sha}" != "${expected_dex_sha}" ]]; then
            echo "Unexpected Stock WFO classes.dex: ${dex_sha}" >&2
            exit 1
        fi

        java -jar "${baksmali_jar}" disassemble -j 1 \
            "${patch_dir}/classes.dex" -o "${patch_dir}/smali"

        local receiver="${patch_dir}/smali/com/mediatek/wfo/impl/WifiOffloadService\$3.smali"
        local service="${patch_dir}/smali/com/mediatek/wfo/impl/WifiOffloadService.smali"
        if [[ ! -r "${receiver}" || ! -r "${service}" ]]; then
            echo "Missing WifiOffloadService smali" >&2
            exit 1
        fi

        # Keep WifiOffloadService's IMS_FEATURE_CHANGED receiver without the
        # MediaTek-only framework cast.
        #
        # It does, at WifiOffloadService.java:571-575:
        #
        #   ImsManager m = ImsManager.getInstance(ctx, phoneId);
        #   ((MtkImsManager) m).getConfigInterfaceEx()          <-- ClassCastException
        #
        # Stock gets away with that because MediaTek PATCHES AOSP's
        # frameworks/opt/net/ims so ImsManager.getInstance() returns its own
        # MtkImsManager subclass. This port builds AOSP's unpatched ims-common,
        # so the cast throws and takes com.mediatek.ims down with it -- measured
        # on the handset, twice at boot, after which the IMS service never came
        # back and no IMS PDN was ever requested.
        #
        # A dependency-closure check cannot catch this: every class resolves;
        # the runtime type assumption is what fails. The previous workaround
        # replaced the receiver with return-void. That stopped the crash but also
        # made updateFeatureValue() constructor-only, so changing WFC at runtime
        # updated persist.vendor.mtk.wfc.enable without updating mIsWfcEnabled or
        # MAL. A reboot was then required (E-099/WI-055).
        #
        # The WFC/VoLTE/ViLTE values this receiver needs already exist in the
        # properties updateFeatureValue() reads. Call that private method through
        # a compiler-style synthetic accessor, then enqueue the blob's existing
        # EVENT_NOTIRY_MAL_USER_PROFILE (20), whose handler calls
        # notifyMalUserProfile/nativeSetWosProfile. This stays inside the jar,
        # avoids an upstream ims-common fork, and preserves live WFC toggles
        # without the invalid MtkImsManager cast.
        #
        # ...but NOT from the properties alone. The broadcast arrives BEFORE the
        # property changes: ImsConfigImpl.setFeatureValue() first stores the
        # value (ImsConfigProvider.update() sends IMS_FEATURE_CHANGED from that
        # store, with phone_id/item/value extras) and only then calls
        # turnOnVolte()/turnOffVolte() -> IMtkRadioEx.setVendorSetting(11) ->
        # rild, which is the process that writes persist.vendor.mtk.volte.enable
        # (no Java class in the jar or in ImsService.apk writes it). So a
        # receiver that re-reads the property hands MAL the PREVIOUS value, and
        # MAL drives the modem from that: measured on the handset 2026-09-03
        # with the CU SIM and carrier_volte_available_bool overridden true --
        # VoLTE switch OFF tap -> rds_set_ui_param volte(1) -> AT+EIMSVOLTE=1 ->
        # onRequestImsSwitch isImsOn=true -> AT+EIMS=1 -> +EIMS: 1; switch ON
        # tap -> volte(0) -> AT+EIMSVOLTE=0 -> AT+EIMS=0 -> +EIMS: 0. Inverted,
        # every time (session-19 ims report, section 3.4).
        #
        # Hence the receiver still refreshes every flag from the properties
        # (the constructor's boot-time read is untouched, and the other three
        # flags have not changed) and then lets the intent's own extras win for
        # the one item that did change: applyImsFeatureChange(phone_id, item,
        # value) stores value==1 into mIsVolteEnabled (item 0), mIsVilteEnabled
        # (item 1) or mIsWfcEnabled (item 2, ImsConfig.FeatureConstants) before
        # the profile is pushed. Intents without the extras (-1 defaults) or with
        # an out-of-range phone id fall back to the property values, exactly as
        # before.
        #
        # There is a second reason this receiver must do real work. With WFC off,
        # MAL still asked WFO for five RSSI thresholds (-85/-75/-78/-88/-90).
        # RssiMonitoringProcessor turned each into a ConnectivityManager
        # NetworkRequest, and AOSP merged them into the Wi-Fi HAL's RSSI-monitor
        # range. This MTK WLAN driver's wlanoidRssiMonitor clamps the +127 upper
        # sentinel to -10 dBm; with framework curRssi=-12, firmware repeatedly
        # reported -10: 2191 events at a 3.072 s mean interval in the captured
        # baseline, with R12_CONN2AP_SPM_WAKEUP_B / Event 0xa1 waking the AP
        # through suspend.
        #
        # WFO is load-bearing for VoLTE/WFC, so do not disable the service or
        # remove its privileged permission. These Android threshold callbacks,
        # however, are direct instances of the empty NetworkCallback base class;
        # MAL independently polls wpa with SIGNAL_POLL and applies the carrier
        # thresholds itself. onRssiMonitorRequest therefore removes any stale
        # callbacks for that SIM and never installs the broken hardware-offload
        # requests, while retaining its original updateLastRssi/quality-message
        # tail. The package-visible helper clears every SIM after a live IMS
        # feature change, and the receiver still sends
        # EVENT_NOTIRY_MAL_USER_PROFILE so MAL's normal profile refresh survives.
        local marker='.method public onReceive(Landroid/content/Context;Landroid/content/Intent;)V'
        if [[ "$(grep -c -F -- "${marker}" "${receiver}")" -ne 1 ]]; then
            echo "Unexpected onReceive count in WifiOffloadService\$3" >&2
            exit 1
        fi
        # .registers stays as baksmali emitted it; only the body changes. Keep
        # updateFeatureValue() private so its existing invoke-direct remains
        # verifier-correct, and add the same synthetic-accessor shape javac would
        # generate for a private outer method used by an inner class.
        python3 - "${receiver}" "${service}" <<'PYEOF'
import re, sys
receiver_path, service_path = sys.argv[1:]
src = open(receiver_path).read()
sig = '.method public onReceive(Landroid/content/Context;Landroid/content/Intent;)V\n'
i = src.index(sig) + len(sig)
j = src.index('.end method', i)
body = src[i:j]
m = re.search(r'^\s*\.(registers|locals)\s+\d+\s*$', body, re.M)
if not m:
    raise SystemExit('no .registers/.locals directive in onReceive')
head = body[:m.end()] + '\n'
replacement = r'''
    iget-object v0, p0, Lcom/mediatek/wfo/impl/WifiOffloadService$3;->this$0:Lcom/mediatek/wfo/impl/WifiOffloadService;

    invoke-static {v0}, Lcom/mediatek/wfo/impl/WifiOffloadService;->access$6000(Lcom/mediatek/wfo/impl/WifiOffloadService;)V

    const/4 v4, -0x1

    const-string v1, "phone_id"

    invoke-virtual {p2, v1, v4}, Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I

    move-result v1

    const-string v2, "item"

    invoke-virtual {p2, v2, v4}, Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I

    move-result v2

    const-string v3, "value"

    invoke-virtual {p2, v3, v4}, Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I

    move-result v3

    invoke-virtual {v0, v1, v2, v3}, Lcom/mediatek/wfo/impl/WifiOffloadService;->applyImsFeatureChange(III)V

    invoke-virtual {v0}, Lcom/mediatek/wfo/impl/WifiOffloadService;->unregisterAllRssiMonitoring()V

    iget-object v0, p0, Lcom/mediatek/wfo/impl/WifiOffloadService$3;->this$0:Lcom/mediatek/wfo/impl/WifiOffloadService;

    invoke-static {v0}, Lcom/mediatek/wfo/impl/WifiOffloadService;->access$000(Lcom/mediatek/wfo/impl/WifiOffloadService;)Lcom/mediatek/wfo/impl/WifiOffloadService$WFOServHandler;

    move-result-object v0

    const/16 v1, 0x14

    invoke-virtual {v0, v1}, Lcom/mediatek/wfo/impl/WifiOffloadService$WFOServHandler;->obtainMessage(I)Landroid/os/Message;

    move-result-object v1

    invoke-virtual {v0, v1}, Lcom/mediatek/wfo/impl/WifiOffloadService$WFOServHandler;->sendMessage(Landroid/os/Message;)Z

    return-void
'''
open(receiver_path, 'w').write(src[:i] + head + replacement + src[j:])

service = open(service_path).read()
private = '.method private updateFeatureValue()V'
accessor_sig = ('.method static synthetic access$6000('
                'Lcom/mediatek/wfo/impl/WifiOffloadService;)V')
cleanup_sig = '.method unregisterAllRssiMonitoring()V'
apply_sig = '.method applyImsFeatureChange(III)V'
if (service.count(private) != 1 or 'access$6000' in service
        or cleanup_sig in service or apply_sig in service
        or 'goto_k50sv1_rssi_registration_done' in service):
    raise SystemExit('unexpected updateFeatureValue declaration')
accessor = r'''.method static synthetic access$6000(Lcom/mediatek/wfo/impl/WifiOffloadService;)V
    .registers 1
    .param p0, "x0"    # Lcom/mediatek/wfo/impl/WifiOffloadService;

    invoke-direct {p0}, Lcom/mediatek/wfo/impl/WifiOffloadService;->updateFeatureValue()V

    return-void
.end method

'''
cleanup = r'''.method unregisterAllRssiMonitoring()V
    .registers 3

    iget-object v1, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mRssiMonitoringProcessor:Lcom/mediatek/wfo/util/RssiMonitoringProcessor;

    if-eqz v1, :cond_k50sv1_rssi_cleanup_done

    const/4 v0, 0x0

    :goto_k50sv1_rssi_cleanup
    iget v1, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mSimCount:I

    if-ge v0, v1, :cond_k50sv1_rssi_cleanup_done

    iget-object v1, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mRssiMonitoringProcessor:Lcom/mediatek/wfo/util/RssiMonitoringProcessor;

    invoke-virtual {v1, v0}, Lcom/mediatek/wfo/util/RssiMonitoringProcessor;->unregisterAllRssiMonitoring(I)V

    add-int/lit8 v0, v0, 0x1

    goto :goto_k50sv1_rssi_cleanup

    :cond_k50sv1_rssi_cleanup_done
    return-void
.end method

'''
# The intent's value for the item that changed wins over the (not yet
# rewritten) persist property. Item ids are ImsConfig.FeatureConstants:
# 0 VoLTE, 1 ViLTE, 2 VoWiFi; 3 (ViWiFi) has no flag in this service and the
# -1 defaults of a bare intent are ignored. Registers: v0 = enabled/mSimCount,
# v1 = scratch/array, p1 = phoneId, p2 = item, p3 = value.
apply = r'''.method applyImsFeatureChange(III)V
    .registers 6
    .param p1, "phoneId"    # I
    .param p2, "item"    # I
    .param p3, "value"    # I

    if-ltz p1, :cond_k50sv1_apply_done

    iget v0, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mSimCount:I

    if-ge p1, v0, :cond_k50sv1_apply_done

    if-ltz p3, :cond_k50sv1_apply_done

    const/4 v1, 0x1

    if-ne p3, v1, :cond_k50sv1_apply_off

    const/4 v0, 0x1

    goto :goto_k50sv1_apply_store

    :cond_k50sv1_apply_off
    const/4 v0, 0x0

    :goto_k50sv1_apply_store
    if-nez p2, :cond_k50sv1_apply_not_volte

    iget-object v1, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mIsVolteEnabled:[Z

    aput-boolean v0, v1, p1

    goto :cond_k50sv1_apply_done

    :cond_k50sv1_apply_not_volte
    const/4 v1, 0x1

    if-ne p2, v1, :cond_k50sv1_apply_not_vilte

    iget-object v1, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mIsVilteEnabled:[Z

    aput-boolean v0, v1, p1

    goto :cond_k50sv1_apply_done

    :cond_k50sv1_apply_not_vilte
    const/4 v1, 0x2

    if-ne p2, v1, :cond_k50sv1_apply_done

    iget-object v1, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mIsWfcEnabled:[Z

    aput-boolean v0, v1, p1

    :cond_k50sv1_apply_done
    return-void
.end method

'''
service = service.replace(private, accessor + cleanup + apply + private, 1)

rssi_old = r'''.method protected onRssiMonitorRequest(II[I)V
    .registers 9
    .param p1, "simId"    # I
    .param p2, "size"    # I
    .param p3, "rssiThresholds"    # [I

    .line 2125
    iget-object v0, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mRssiMonitoringProcessor:Lcom/mediatek/wfo/util/RssiMonitoringProcessor;

    invoke-virtual {v0, p1, p2, p3}, Lcom/mediatek/wfo/util/RssiMonitoringProcessor;->registerRssiMonitoring(II[I)V

    .line 2128
'''
rssi_new = r'''.method protected onRssiMonitorRequest(II[I)V
    .registers 9
    .param p1, "simId"    # I
    .param p2, "size"    # I
    .param p3, "rssiThresholds"    # [I

    const-string v0, "onRssiMonitorRequest: invalid SIM id"

    invoke-direct {p0, p1, v0}, Lcom/mediatek/wfo/impl/WifiOffloadService;->checkInvalidSimIdx(ILjava/lang/String;)Z

    move-result v0

    if-nez v0, :goto_k50sv1_rssi_registration_done

    iget-object v0, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mRssiMonitoringProcessor:Lcom/mediatek/wfo/util/RssiMonitoringProcessor;

    invoke-virtual {v0, p1}, Lcom/mediatek/wfo/util/RssiMonitoringProcessor;->unregisterAllRssiMonitoring(I)V

    :goto_k50sv1_rssi_registration_done
    .line 2128
'''
if service.count(rssi_old) != 1:
    raise SystemExit('unexpected onRssiMonitorRequest prologue')
service = service.replace(rssi_old, rssi_new, 1)
open(service_path, 'w').write(service)
PYEOF
        if [[ "$(grep -c -F 'Lcom/mediatek/ims/internal/MtkImsManager;' "${receiver}")" -ne 0 ]]; then
            echo "WFO receiver still references MtkImsManager" >&2
            exit 1
        fi
        if [[ "$(grep -c -F -- '->access$6000' "${receiver}")" -ne 1 || \
              "$(grep -c -F '.method static synthetic access$6000' "${service}")" -ne 1 || \
              "$(grep -c -F '.method private updateFeatureValue()V' "${service}")" -ne 1 || \
              "$(grep -c -F -- '->applyImsFeatureChange(III)V' "${receiver}")" -ne 1 || \
              "$(grep -c -F '.method applyImsFeatureChange(III)V' "${service}")" -ne 1 || \
              "$(grep -c -F -- 'Landroid/content/Intent;->getIntExtra(Ljava/lang/String;I)I' "${receiver}")" -ne 3 || \
              "$(grep -c -F -- '->unregisterAllRssiMonitoring()V' "${receiver}")" -ne 1 || \
              "$(grep -c -F '.method unregisterAllRssiMonitoring()V' "${service}")" -ne 1 || \
              "$(grep -c -F -x '    :goto_k50sv1_rssi_registration_done' "${service}")" -ne 1 ]]; then
            echo "WFO live feature refresh/RSSI suppression was not installed" >&2
            exit 1
        fi

        # Give notifyMalSimInfo() a card type it can use.
        #
        # WifiOffloadService.notifyMalSimInfo() is the ONLY thing that tells MAL
        # a SIM exists, and every VoWiFi path below it is dead until it does.
        # On stock it reads the card type through
        #
        #   MtkTelephonyManagerEx.getDefault().getIccCardType(subId)
        #
        # which resolves ServiceManager.getService("phoneEx") -- a binder
        # service registered only by MtkTeleService.apk, MediaTek's drop-in
        # replacement for packages/services/Telephony. This port ships AOSP's
        # Phone app, which registers "phone" and "iphonesubinfo" only, so
        # MtkTelephonyManagerEx catches the NPE and returns null and
        # notifyMalSimInfo bails four instructions later. Measured on the
        # handset, on every SIM-state change, both slots:
        #
        #   W System.err: java.lang.NullPointerException: ... IMtkTelephonyEx.getIccCardType
        #       at com.mediatek.telephony.MtkTelephonyManagerEx.getIccCardType(:415)
        #       at com.mediatek.wfo.impl.WifiOffloadService.notifyMalSimInfo(:1779)
        #   D WifiOffloadService: notifyMalSimInfo: unexpected result, simType=null, return directly
        #
        # The substitute is neither a guess nor a constant: MediaTek's own RIL
        # already publishes the card type per slot, and it is what the "phoneEx"
        # implementation would have returned. Live on this handset:
        #
        #   [vendor.gsm.ril.uicctype]:   [USIM]     (slot 0)
        #   [vendor.gsm.ril.uicctype.2]: [USIM]     (slot 1)
        #
        # Note the suffix scheme -- base name for slot 0, ".2" for slot 1. It is
        # NOT the ".1" that vendor.gsm.ril.uicc.mccmnc uses; MediaTek is
        # inconsistent about this and the two must not be assumed to match.
        # SIM_COUNT is 2 on this chassis, so both names are spelled out rather
        # than built at runtime.
        #
        # SystemProperties.get(key, def) returns def when the property is unset
        # OR empty, so a slot with no card would fall back to "USIM" -- which is
        # unreachable anyway, because this code sits inside the "LOADED" branch.
        # SystemProperties is already used by ten classes in this jar, so it
        # raises no new hidden-API question.
        #
        # The registers are the ones baksmali emitted: v2 is the slot index
        # (move/from16 v2, p1), v9 is simTypeStr, and v12 is scratch that the
        # very next instruction overwrites. .registers is 28, so all three are
        # reachable by every instruction form used here.
        python3 - "${service}" <<'WFOSIMEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = '''    invoke-static {}, Lcom/mediatek/telephony/MtkTelephonyManagerEx;->getDefault()Lcom/mediatek/telephony/MtkTelephonyManagerEx;

    move-result-object v12

    invoke-virtual {v12, v4}, Lcom/mediatek/telephony/MtkTelephonyManagerEx;->getIccCardType(I)Ljava/lang/String;

    move-result-object v9
'''
new = '''    if-nez v2, :cond_k50sv1_uicc_slot1

    const-string v12, "vendor.gsm.ril.uicctype"

    goto :goto_k50sv1_uicc

    :cond_k50sv1_uicc_slot1
    const-string v12, "vendor.gsm.ril.uicctype.2"

    :goto_k50sv1_uicc
    const-string v9, "USIM"

    invoke-static {v12, v9}, Landroid/os/SystemProperties;->get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v9
'''
if src.count(old) != 1:
    raise SystemExit('expected exactly one getIccCardType call site, found %d'
                     % src.count(old))
open(path, 'w').write(src.replace(old, new))
WFOSIMEOF
        if [[ "$(grep -c -F 'getIccCardType' "${service}")" -ne 0 ]]; then
            echo "WifiOffloadService still calls getIccCardType" >&2
            exit 1
        fi
        # getIsimImpi stays. It returns null the same way, but notifyMalSimInfo
        # already survives that: the null check five instructions later
        # substitutes "" and checkAsciiValid("") is true, so the method carries
        # on. Whether an ePDG accepts a UE with no IMPI is a carrier question
        # this port cannot settle statically -- and there is no correct value to
        # substitute anyway, because the SIM in slot 0 has no ISIM application
        # at all (IccCardStatus reports ims_id=-1, RIL-SIM: "Not get ISIM AID
        # yet").
        #
        # notifyPowerOnModem's RadioManager.isFlightModePowerOffModemConfigEnabled()
        # also stays and needs no patch: it reads five SystemProperties and two
        # static booleans and cannot throw. An earlier note claiming it had to be
        # neutralised was wrong.

        # Check WFO's remote Binder calls before the inherited Stub reads the
        # parcel or invokes a method. The concrete class is loaded from this
        # jar; its duplicated Stub is shadowed by the bootclasspath copy.
        # Standard phone permissions preserve phone/system and authorized shell
        # callers. Other Binder transactions, including INTERFACE_TRANSACTION,
        # retain the superclass behavior. Never clear the caller's identity.
        python3 - "${service}" \
            "${patch_dir}/smali/com/mediatek/wfo/IWifiOffloadService\$Stub.smali" <<'WFOAUTHEOF'
import re
import sys

path, stub_path = sys.argv[1:]
src = open(path).read()
stub = open(stub_path).read()
expected_transactions = {
    'registerForHandoverEvent': 1, 'unregisterForHandoverEvent': 2,
    'getRatType': 3, 'getDisconnectCause': 4, 'setEpdgFqdn': 5,
    'updateCallState': 6, 'isWifiConnected': 7, 'updateRadioState': 8,
    'setMccMncAllowList': 9, 'getMccMncAllowList': 10,
    'factoryReset': 11, 'setWifiOff': 12,
}
transactions = re.findall(
    r'^\.field static final TRANSACTION_(\w+):I = (0x[0-9a-f]+)$', stub, re.M)
if (len(transactions) != len(expected_transactions)
        or {name: int(code, 16) for name, code in transactions}
        != expected_transactions):
    raise SystemExit('unexpected WFO Binder transaction map')
for declaration in (
    '.class public Lcom/mediatek/wfo/impl/WifiOffloadService;',
    '.super Lcom/mediatek/wfo/IWifiOffloadService$Stub;',
    '.field private mContext:Landroid/content/Context;',
):
    if src.splitlines().count(declaration) != 1:
        raise SystemExit('unexpected WFO declaration: ' + declaration)
if re.search(r'^\.method .* onTransact\(', src, re.M):
    raise SystemExit('WifiOffloadService already overrides onTransact')

guard = r'''.method public onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z
    .locals 3
    .annotation system Ldalvik/annotation/Throws;
        value = {
            Landroid/os/RemoteException;
        }
    .end annotation

    packed-switch p1, :pswitch_data_k50sv1_wfo_permission

    goto :goto_k50sv1_wfo_dispatch

    :pswitch_k50sv1_wfo_read
    const-string v1, "android.permission.READ_PRIVILEGED_PHONE_STATE"

    goto :goto_k50sv1_wfo_enforce

    :pswitch_k50sv1_wfo_modify
    const-string v1, "android.permission.MODIFY_PHONE_STATE"

    :goto_k50sv1_wfo_enforce
    iget-object v0, p0, Lcom/mediatek/wfo/impl/WifiOffloadService;->mContext:Landroid/content/Context;

    const-string v2, "WifiOffloadService"

    invoke-virtual {v0, v1, v2}, Landroid/content/Context;->enforceCallingOrSelfPermission(Ljava/lang/String;Ljava/lang/String;)V

    :goto_k50sv1_wfo_dispatch
    invoke-super {p0, p1, p2, p3, p4}, Lcom/mediatek/wfo/IWifiOffloadService$Stub;->onTransact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z

    move-result v0

    return v0

    :pswitch_data_k50sv1_wfo_permission
    .packed-switch 0x1
        :pswitch_k50sv1_wfo_read
        :pswitch_k50sv1_wfo_read
        :pswitch_k50sv1_wfo_read
        :pswitch_k50sv1_wfo_read
        :pswitch_k50sv1_wfo_modify
        :pswitch_k50sv1_wfo_modify
        :pswitch_k50sv1_wfo_read
        :pswitch_k50sv1_wfo_modify
        :pswitch_k50sv1_wfo_modify
        :pswitch_k50sv1_wfo_read
        :pswitch_k50sv1_wfo_modify
        :pswitch_k50sv1_wfo_modify
    .end packed-switch
.end method
'''
open(path, 'w').write(src.rstrip() + '\n\n' + guard)
WFOAUTHEOF

        java -jar "${smali_jar}" assemble -j 1 \
            "${patch_dir}/smali" -o "${patch_dir}/classes.dex"

        cp -- "${jar}" "${patch_dir}/mediatek-wfo-legacy.jar"
        zip -q -d "${patch_dir}/mediatek-wfo-legacy.jar" classes.dex
        touch -d '2008-01-01 00:00:00 UTC' "${patch_dir}/classes.dex"
        (
            cd "${patch_dir}"
            zip -q -X mediatek-wfo-legacy.jar classes.dex
        )
        unzip -tq "${patch_dir}/mediatek-wfo-legacy.jar" >/dev/null
        dex_sha="$(sha256sum "${patch_dir}/classes.dex" | awk '{ print $1 }')"
        if [[ "${dex_sha}" != "${patched_dex_sha}" ]]; then
            echo "Non-reproducible patched WFO classes.dex: ${dex_sha}" >&2
            exit 1
        fi
        jar_sha="$(sha256sum "${patch_dir}/mediatek-wfo-legacy.jar" | awk '{ print $1 }')"
        if [[ "${jar_sha}" != "${patched_jar_sha}" ]]; then
            echo "Non-reproducible patched mediatek-wfo-legacy.jar: ${jar_sha}" >&2
            exit 1
        fi
        chmod 0644 "${patch_dir}/mediatek-wfo-legacy.jar"
        mv -f -- "${patch_dir}/mediatek-wfo-legacy.jar" "${jar}"
    )
}

function blob_fixup() {
    case "$1" in
        system/priv-app/ImsService/ImsService.apk)
            patch_ims_apk "$2" || exit 1
            ;;
        system/framework/mediatek-wfo-legacy.jar)
            patch_wfo_jar "$2" || exit 1
            ;;
        vendor/etc/init/rilproxy.rc)
            # Load the device tree's RIL shim instead of mtk-rilproxy.so. The
            # shim dlopens the blob, returns the fixed truthful capability of
            # each physical protocol stack, and absorbs AOSP's attempted swap
            # as a synthetic transaction. MediaTek's real switch hangs this
            # modem with both radios UNAVAILABLE and is a no-op even when it
            # completes; the blob addresses and host tests are in ril-shim/.
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "977b91d4b168d17f8fbedd65c98534634f8e403c6d721b3757581aff3182c4bf" ]]; then
                echo "Refusing to patch an unknown rilproxy.rc" >&2
                exit 1
            fi
            sed -i -E \
                's|(/vendor/bin/hw/rilproxy) -l mtk-rilproxy\.so|\1 -l libril-k50sv1-shim.so|' "$2"
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "40e110c046ee532b272cd3a0324fa43673c60aa9fbd62b02f5bfb0d446fda4ca" ]]; then
                echo "rilproxy.rc shim rewrite is not reproducible" >&2
                exit 1
            fi
            ;;
        vendor/lib64/librilmtk.so)
            # This modem-side library publishes getVersion() on private RIL
            # connection setup. Keep it in the vendor property namespace;
            # librilproxy still owns AOSP's gsm.version.ril-impl diagnostic.
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "69981722f45545a9c468853bf8b32b5016a9ba68ad2e1c99fccba36277717956" ]] || \
               [[ "$(LC_ALL=C grep -aoF 'gsm.version.ril-impl' "$2" | wc -l)" -ne 1 ]]; then
                echo "Refusing to patch an unknown librilmtk.so version property" >&2
                exit 1
            fi
            LC_ALL=C perl -0pi -e \
                's{\Qgsm.version.ril-impl\E\0}{"vendor.ril.impl" . ("\0" x 6)}ge' "$2"
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "4b63af5d16f24fb3a1cce24f5f334aa4a0d80f07a055c525c9a11e1abc0c61df" ]]; then
                echo "librilmtk.so version-property rewrite is not reproducible" >&2
                exit 1
            fi
            ;;
        vendor/lib/libcam.paramsmgr.so)
            # Limit the picture tables to 12 IMX145 and 11 GC5025 entries.
            # JPEG dimensions of the removed 3264x1836 and 2592x1944 modes
            # are 3264x1840 and 2592x1952, respectively.
            # Both defaults and all focus metadata stay intact.
            python3 - "$2" <<'CAMERASIZEEOF' || exit 1
import hashlib
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
input_sha = "c718ded972a72928e293e40f0079dd50834955f9948d003a98033f331bb79f64"
output_sha = "25fe4a83ce842d4b532a6f77ae223a8aa526652eb623d018b126f6aae2365f02"
count_updates = {0x48748: 12, 0x8c9d4: 11}  # Thumb movs r3, #count
sizes = (
    "320x240", "640x480", "1024x768", "1280x720", "1280x768",
    "1280x960", "1600x1200", "1920x1088", "2048x1536", "2560x1440",
    "2560x1920", "3264x2448", "3264x1836", "3600x2160", "3840x2176",
)
front_sizes = sizes[:11] + ("2592x1944", "2864x1600")
with path.open("r+b") as blob:
    original = blob.read()
    if hashlib.sha256(original).hexdigest() != input_sha:
        raise SystemExit("Refusing to patch an unknown or modified libcam.paramsmgr.so")
    if (len(original) != 0x9ad98 or original[:7] != b"\x7fELF\x01\x01\x01"
            or struct.unpack_from("<H", original, 18)[0] != 40):
        raise SystemExit("Unexpected camera parameter ELF layout")
    if original[0x48744:0x48752] != bytes.fromhex("48 46 f8 c1 0f 23 73 49 79 44 d6 f7 13 ff"):
        raise SystemExit("Unexpected IMX145 picture-size count instruction")
    if original[0x8c9ce:0x8c9e2] != bytes.fromhex("90 e8 f8 00 f8 c1 0d 23 6c 49 1a af 38 46 79 44 92 f7 cb fd"):
        raise SystemExit("Unexpected GC5025 picture-size count instruction")

    # Thumb PC-relative literals select this picture table and its default.
    table_offset = struct.unpack_from("<i", original, 0x48914)[0] + 0x4873a
    default_offset = struct.unpack_from("<i", original, 0x48918)[0] + 0x48750
    if table_offset != 0x97768:
        raise SystemExit("Unexpected IMX145 picture-size table reference")
    if default_offset != 0x129e0 or original[default_offset:default_offset + 10] != b"3264x2448\0":
        raise SystemExit("Unexpected IMX145 default picture size")

    front_table_offset = struct.unpack_from("<i", original, 0x8cb84)[0] + 0x8c9c8
    front_default_offset = struct.unpack_from("<i", original, 0x8cb88)[0] + 0x8c9e0
    if front_table_offset != 0x98548:
        raise SystemExit("Unexpected GC5025 picture-size table reference")
    if front_default_offset != 0x14349 or original[front_default_offset:front_default_offset + 10] != b"2560x1920\0":
        raise SystemExit("Unexpected GC5025 default picture size")

    for sensor, offset, entries in (("IMX145", table_offset, sizes),
                                     ("GC5025", front_table_offset, front_sizes)):
        pointers = struct.unpack_from(f"<{len(entries)}I", original, offset)
        for pointer, size in zip(pointers, entries):
            if original[pointer:pointer + len(size) + 1] != size.encode("ascii") + b"\0":
                raise SystemExit(f"Unexpected {sensor} picture-size table entry")

    patched = bytearray(original)
    for offset, count in count_updates.items():
        patched[offset] = count
    if hashlib.sha256(patched).hexdigest() != output_sha:
        raise SystemExit("Camera picture-size fixup is not reproducible")
    for offset in count_updates:
        blob.seek(offset)
        if blob.write(patched[offset:offset + 1]) != 1:
            raise SystemExit("Failed to write a camera picture-size count")
CAMERASIZEEOF
            ;;
        vendor/lib/libmal.so|vendor/lib/libmal_epdga.so|\
        vendor/lib/libmal_nwmngr.so|vendor/lib/libmal_rds.so|\
        vendor/lib64/libmal.so)
            # MAL predates Treble and names the old core-data control socket.
            # Use an equal-or-shorter device-owned path under /data/vendor so
            # wpa_supplicant and MAL share wpa_data_file without a bind mount.
            local expected_input expected_output expected_paths
            case "$1" in
                vendor/lib/libmal.so)
                    expected_input=ffa030eca4e81f4497996d886266c052cc73eb45a274b5aa1ccf9d0800884af1
                    expected_output=cdc412e1ed88f34c1c1542eb20c54536f3c5002898828633ba66e87805611631
                    expected_paths=6
                    ;;
                vendor/lib/libmal_epdga.so)
                    expected_input=a6643d1da8bba4c0f94fb92e72bcc057589cc044cb5df3f04208134f1cef5a4a
                    expected_output=48493993b50f39bad564fbd4961d2b9841b133d8f59c76d49755229b14e3c5c1
                    expected_paths=4
                    ;;
                vendor/lib/libmal_nwmngr.so)
                    expected_input=0e1a455b8780e7dc629f6cc4530f96e9a0b0b33ef56934cfac3392a2110705ca
                    expected_output=c8e4e88582582aeabe8129e381381f8f4dc161c2dc61e71cf81ea0d0622ab888
                    expected_paths=2
                    ;;
                vendor/lib/libmal_rds.so)
                    expected_input=8cd3418b43eae7f19592172fe355e377cc07c5f5e7a61ffd30e2abb441912a85
                    expected_output=577be04201426ebb06cceab590e6d452cb2dd243245a717cdce96aaaffa622f7
                    expected_paths=2
                    ;;
                vendor/lib64/libmal.so)
                    expected_input=02c4014e2f972573ff673cd07ed7f0e4432debbd38cef962979540012506bea7
                    expected_output=c3345c427a0ab95594122a99f8b154cb54fd98c6e0a2ba987069d5b9753b9bc6
                    expected_paths=6
                    ;;
            esac
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != "${expected_input}" ]] || \
               [[ "$(LC_ALL=C grep -aoF '/data/misc/wifi/sockets' "$2" | wc -l)" -ne \
                  "${expected_paths}" ]]; then
                echo "Refusing to patch unknown MAL socket paths in $1" >&2
                exit 1
            fi
            LC_ALL=C perl -0pi -e '
                s{\Q/data/misc/wifi/sockets/wlan0\E}{"/data/vendor/wifi/sock/wlan0\0"}ge;
                s{\Q/data/misc/wifi/sockets/ea_ctrlconn\E}{"/data/vendor/wifi/sock/ea_ctrlconn\0"}ge;
                s{\Q/data/misc/wifi/sockets/rds_ctrlconn\E}{"/data/vendor/wifi/sock/rds_ctrlconn\0"}ge;
                s{\Q/data/misc/wifi/sockets/nwmngr_ctrlconn\E}{"/data/vendor/wifi/sock/nwmngr_ctrlconn\0"}ge;
            ' "$2"
            if LC_ALL=C grep -aqF '/data/misc/wifi/sockets' "$2" || \
               [[ "$(LC_ALL=C grep -aoF '/data/vendor/wifi/sock' "$2" | wc -l)" -ne \
                  "${expected_paths}" ]] || \
               [[ "$(sha256sum "$2" | awk '{ print $1 }')" != "${expected_output}" ]]; then
                echo "MAL socket-path rewrite is not reproducible for $1" >&2
                exit 1
            fi
            ;;
        vendor/bin/volte_stack)
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "db8d700b84adf95206c497c15acaa70524756183a5de876391effd5dab734edc" ]]; then
                echo "Refusing to patch an unknown volte_stack" >&2
                exit 1
            fi
            # Full-Treble vendor namespaces reject dlopen paths containing an
            # inaccessible /system/lib prefix. Preserve binary layout while
            # switching to the public LLNDK SONAME resolved through the linked
            # system namespace; retain libandroid.so as the legacy fallback.
            perl -0pi -e '
                s{\Q/system/lib/libandroid_net.so\E}{"libandroid_net.so" . ("\x00" x 12)}e;
                s{\Q/system/lib/libandroid.so\E}{"libandroid.so" . ("\x00" x 12)}e;
            ' "$2"
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "d6d74be9db1adf75f548d5585ac1e244656f2b2136135320564567a0886e2eb0" ]]; then
                echo "VoLTE stack linker-namespace fixup is not reproducible" >&2
                exit 1
            fi
            ;;
        vendor/bin/hw/android.hardware.wifi@1.0-service-lazy-mediatek)
            local match_count
            match_count=$(LC_ALL=C grep -ao 'libwifi-hal\.so' "$2" | wc -l)
            if [[ "${match_count}" -ne 1 ]]; then
                echo "Unexpected libwifi-hal dependency count: ${match_count}" >&2
                exit 1
            fi
            LC_ALL=C perl -0pi -e \
                's/libwifi-hal\.so/libmtk-wifi.so/g' "$2"
            if ! LC_ALL=C grep -aq 'libmtk-wifi\.so' "$2" || \
               LC_ALL=C grep -aq 'libwifi-hal\.so' "$2"; then
                echo "Wi-Fi HAL service SONAME rewrite did not take" >&2
                exit 1
            fi
            ;;
        vendor/lib64/libmtk-wifi.so)
            local match_count
            match_count=$(LC_ALL=C grep -ao 'libwifi-hal\.so' "$2" | wc -l)
            if [[ "${match_count}" -ne 1 ]]; then
                echo "Unexpected libwifi-hal SONAME count: ${match_count}" >&2
                exit 1
            fi
            LC_ALL=C perl -0pi -e \
                's/libwifi-hal\.so/libmtk-wifi.so/g' "$2"
            if ! LC_ALL=C grep -aq 'libmtk-wifi\.so' "$2" || \
               LC_ALL=C grep -aq 'libwifi-hal\.so' "$2"; then
                echo "Wi-Fi HAL SONAME rewrite did not take" >&2
                exit 1
            fi
            ;;
    esac
}

# Resolve -s/--section against the section tags in proprietary-files.txt.
#
# extract_utils turns --section into
#     sed -n '/^[[:space:]]*#.*<name>/I,/^[[:space:]]*$/p'
# i.e. it starts at the FIRST comment line containing the string and stops at
# the next blank line. A bare subsystem word therefore selects whichever comment
# happens to mention it first, which is usually not the section header:
# "graphics" hit the Soong error quoted in the file header and extracted nothing
# at all, "media" hit a frameworks/av/media path in the Audio section, and "ims"
# hit the Radio section's note about the voice IMS closure.
#
# Every section header carries a "-- section: <tag>" suffix. Translate the tag
# the user typed into that full string, which appears nowhere else, and refuse
# anything that does not resolve to exactly one section rather than silently
# extracting the wrong range.
function resolve_section() {
    local requested="$1"
    local list="${MY_DIR}/proprietary-files.txt"
    local matches

    # An explicit "section: foo" is passed through, so the raw extract_utils
    # behaviour stays reachable for anything this table does not cover.
    if [[ "${requested}" == section:* ]]; then
        printf '%s' "${requested}"
        return 0
    fi

    # The guard is anchored; extract_utils' own section range is NOT (it is
    # unanchored and case-insensitive, extract_utils.sh:1127). So a tag that is
    # a strict PREFIX of another -- "media" against a future "media-hifi" --
    # would pass this grep with a count of 1 while the sed opened at both
    # headers and silently extracted the union, which is exactly the failure
    # proprietary-files.txt's header claims is impossible. No pair collides
    # among the current tags; the prefix test below keeps it that way.
    matches="$(grep -c -- "-- section: ${requested}\$" "${list}" || true)"
    if [[ "${matches}" -eq 1 ]]; then
        local prefixed
        prefixed="$(sed -n 's/^#.*-- section: \([A-Za-z0-9_-]\{1,\}\)$/\1/p' "${list}" \
            | grep -c -- "^${requested}." || true)"
        if [[ "${prefixed}" -ne 0 ]]; then
            echo "Section '${requested}' is a prefix of ${prefixed} other section tag(s)." >&2
            echo "extract_utils' section range is unanchored, so this would extract their union." >&2
            echo "Rename the tags so none is a prefix of another." >&2
            exit 1
        fi
    fi
    if [[ "${matches}" -ne 1 ]]; then
        {
            echo "Unknown --section '${requested}'. Known sections:"
            # Anchored and character-restricted: an unanchored ".*" also
            # matches the prose in proprietary-files.txt's own header, which
            # made this print a bogus 19th "section".
            sed -n 's/^#.*-- section: \([A-Za-z0-9_-]\{1,\}\)$/  \1/p' "${list}" | sort
            echo
            echo "Pass 'section: <tag>' verbatim to bypass this check."
        } >&2
        exit 1
    fi
    printf 'section: %s' "${requested}"
}

if [[ -n "${SECTION}" ]]; then
    SECTION="$(resolve_section "${SECTION}")"
fi

# Prefer the immutable offline extraction over the Magisk-modified handset.
if [[ -z "${SRC}" ]]; then
    SRC="${LINEAGE_ROOT}/../factory_image_unpacked"
fi

# extract_utils accepts adb, a directory or a non-A/B extraction zip.
if [[ "${SRC}" != "adb" && ! -d "${SRC}" ]] &&
        [[ ! -f "${SRC}" || "${SRC##*.}" != "zip" ]]; then
    echo "Extraction source is not adb, a directory or a .zip: ${SRC}" >&2
    exit 1
fi

setup_vendor "${DEVICE}" "${VENDOR}" "${LINEAGE_ROOT}" false "${CLEAN_VENDOR}"

VENDOR_OUTPUT="$(cd "${LINEAGE_ROOT}/${OUTDIR}" && pwd -P)"
PROPRIETARY_ROOT="${VENDOR_OUTPUT}/proprietary"
[[ ! -L "${PROPRIETARY_ROOT}" ]] || {
    echo "Refusing to extract through a symlinked proprietary directory: ${PROPRIETARY_ROOT}" >&2
    exit 1
}
BACKUP_DIR="$(mktemp -d "${VENDOR_OUTPUT}/.extract-backup.XXXXXX")"
BACKUP_READY=false
BACKUP_FILES=(proprietary Android.bp Android.mk BoardConfigVendor.mk "${DEVICE}-vendor.mk")

# extract_utils moves the previous clean payload into its disposable TMPDIR.
# Keep an independent snapshot, including generated files, until all steps pass.
finish_extraction() {
    local status=$1
    trap - EXIT
    if [[ "${status}" -ne 0 && "${BACKUP_READY}" == true ]]; then
        for name in "${BACKUP_FILES[@]}"; do
            if ! rm -rf -- "${VENDOR_OUTPUT}/${name}" ||
                    { [[ -e "${BACKUP_DIR}/${name}" || -L "${BACKUP_DIR}/${name}" ]] &&
                      ! mv -- "${BACKUP_DIR}/${name}" "${VENDOR_OUTPUT}/${name}"; }; then
                echo "Restore failed; previous vendor data remains in ${BACKUP_DIR}" >&2
                cleanup
                exit 1
            fi
        done
        echo "Extraction failed; previous vendor payload and makefiles restored." >&2
    fi
    rm -rf -- "${BACKUP_DIR}"
    cleanup
    exit "${status}"
}
trap 'finish_extraction "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for name in "${BACKUP_FILES[@]}"; do
    if [[ -e "${VENDOR_OUTPUT}/${name}" || -L "${VENDOR_OUTPUT}/${name}" ]]; then
        cp -a --reflink=auto -- "${VENDOR_OUTPUT}/${name}" "${BACKUP_DIR}/${name}"
    fi
done
BACKUP_READY=true

extract "${MY_DIR}/proprietary-files.txt" "${SRC}" ${KANG} --section "${SECTION}"
# The helper briefly disables errexit and treats missing source files as skips.
extract_status=$?
set -e
[[ "${extract_status}" -eq 0 ]] || exit "${extract_status}"
[[ $(( ${#PRODUCT_COPY_FILES_LIST[@]} + ${#PRODUCT_PACKAGES_LIST[@]} )) -gt 0 ]] || {
    echo "No proprietary files selected" >&2
    exit 1
}
for spec in "${PRODUCT_COPY_FILES_LIST[@]}" "${PRODUCT_PACKAGES_LIST[@]}"; do
    output="${PROPRIETARY_ROOT}/$(target_file "${spec}")"
    if [[ "$(target_args "${spec}")" == rootfs ]]; then
        output="${PROPRIETARY_ROOT}/rootfs/$(target_file "${spec}")"
    fi
    [[ -f "${output}" ]] || { echo "Missing extracted file: ${output}" >&2; exit 1; }
done

(
    set -o pipefail
    cd "${PROPRIETARY_ROOT}"
    find . \( -type f -o -type l \) ! -name SHA256SUMS -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum >SHA256SUMS
)

"${MY_DIR}/setup-makefiles.sh" "${LINEAGE_ROOT}"
