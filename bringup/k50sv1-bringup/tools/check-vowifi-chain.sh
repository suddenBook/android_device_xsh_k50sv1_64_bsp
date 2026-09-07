#!/usr/bin/env bash
#
# Walk the VoWiFi (ePDG) chain on a live handset, stage by stage, and say which
# stage it stops at. Companion to check-volte-chain.sh, and it deliberately
# starts by re-checking VoLTE.
#
# WHY VoLTE IS STAGE 1. ImsManager.updateImsServiceConfig() batches VoLTE, WFC
# and video into ONE CapabilityChangeRequest before changeMmTelCapability(). A
# vendor changeEnabledCapabilities() that chokes on the new IWLAN entry takes
# the VoLTE entry down with it -- so "did WFC work" is not the first question.
# "Is VoLTE still working" is. If stage 1 fails, stop and revert the two
# framework booleans before reading anything below it.
#
#   1  VoLTE still registers                (+CIREGU: 1,5 and phone 0 MMTEL voice)
#   2  the ePDG data plane is installed     (5 binaries, 10 libs, the configs)
#   3  wfca and vendor.epdg_wod are running (and nothing has tombstoned)
#   4  the wpa control socket exists        (E-096/E-116: one vendor-data path)
#   5  MAL learns the SIM                   (E-097: notifyMalSimInfo)
#   6  WFC is available by platform         (the two framework booleans)
#   7  epdg_wod resolves an ePDG and brings a tunnel up
#   8  IMS registers over IWLAN
#
# Stages 7 and 8 need a WFC-capable home carrier, the user-facing switch ON and
# Wi-Fi associated. The device overlay now sets carrier_wfc_ims_available_bool
# TRUE for CU and CMCC (E-170), so the carrier gate is no longer the thing that
# stops them; what stops them is the network, and stage 6 SKIPs on whichever of
# the three -- carrier availability, the user switch, Wi-Fi -- is not satisfied.
# An earlier version of this comment said the CU/CMCC carrier gate is
# "correctly false"; that was the defect E-170 fixed, and it contradicted the
# code below, which has always read the live value rather than assuming one.
#
# ENLARGE THE LOG RING FIRST:  adb -s <serial> shell logcat -b all -G 64M
# The reason is check-volte-chain.sh's stage 0, and it applies identically here.
#
# Usage: check-vowifi-chain.sh <adb-serial-or-host:port> [capture-dir]
#
# Nothing here writes to the device.

set -uo pipefail

SERIAL="${1:-}"
CAPTURE="${2:-}"
if [[ -z "${SERIAL}" ]]; then
    echo "usage: $(basename "$0") <adb-serial-or-host:port> [capture-dir]" >&2
    exit 2
fi

ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
WFC_RESOURCE_TOOL="${TOOL_DIR}/check-wfc-framework-resource.sh"
export ADB_LIBUSB="${ADB_LIBUSB:-1}"
if [[ ! -x "${ADB_BIN}" ]]; then
    echo "adb not executable: ${ADB_BIN}" >&2
    exit 2
fi

if [[ -n "${CAPTURE}" ]]; then
    capture_parent="$(dirname "${CAPTURE}")"
    capture_name="$(basename "${CAPTURE}")"
    [[ "${capture_name}" != . && "${capture_name}" != .. && \
       "${capture_name}" != / ]] || {
        echo "unsafe capture directory name: ${CAPTURE}" >&2
        exit 2
    }
    [[ ! -e "${CAPTURE}" && ! -L "${CAPTURE}" ]] || {
        echo "capture destination already exists; refusing to overwrite: ${CAPTURE}" >&2
        exit 2
    }
    [[ -d "${capture_parent}" && ! -L "${capture_parent}" ]] || {
        echo "capture parent must be an existing ordinary directory: ${capture_parent}" >&2
        exit 2
    }
    capture_parent="$(realpath -e "${capture_parent}")"
    CAPTURE="${capture_parent}/${capture_name}"
fi
if ! "${ADB_BIN}" -s "${SERIAL}" get-state >/dev/null 2>&1; then
    echo "device not reachable: ${SERIAL}" >&2
    exit 2
fi

sh_() { "${ADB_BIN}" -s "${SERIAL}" shell "$@" 2>/dev/null | tr -d '\r'; }

