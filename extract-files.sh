#!/bin/bash

set -e

DEVICE=k50sv1_64_bsp
VENDOR=xsh

MY_DIR="${BASH_SOURCE%/*}"
if [[ ! -d "${MY_DIR}" ]]; then
    MY_DIR="${PWD}"
fi

LINEAGE_ROOT="${MY_DIR}/../../.."
HELPER="${LINEAGE_ROOT}/vendor/lineage/build/tools/extract_utils.sh"

if [[ ! -f "${HELPER}" ]]; then
    echo "Unable to find extract_utils.sh at ${HELPER}" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${HELPER}"

GATEKEEPER_STAGE=

function device_cleanup() {
    if [[ -n "${GATEKEEPER_STAGE}" ]]; then
        rm -f -- "${GATEKEEPER_STAGE}"
    fi
    cleanup
}

# extract_utils installs its own EXIT trap when sourced. Extend it so a failed
# extraction cannot leave the gatekeeper staging file in the vendor repository.
trap device_cleanup EXIT

function stage_gatekeeper_blob() {
    local expected_sha="a48349adba6e54500fb39cd4604a8d0979057728b88b7268719d5a8464fc6f9a"
    local source_path="/system/vendor/lib64/hw/libSoftGatekeeper.so"
    local vendor_root="${LINEAGE_ROOT}/vendor/${VENDOR}/${DEVICE}"
    local actual_sha
    local zip_entry

    GATEKEEPER_STAGE="$(mktemp "${vendor_root}/.gatekeeper.default.so.XXXXXX")"

    if [[ "${SRC}" == "adb" ]]; then
        init_adb_connection
        if ! get_file "${source_path}" "${GATEKEEPER_STAGE}" "${SRC}"; then
            echo "Unable to fetch ${source_path} from adb" >&2
            exit 1
        fi
    elif [[ -f "${SRC}" && "${SRC##*.}" == "zip" ]]; then
        for zip_entry in \
            "${source_path#/system/}" \
            "${source_path#/}" \
            "system/${source_path#/}"; do
            if unzip -p "${SRC}" "${zip_entry}" >"${GATEKEEPER_STAGE}" 2>/dev/null && \
                    [[ -s "${GATEKEEPER_STAGE}" ]]; then
                break
            fi
            : >"${GATEKEEPER_STAGE}"
        done
        if [[ ! -s "${GATEKEEPER_STAGE}" ]]; then
            echo "Unable to fetch ${source_path} from ${SRC}" >&2
            exit 1
        fi
    elif ! get_file "${source_path}" "${GATEKEEPER_STAGE}" "${SRC}"; then
        echo "Unable to fetch ${source_path} from ${SRC}" >&2
        exit 1
    fi

    if [[ -L "${GATEKEEPER_STAGE}" || ! -s "${GATEKEEPER_STAGE}" ]]; then
        echo "Fetched libSoftGatekeeper.so is not a regular non-empty file" >&2
        exit 1
    fi
    actual_sha="$(sha256sum "${GATEKEEPER_STAGE}" | awk '{ print $1 }')"
    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
        echo "Refusing unknown libSoftGatekeeper.so: ${actual_sha}" >&2
        exit 1
    fi
    chmod 0644 "${GATEKEEPER_STAGE}"
}