pass=0; fail=0; unread=0; skip=0
ok()      { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad()     { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
unread_() { printf '  ????  %s\n' "$*"; unread=$((unread + 1)); }
skip_()   { printf '  SKIP  %s\n' "$*"; skip=$((skip + 1)); }
stage()   { printf '\n== %s ==\n' "$*"; }

# Capture once, match against here-strings. Never `sh_ ... | grep -q`: sh_ is a
# pipeline ending in tr, and under pipefail a grep -q that exits at its first
# match SIGPIPEs tr, whose status then wins -- so a SUCCESSFUL match reads as a
# failure. HANDOFF trap 6, and this file's producers are exactly the long ones.
LOGS="$(sh_ 'logcat -b radio,main,system -d -v threadtime')"
if [[ -z "${LOGS}" ]]; then
    echo "could not read logcat; every stage below would be unreadable" >&2
    exit 2
fi
count() { printf '%s\n' "${LOGS}" | grep -c -- "$1"; }
ordered_transaction_line() {
    local pattern="$1"
    local after="$2"
    local record line_number

    while IFS= read -r record; do
        [[ -n "${record}" ]] || continue
        line_number="${record%%:*}"
        if [[ "${line_number}" =~ ^[0-9]+$ ]] && (( line_number > after )); then
            printf '%s' "${line_number}"
            return 0
        fi
    done < <(printf '%s\n' "${TRANSACTION_LOGS:-}" | grep -n -E "${pattern}" || true)
    return 1
}
if [[ -n "${CAPTURE}" ]]; then
    mkdir -- "${CAPTURE}" || {
        echo "cannot create new capture directory: ${CAPTURE}" >&2
        exit 2
    }
    capture_incomplete="${CAPTURE}/.logcat-combined.txt.incomplete"
    if ! printf '%s\n' "${LOGS}" >"${capture_incomplete}" || \
       [[ ! -s "${capture_incomplete}" ]] || \
       ! chmod 0644 "${capture_incomplete}" || \
       ! mv -T "${capture_incomplete}" "${CAPTURE}/logcat-combined.txt"; then
        echo "cannot write complete capture artifact: ${capture_incomplete}" >&2
        rm -f -- "${capture_incomplete}"
        rmdir "${CAPTURE}" 2>/dev/null || true
        exit 2
    fi
fi

stage "0. the capture window"
ring_line="$(sh_ 'logcat -b radio -g')"
# Match every unit logcat can print, not only MiB. AOSP's default radio ring is
# 256 KiB (system/core/logcat/logcat.cpp), so the single most likely too-small
# reading -- a device that never got ro.logd.size.radio, or one whose ring was
# reset -- matched nothing, fell into the "could not read" arm, and was
# downgraded from a hard `bad` to an unread. This is check-volte-chain.sh's
# stage 0 verbatim.
ring_desc="$(grep -o 'ring buffer is [0-9]* [KMG]iB' <<<"${ring_line}" | tail -1)"
ring_desc="${ring_desc#ring buffer is }"
ring_num="${ring_desc//[^0-9]/}"
case "${ring_desc##* }" in
    KiB) ring_mib=0 ;;
    MiB) ring_mib="${ring_num}" ;;
    GiB) ring_mib=$(( ring_num * 1024 )) ;;
    *)   ring_mib="" ;;
esac
# See check-volte-chain.sh's stage 0 for why the floor is 32 and not 64: that is
# what device.mk ships as ro.logd.size.radio on the diagnostic tiers, so it is
# what a freshly flashed image has before anyone touches it. 64 MiB is for
# deliberately reproducing the IMSM retry loop, not for reading a boot.
if [[ -z "${ring_mib}" ]]; then
    unread_ "could not read the radio ring size; 'logcat -b radio -g' said: ${ring_line:-<nothing>}"
elif (( ring_mib < 32 )); then
    bad "radio ring is ${ring_desc}, under the 32 MiB the diagnostic tiers ship; something shrank it, or this is not a Tier 1/2 image"
else
    ok "radio ring is ${ring_desc}"
fi

stage "1. VoLTE still registers (regression guard -- read this before anything below)"
# The <ext_info> parameter after the state is OPTIONAL, so a registered modem
# can report a bare `+CIREGU: 1`. This used to require the comma
# ('+CIREGU: 1,'*) and would then call a registered handset NOT REGISTERED, on
# the stage labelled "read this before anything below" -- sending the operator
# to revert working framework booleans. It is not hypothetical: this project's
# own evidence holds 2 bare `+CIREGU: 1` records against 13 of `+CIREGU: 1,5`.
# Matched the way check-volte-chain.sh:363 already matched it; the two tools
# read the same URC and could not both be right.
ciregu="$(printf '%s\n' "${LOGS}" | grep -o '+CIREGU: [0-9],\?[0-9]*' | tail -1)"
if [[ -z "${ciregu}" ]]; then
    unread_ "no +CIREGU in this window"
elif grep -qE '\+CIREGU: [1-9]' <<<"${ciregu}"; then
    ok "modem IMS registered (${ciregu})"
else
    bad "modem IMS NOT registered (${ciregu})"
fi
# `dumpsys activity service com.android.phone`, not the TelephonyDebugService
# component: the component form prints nothing on this build. The dump has one
# mMmTelCapabilities line per phone, in phone order, and IMS only ever runs on
# phone 0 here -- so take the FIRST. Phone 1's line reads all-false and matching
# it would invert this verdict.
# Capture, then match a here-string: `sh_ ... | grep -m1` is the SIGPIPE trap
# this file's own header describes. grep exits at the first match, the tr inside
# sh_ takes SIGPIPE if it is still writing, and under pipefail its 141 wins --
# so a successful match can hand back a failure. dumpsys of com.android.phone is
# large enough for that to be the usual case, not the rare one.
phone_service_dump="$(sh_ 'dumpsys activity service com.android.phone')"
mmtel="$(grep -m1 'mMmTelCapabilities' <<<"${phone_service_dump}" || true)"
if [[ "${mmtel}" == *'Voice: true'* ]]; then
    ok "phone 0 MMTEL voice capability true (${mmtel##*mMmTelCapabilities=})"
elif [[ -z "${mmtel}" ]]; then
    unread_ "no mMmTelCapabilities line"
else
    bad "phone 0 MMTEL voice capability LOST -- suspect updateImsServiceConfig batching: ${mmtel##*mMmTelCapabilities=}"
fi

stage "2. the ePDG data plane is installed"
expected_epdg_files="$(printf '%s\n' \
    /vendor/bin/wfca \
    /vendor/bin/epdg_wod \
    /vendor/bin/starter \
    /vendor/bin/charon \
    /vendor/bin/stroke \
    /vendor/lib/libmal_epdga.so \
    /vendor/lib/libwo.so \
    /vendor/lib64/libwo.so \
    /vendor/lib64/libcharon-ss.so \
    /vendor/lib64/libstrongswan.so \
    /vendor/etc/ipsec/wod_optr.conf)"
listing="$(sh_ '
    rc=0
    for path in \
        /vendor/bin/wfca \
        /vendor/bin/epdg_wod \
        /vendor/bin/starter \
        /vendor/bin/charon \
        /vendor/bin/stroke \
        /vendor/lib/libmal_epdga.so \
        /vendor/lib/libwo.so \
        /vendor/lib64/libwo.so \
        /vendor/lib64/libcharon-ss.so \
        /vendor/lib64/libstrongswan.so \
        /vendor/etc/ipsec/wod_optr.conf; do
        if [ -f "${path}" ]; then
            printf "%s\n" "${path}"
        else
            printf "__K50_MISSING=%s\n" "${path}"
            rc=1
        fi
    done
    printf "__K50_FILE_RC=%s\n" "${rc}"
    exit 0
')"
file_rc_lines="$(grep -c '^__K50_FILE_RC=' <<<"${listing}")"
file_rc="$(sed -n 's/^__K50_FILE_RC=//p' <<<"${listing}")"
actual_epdg_files="$(grep '^/vendor/' <<<"${listing}" || true)"
if [[ "${file_rc_lines}" -ne 1 || ! "${file_rc}" =~ ^[01]$ ]]; then
    unread_ "ePDG file probe returned no valid remote status sentinel"
elif [[ "${file_rc}" != 0 ]]; then
    missing_files="$(sed -n 's/^__K50_MISSING=//p' <<<"${listing}")"
    bad "required ePDG ordinary file(s) missing: ${missing_files//$'\n'/, }"
elif [[ "${actual_epdg_files}" == "${expected_epdg_files}" && \
        "$(awk 'NF { count++ } END { print count + 0 }' \
            <<<"${actual_epdg_files}")" -eq 11 ]]; then
    ok "all 11 exact ePDG paths are ordinary files"