function patch_ims_apk() {
    local apk="$1"
    local expected_apk_sha="06e62235bc7b30655f5dfcd2efaa7ab6a9b4c6f1efd6a6f8ce49ce1e62da3ff5"
    local expected_dex_sha="6aa7926e7974420e7fc5ea6e96c5287617a6a826dc60a46a7996f793bd986deb"
    local baksmali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/baksmali.jar"
    local smali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/smali.jar"
    local apk_sha
    local dex_sha
    local patch_dir

    apk_sha="$(sha256sum "${apk}" | awk '{ print $1 }')"
    if [[ "${apk_sha}" != "${expected_apk_sha}" ]]; then
        echo "Refusing to patch an unknown ImsService.apk: ${apk_sha}" >&2
        return 1
    fi
    for tool in java unzip zip; do
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
        # These two pins are reproducibility gates, not integrity gates: the
        # input APK is already SHA-256 checked above. They exist so that a
        # toolchain change, a resource-ID shift or an unintended smali edit is a
        # loud failure. Both were re-derived when the WFO startup call stopped
        # being deleted (E-087); the previous values were
        # 3d604f601fe96110598fdda69f675f16751e6b78c47275b9225686b4fcb58a1c and
        # 022d324338cdfac31c78c4babb4871eca311d72b35c9fe2349ab7986a5d91e6e.
        # Both new values were confirmed to reproduce across two runs, and the
        # resulting dex was checked to carry the four LINEAGE resource IDs and
        # exactly one makeWfoService() call.
        dex_sha="$(unzip -p "${patch_dir}/ImsService.apk" classes.dex \
            | sha256sum | awk '{ print $1 }')"
        if [[ "${dex_sha}" != \
              "d5bfa7cca540029899e48040aadc35fde6e5846cb2150d0e70b5263e1f00d638" ]]; then
            echo "Non-reproducible patched IMS classes.dex: ${dex_sha}" >&2
            exit 1
        fi
        apk_sha="$(sha256sum "${patch_dir}/ImsService.apk" | awk '{ print $1 }')"
        if [[ "${apk_sha}" != \
              "c762f544596c1066c1ed36feb78ee00d7035262bf087572a7c8026f2f8629a8b" ]]; then
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
    local baksmali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/baksmali.jar"
    local smali_jar="${LINEAGE_ROOT}/prebuilts/tools-lineage/common/smali/smali.jar"
    local jar_sha
    local dex_sha
    local patch_dir

    jar_sha="$(sha256sum "${jar}" | awk '{ print $1 }')"
    if [[ "${jar_sha}" != "${expected_jar_sha}" ]]; then
        echo "Refusing to patch an unknown mediatek-wfo-legacy.jar: ${jar_sha}" >&2
        return 1
    fi
    for tool in java unzip zip; do
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
if (service.count(private) != 1 or 'access$6000' in service
        or cleanup_sig in service
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
service = service.replace(private, accessor + cleanup + private, 1)

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
        if [[ "${dex_sha}" != \
              "95f0be95eec46c729d560bd9992f8437b662d4fb2ce46ca6d0df08d430d67e62" ]]; then
            echo "Non-reproducible patched WFO classes.dex: ${dex_sha}" >&2
            exit 1
        fi
        jar_sha="$(sha256sum "${patch_dir}/mediatek-wfo-legacy.jar" | awk '{ print $1 }')"
        if [[ "${jar_sha}" != \
              "899a5149c2ca85a1d2bfadf02fcb419a860133becc9c9716d1482b1438bef3c2" ]]; then
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
        vendor/lib64/hw/gatekeeper.default.so)
            # Stock stores this as a symlink to a byte-identical
            # libSoftGatekeeper.so, and extract_utils probes the destination
            # name before the source name. Do not try to dereference that link
            # after extraction: a clean or section-only output need not contain
            # its target. stage_gatekeeper_blob fetched and pinned the target
            # directly from the active source before extract_utils ran.
            local expected_gatekeeper_sha="a48349adba6e54500fb39cd4604a8d0979057728b88b7268719d5a8464fc6f9a"
            local staged_gatekeeper_sha
            if [[ -z "${GATEKEEPER_STAGE}" || ! -f "${GATEKEEPER_STAGE}" ]]; then
                echo "Missing staged libSoftGatekeeper.so" >&2
                exit 1
            fi
            staged_gatekeeper_sha="$(sha256sum "${GATEKEEPER_STAGE}" | awk '{ print $1 }')"
            if [[ "${staged_gatekeeper_sha}" != "${expected_gatekeeper_sha}" ]]; then
                echo "Staged libSoftGatekeeper.so changed: ${staged_gatekeeper_sha}" >&2
                exit 1
            fi
            # The stage and vendor output are in the same repository, so rename
            # atomically replaces the extracted symlink (or any prior file).
            mv -f -- "${GATEKEEPER_STAGE}" "$2" || exit 1
            GATEKEEPER_STAGE=
            rm -f -- "$(dirname "$2")/libSoftGatekeeper.so"
            if [[ -L "$2" || ! -s "$2" ]] || \
               [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "${expected_gatekeeper_sha}" ]] || \
               [[ -e "$(dirname "$2")/libSoftGatekeeper.so" || \
                  -L "$(dirname "$2")/libSoftGatekeeper.so" ]]; then
                echo "gatekeeper.default.so publication failed" >&2
                exit 1
            fi
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
        vendor/etc/init/mtkrild.rc)
            # These names look like an optional VSIM feature, but rilproxy
            # opens rild-vsim unconditionally and retries once per second when
            # it is absent. They are a private channel in the two-stage vendor
            # RIL ABI, not a declaration that this chassis offers virtual SIM.
            # Preserve all three stock endpoints and grant only rild's stock
            # sock_file write edge in device policy.
            if [[ "$(sha256sum "$2" | awk '{ print $1 }')" != \
                  "3c5d36df6d1b8b6ff8157bde278b914521c345ca278dacb3725c68d55af1e7cd" ]]; then
                echo "Refusing to patch an unknown mtkrild.rc" >&2
                exit 1
            fi
            local vsim_socket_count
            vsim_socket_count=$(LC_ALL=C grep -Ec \
                '^[[:space:]]+socket rild-vsim(2|3)? stream 660 root radio$' "$2")
            if [[ "${vsim_socket_count}" -ne 3 ]]; then
                echo "Unexpected mtkrild.rc VSIM socket count: ${vsim_socket_count}" >&2
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

CLEAN_VENDOR=true
SECTION=
KANG=
SRC=

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n | --no-cleanup)
            CLEAN_VENDOR=false
            ;;
        -k | --kang)
            KANG="--kang"
            ;;
        -s | --section)
            shift
            SECTION="$1"
            CLEAN_VENDOR=false
            ;;
        *)
            SRC="$1"
            ;;
    esac
    shift
done

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

    matches="$(grep -c -- "-- section: ${requested}\$" "${list}" || true)"
    if [[ "${matches}" -ne 1 ]]; then
        {
            echo "Unknown --section '${requested}'. Known sections:"
            sed -n 's/.*-- section: \(.*\)$/  \1/p' "${list}" | sort
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

if [[ "${SRC}" != "adb" && ! -d "${SRC}" ]]; then
    echo "Extraction source does not exist: ${SRC}" >&2
    exit 1
fi

setup_vendor "${DEVICE}" "${VENDOR}" "${LINEAGE_ROOT}" false "${CLEAN_VENDOR}"

# Full extraction and the gatekeeper section both need the symlink target. Fetch
# it explicitly because extract_utils intentionally probes the destination name
# first and therefore extracts Stock's gatekeeper.default.so symlink.
if [[ -z "${SECTION}" || "${SECTION}" == "section: gatekeeper" ]]; then
    stage_gatekeeper_blob
fi

extract "${MY_DIR}/proprietary-files.txt" "${SRC}" ${KANG} --section "${SECTION}"

PROPRIETARY_ROOT="${LINEAGE_ROOT}/vendor/${VENDOR}/${DEVICE}/proprietary"
(
    cd "${PROPRIETARY_ROOT}"
    find . \( -type f -o -type l \) ! -name SHA256SUMS -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum >SHA256SUMS
)

"${MY_DIR}/setup-makefiles.sh"