else
    bad "ePDG file probe returned an unexpected or duplicate path set"
fi

stage "3. the daemons are running"
for svc in wfca vendor.epdg_wod; do
    state="$(sh_ "getprop init.svc.${svc}")"
    case "${state}" in
        running) ok "init.svc.${svc}=running" ;;
        '')      bad "init.svc.${svc} is unset -- its rc file did not install or did not parse" ;;
        *)       bad "init.svc.${svc}=${state}" ;;
    esac
done
# THE DIRECTORY LISTING IS PROVED SEPARATELY, because it is the half that can
# fail silently. /data/tombstones is drwxrwx--- system system: under a non-root
# adbd the glob does not expand, the loop body runs once on the literal string,
# `[ -f ]` fails, `continue` fires, rc stays 0 -- and "cannot look" became "no
# ePDG process crashed". An absent or undecrypted /data reads the same. rc only
# ever tracked `head` failures, which never run in that case. This tool is used
# on Tier 1/2 where adbd is root, so it was masked; it never asserted that.
tombstone_probe="$(sh_ '
    rc=0
    if [ -d /data/tombstones ] && ls /data/tombstones >/dev/null 2>&1; then
        printf "__K50_TOMBSTONE_LISTABLE=1\n"
    else
        printf "__K50_TOMBSTONE_LISTABLE=0\n"
    fi
    for tombstone in /data/tombstones/tombstone_*; do
        [ -f "${tombstone}" ] || continue
        printf "__K50_TOMBSTONE_FILE=%s\n" "${tombstone}"
        head -n 80 "${tombstone}" || rc=1
    done
    printf "__K50_TOMBSTONE_RC=%s\n" "${rc}"
')"
tombstone_rc="$(sed -n 's/^__K50_TOMBSTONE_RC=//p' \
    <<<"${tombstone_probe}")"
tombstone_rc_count="$(grep -c '^__K50_TOMBSTONE_RC=' \
    <<<"${tombstone_probe}")"
tombstone_files="$(grep -c '^__K50_TOMBSTONE_FILE=' \
    <<<"${tombstone_probe}")"
crashes="$(printf '%s\n' "${tombstone_probe}" | grep -Ec \
    '>>> /vendor/bin/(wfca|epdg_wod|charon|starter|stroke) <<<' || true)"
tombstone_listable="$(sed -n 's/^__K50_TOMBSTONE_LISTABLE=//p' \
    <<<"${tombstone_probe}")"
if [[ "${tombstone_rc_count}" -ne 1 || "${tombstone_rc}" != 0 ]]; then
    unread_ "could not read current tombstone headers"
elif [[ "${tombstone_listable}" != 1 ]]; then
    unread_ "/data/tombstones is not listable from this adb session"
elif [[ "${crashes}" == 0 ]]; then
    ok "no ePDG process appears in ${tombstone_files} retained tombstone header(s)"
else
    bad "${crashes} tombstone header(s) name an ePDG process"
fi

# epdg_wod sizes a per-SIM client array from wo_get_sim_count(), which reads
# persist.vendor.radio.msimmode. If that property is empty when it starts -- as
# it is on a wipe-flash first boot unless the build sets it, because mtk-ril
# does not write it until 3.3 s later -- the array gets ONE element, and the
# first `wosbp=1,...` from MAL indexes past it with no bounds check and
# segfaults on adjacent heap. `Reset settings[1]` is the direct observable of
# the count being right; this is the gate for that, and it is why
# vendor.prop sets msimmode at build time.
slots="$(printf '%s\n' "${LOGS}" | grep -c 'Reset  *settings\[1\] to default')"
msim="$(sh_ 'getprop persist.vendor.radio.msimmode')"
if [[ "${slots}" != 0 ]]; then
    ok "epdg_wod sized itself for 2 SIM slots (msimmode=${msim:-<unset>})"
elif [[ -z "${msim}" ]]; then
    bad "persist.vendor.radio.msimmode is unset -- epdg_wod will size for 1 slot and crash on slot 1"
else
    unread_ "no 'Reset settings[1]' line in this window (msimmode=${msim}); boot may have scrolled out"
fi

stage "4. the wpa control socket (E-096)"
wifi_on="$(sh_ 'dumpsys wifi | head -1')"
supplicant="$(sh_ 'pidof wpa_supplicant')"
if [[ -z "${supplicant}" ]]; then
    unread_ "wpa_supplicant is not running (Wi-Fi state: ${wifi_on:-unknown}); turn Wi-Fi on and re-run"
else
    argv="$(sh_ "cat /proc/${supplicant}/cmdline" | tr '\0' ' ')"
    if [[ "${argv}" == *"-O/data/vendor/wifi/sock"* ]]; then
        ok "wpa_supplicant started with the -O override"
    else
        bad "wpa_supplicant has no -O override; no per-interface socket will exist (argv: ${argv})"
    fi
    if [[ -n "$(sh_ 'ls /data/vendor/wifi/sock/wlan0 2>/dev/null')" ]]; then
        ok "/data/vendor/wifi/sock/wlan0 exists"
    else
        bad "/data/vendor/wifi/sock/wlan0 missing"
    fi
    mounts="$(sh_ mount)"
    if grep -qE '[[:space:]]/data/misc/wifi/sockets[[:space:]]' <<<"${mounts}"; then
        bad "legacy /data/misc/wifi/sockets bind mount is still active"
    else
        ok "legacy core-data Wi-Fi socket path is not bind-mounted"
    fi
    nowpa="$(count "Can't connect to wpa server side")"
    if [[ "${nowpa}" == 0 ]]; then
        ok "MAL never logged \"Can't connect to wpa server side\""
    else
        bad "MAL logged \"Can't connect to wpa server side\" ${nowpa} time(s)"
    fi
fi

stage "5. MAL learns the SIM (E-097)"
simnull="$(count 'notifyMalSimInfo: unexpected result, simType=null')"
if [[ "${simnull}" == 0 ]]; then
    ok "notifyMalSimInfo never bailed on a null card type"
else
    bad "notifyMalSimInfo bailed on simType=null ${simnull} time(s) -- the extract-files smali patch did not land"
fi
uicc="$(sh_ 'getprop vendor.gsm.ril.uicctype')"
[[ -n "${uicc}" ]] && ok "vendor.gsm.ril.uicctype=${uicc}" \
                   || unread_ "vendor.gsm.ril.uicctype is unset; the substitute would fall back to USIM"

stage "6. device and carrier WFC gates"
# Read the merged framework resource from the running system. CarrierConfig can
# truthfully disable WFC for the current Chinese SIMs, but that must not conceal
# a regression in the device-wide framework capability resource.
runtime_framework_res="$(mktemp)"
if [[ ! -x "${WFC_RESOURCE_TOOL}" ]]; then
    unread_ "local merged-resource validator is unavailable: ${WFC_RESOURCE_TOOL}"
elif "${ADB_BIN}" -s "${SERIAL}" exec-out \
        cat /system/framework/framework-res.apk >"${runtime_framework_res}" \
        2>/dev/null && [[ -s "${runtime_framework_res}" ]]; then
    if resource_result="$("${WFC_RESOURCE_TOOL}" \
            --framework-res "${runtime_framework_res}" 2>&1)"; then
        ok "running framework-res resolves config_device_wfc_ims_available=true"
    else
        bad "running framework-res WFC capability is invalid: ${resource_result}"
    fi
else
    unread_ "could not read running /system/framework/framework-res.apk"
fi
rm -f -- "${runtime_framework_res}"
for pair in \
    persist.vendor.mtk_wfc_support=1 \
    persist.vendor.wfc.sys_wfc_support=1 \
    persist.dbg.wfc_avail_ovr=0 \
    persist.dbg.wfc_avail_ovr0=0 \
    persist.dbg.wfc_avail_ovr1=0; do
    prop="${pair%%=*}"; want="${pair#*=}"; got="$(sh_ "getprop ${prop}")"
    [[ "${got}" == "${want}" ]] && ok "${prop}=${got}" \
                                || bad "${prop}=${got:-<unset>} (expected ${want})"
done
# ImsManager.isWfcEnabledByPlatform() ANDs config_device_wfc_ims_available with
# KEY_CARRIER_WFC_IMS_AVAILABLE_BOOL. Neither is a property, so read the carrier
# config dump.
#
# Read the mConfigFromDefaultApp SECTION, not the first match. `dumpsys
# carrier_config` prints THREE blocks per phone, in this order:
#
#   Phone Id = 0
#       Default Values from CarrierConfigManager :   <- AOSP's defaults, FALSE
#       mConfigFromDefaultApp :                      <- where this overlay lands
#       mConfigFromCarrierApp : null
#
# so a `grep -m1` reads AOSP's default and reports the overlay as not applied on
# a device where it did. That is exactly what the first run of this tool did.
carrier_dump_raw="$(sh_ '
    carrier_output="$(dumpsys carrier_config 2>&1)"
    carrier_rc=$?
    printf "%s\n" "${carrier_output}"
    printf "__K50_CARRIER_CONFIG_RC=%s\n" "${carrier_rc}"
')"
carrier_dump_rc="$(sed -n 's/^__K50_CARRIER_CONFIG_RC=//p' \
    <<<"${carrier_dump_raw}")"
carrier_dump="$(sed '/^__K50_CARRIER_CONFIG_RC=/d' <<<"${carrier_dump_raw}")"
carrier_default_sections="$(printf '%s\n' "${carrier_dump}" | awk '
    /^Phone Id[[:space:]]*=/ { phone = $NF; next }
    /^[[:space:]]+mConfigFromDefaultApp[[:space:]]*:/ && phone == 0 { count++ }
    END { print count + 0 }
')"
wfcbool="$(awk '
    /^Phone Id[[:space:]]*=/ { phone = $NF; in_default = 0; next }
    /^[[:space:]]+(Default Values from CarrierConfigManager|mConfigFromDefaultApp|mConfigFromCarrierApp|mOverrideConfigs)[[:space:]]*:/ {
        in_default = (phone == 0 && index($0, "mConfigFromDefaultApp") > 0)
        next
    }
    in_default && /carrier_wfc_ims_available_bool/ { print; exit }' \
    <<<"${carrier_dump}")"
carrier_wfc_available=false
carrier_config_readable=false
if [[ "${carrier_dump_rc}" != 0 || "${carrier_default_sections}" -ne 1 ]]; then
    unread_ "phone-0 CarrierConfig dump/default-app section is unreadable"
elif [[ "$(grep -c '^__K50_CARRIER_CONFIG_RC=' <<<"${carrier_dump_raw}")" -ne 1 ]]; then
    unread_ "CarrierConfig probe returned no unique status sentinel"
else
    carrier_config_readable=true
fi
case "${carrier_config_readable}:${wfcbool}" in
    true:*true*)
        carrier_wfc_available=true
        ok "carrier_wfc_ims_available_bool = true (mConfigFromDefaultApp, phone 0)"
        ;;
    true:*false*)
        skip_ "phone 0 carrier explicitly disables WFC; carrier-dependent stages 7-8 are skipped"
        ;;
    true:*)
        # Availability defaults false. Omission was the truthful result while
        # vendor.xml carried no China Unicom/China Mobile fragment; since E-170
        # those carriers contribute the key as true, so an
        # omission on a CU/CMCC phone 0 now means the flashed image predates the
        # fragment (verify-post-flash.sh names it as a failure). It is not
        # evidence that the overlay failed to load: the global emergency
        # fragment is validated by verify-post-flash.sh separately.
        skip_ "phone 0 carrier contributes no WFC availability; effective default is false and stages 7-8 are skipped"
        ;;
    false:*) ;;
esac

stage "7. epdg_wod brings a tunnel up"
wfc_enable="$(sh_ 'getprop persist.vendor.mtk.wfc.enable')"
TUNNEL_READY=false
TUNNEL_READY_LINE=0
TRANSACTION_LOGS=""
if [[ "${carrier_config_readable}" != true ]]; then
    unread_ "carrier WFC availability could not be evaluated"
elif [[ "${carrier_wfc_available}" != true ]]; then
    skip_ "home carrier does not advertise WFC; no ePDG tunnel is demanded"
elif [[ -z "${wfc_enable}" ]]; then
    unread_ "persist.vendor.mtk.wfc.enable is unreadable"
elif [[ "${wfc_enable}" != 1 ]]; then
    skip_ "persist.vendor.mtk.wfc.enable=${wfc_enable:-<unset>}; turn WFC on in Settings and re-run stages 7-8"
else
    # Judge only the latest native attach transaction. Old success anywhere in
    # the boot ring must not hide a later failure or cellular fallback.
    transaction_start_line=0
    while IFS= read -r query_record; do
        [[ -n "${query_record}" ]] || continue
        query_line="${query_record%%:*}"
        [[ "${query_line}" =~ ^[0-9]+$ ]] && transaction_start_line="${query_line}"
    done < <(printf '%s\n' "${LOGS}" \
        | grep -n -E 'Query \[epdg\.epc\.mnc[0-9]+\.mcc[0-9]+\.pub\.3gppnetwork\.org\]' \
        || true)
    if (( transaction_start_line == 0 )); then
        bad "no current ePDG query starts a native attach transaction"
    else
        TRANSACTION_LOGS="$(sed -n "${transaction_start_line},\$p" <<<"${LOGS}")"
        fqdn="$(printf '%s\n' "${TRANSACTION_LOGS}" \
            | grep -o 'epdg\.epc\.mnc[0-9]*\.mcc[0-9]*\.pub\.3gppnetwork\.org' \
            | sed -n '1p' || true)"
        dns_line="$(ordered_transaction_line \
            'DNS.*((v4|v6) addr_num:[1-9]|status:0, result\(0x[1-9a-fA-F])' 0 || true)"
        auth_line="$(ordered_transaction_line \
            'authentication of .* succeeded' "${dns_line:-0}" || true)"
        ike_line="$(ordered_transaction_line \
            'IKE_SA .* established' "${auth_line:-0}" || true)"
        wifi_rsp_line="$(ordered_transaction_line \
            'setup thru wifi with rsp' "${ike_line:-0}" || true)"
        attach_line="$(ordered_transaction_line \
            'EA ATTACH Success|\+woattach:0,ims,0,' "${ike_line:-0}" || true)"
        # MTK RDS uses 0 for invalid/unassigned, 1 for cellular and 2 for Wi-Fi.
        # E-091's RAT-error loop is the negative control for accepting 0 here.
        wifi_pdn_line="$(ordered_transaction_line \
            'epdgConfig.*isHandOver: [01].*eran_type: 2|responseUnsolDataCallRspToMal.*eran_type:2, cause:0' \
            "${ike_line:-0}" || true)"
        transaction_failures="$(printf '%s\n' "${TRANSACTION_LOGS}" | grep -Eic \
            'Fail to query IP addr|EA ATTACH Failed|setup thru wifi failed|LTE handover to WIFI failed|\+woattach:[^,]*,[^,]*,[1-9][0-9]*,' \
            || true)"

        handover_start_line="$(ordered_transaction_line \
            'LTE handover to WIFI started' 0 || true)"
        handover_success_line=""
        if [[ -n "${handover_start_line}" ]]; then
            handover_success_line="$(ordered_transaction_line \
                'LTE handover to WIFI success' "${handover_start_line}" || true)"
        fi

        if [[ -z "${dns_line}" || -z "${auth_line}" || -z "${ike_line}" || \
              -z "${wifi_rsp_line}" || -z "${attach_line}" || \
              -z "${wifi_pdn_line}" ]]; then
            bad "latest ${fqdn:-ePDG} transaction lacks ordered DNS, authentication, established IKE, Wi-Fi response, attach success, or Wi-Fi PDN evidence"
        elif [[ "${transaction_failures}" -ne 0 ]]; then
            bad "latest ePDG transaction contains ${transaction_failures} native failure outcome(s)"
        elif [[ -n "${handover_start_line}" && -z "${handover_success_line}" ]]; then
            bad "latest LTE-to-WiFi handover started but never reported success"
        else
            TUNNEL_READY=true
            TUNNEL_READY_LINE="${wifi_rsp_line}"
            (( attach_line > TUNNEL_READY_LINE )) && TUNNEL_READY_LINE="${attach_line}"
            (( wifi_pdn_line > TUNNEL_READY_LINE )) && TUNNEL_READY_LINE="${wifi_pdn_line}"
            [[ -n "${handover_success_line}" ]] && \
                (( handover_success_line > TUNNEL_READY_LINE )) && \
                TUNNEL_READY_LINE="${handover_success_line}"
            ok "latest ${fqdn} transaction established authenticated IKE and a successful Wi-Fi IMS PDN"
        fi

        charon_pid="$(sh_ 'pidof charon')"
        [[ -n "${charon_pid}" ]] && \
            printf '        progress only: charon pid %s (liveness is not tunnel proof)\n' \
                "${charon_pid}"
    fi
fi

stage "8. IMS over IWLAN"
if [[ "${carrier_config_readable}" != true ]]; then
    unread_ "carrier WFC availability could not be evaluated for IWLAN registration"
elif [[ "${carrier_wfc_available}" != true ]]; then
    skip_ "home carrier does not advertise WFC; IWLAN registration is outside this fixture"
elif [[ -z "${wfc_enable}" ]]; then
    unread_ "WFC switch state is unreadable"
elif [[ "${wfc_enable}" != 1 ]]; then
    skip_ "WFC is off; IWLAN registration cannot be demanded"
else
    # E-100 proved the framework imsRadioTech=1 callback can be emitted while
    # the vendor stack is still on LTE. The authoritative MTK line is the
    # vendor ImsService registration conversion: raw RAT 18 -> tech 1. Require
    # it only after the native tunnel predicate, then require a later slot-0
    # Voice:true capability event and the current phone-service capability.
    if [[ "${TUNNEL_READY}" != true ]]; then
        bad "IWLAN registration cannot pass because no native Wi-Fi IMS PDN was proven"
    else
        vendor_iwlan_line="$(ordered_transaction_line \
            'ImsService: \[0\] state 2 updateImsRegstration, tech 1' \
            "${TUNNEL_READY_LINE}" || true)"
        voice_line="$(ordered_transaction_line \
            '\[0\].*MmTel Capabilities.*Voice: true' \
            "${vendor_iwlan_line:-0}" || true)"
        if [[ -n "${vendor_iwlan_line}" && -n "${voice_line}" && \
              "${mmtel}" == *'Voice: true'* ]]; then
            ok "vendor ImsService registered slot 0 on IWLAN and later exposed MMTEL voice"
        else
            bad "latest native tunnel lacks a later vendor tech-1 registration and slot-0 Voice:true capability"
        fi
        callback_count="$(printf '%s\n' "${TRANSACTION_LOGS}" | grep -Eic \
            '(ImsPhoneCallTracker|ImsSmsDispacher).*imsRadioTech=1' || true)"
        printf '        framework imsRadioTech callback lines: %s (corroboration only)\n' \
            "${callback_count}"
    fi
fi

stage "9. the initial-attach APN re-send (E-095)"
armed="$(count 'attach-APN re-send armed')"
if [[ "${armed}" != 0 ]]; then
    ok "the RIL shim armed its attach-APN hooks"
else
    hookfail="$(grep -m1 'attach-APN hooks NOT installed' <<<"${LOGS}" || true)"
    [[ -n "${hookfail}" ]] && bad "the shim could not install its hooks: ${hookfail#* }" \
                           || unread_ "no 'attach-APN re-send armed' line -- boot may have scrolled out of this window"
fi
# The counts are INFORMATION, not a verdict, and the reason matters.
#
# `this_is_an_invalid_apn` is written at EVERY BOOT, not only after an airplane
# cycle. Measured: the IA cache lives in the NON-persistent vendor.ril.radio.ia
# while the password flag lives in the PERSISTENT
# persist.vendor.radio.ia-pwd-flag, so on a cold boot the flag is 1 and the
# cache is empty -- "empty IA property", "empty IA due to password", clear,
# write the sentinel, emit the URC. The framework then sends a real
# SET_INITIAL_ATTACH_APN on records-loaded and slot 0 attaches normally.
#
# The shim has nothing cached at that point and correctly does NOT re-send.
# So a boot-time burst with zero re-sends is the EXPECTED state and must not be
# reported as a regression. What E-092 actually costs is slot 0's attach, so
# that is what this gate reads.
invalid="$(count 'this_is_an_invalid_apn')"
resent="$(count 're-sending SET_INITIAL_ATTACH_APN')"
printf '        sentinel APN written %s time(s); shim re-sent %s time(s)\n' \
    "${invalid}" "${resent}"
opnum="$(sh_ 'getprop gsm.operator.numeric')"
if [[ "${opnum}" == ,* || -z "${opnum}" ]]; then
    bad "gsm.operator.numeric=${opnum:-<unset>} -- slot 0 has no operator, which is E-092's symptom"
else
    ok "gsm.operator.numeric=${opnum} -- slot 0 is attached"
fi

printf '\n%s: %d pass, %d fail, %d unread, %d intentionally skipped\n' \
    "$(basename "$0")" "${pass}" "${fail}" "${unread}" "${skip}"
(( fail == 0 )) || exit 1
(( unread == 0 )) || exit 2
