#!/usr/bin/env bash
#
# Walk the VoLTE chain on a live handset, stage by stage, and say which stage
# it stops at.
#
# The chain has eight links and every one of them has been the failure point at
# some stage of this project, so the point of this tool is to name the link
# rather than report "VoLTE does not work". Read E-087 for the derivation.
#
#   1  both SIMs loaded, slot 0 registered on a network that offers VoPS
#   2  persist.vendor.mtk_wfc_support == 1        (isEpdgSupport(); E-087)
#   3  the "wfo" binder service is published      (WfoService.makeWfoService)
#   4  the wfo HIDL service is up and reachable   (VINTF manifest entry)
#   5  RDS's Epdgs gate is open                   (rds_set_ui_param landed)
#   6  queryEpdgRat computes an IMS RAT          (eran_type != 0; E-091)
#   7  the IMS PDN activates and is not aborted
#   8  the modem registers IMS, and the framework sees MMTEL voice
#
# ENLARGE THE LOG RING BEFORE YOU REPRODUCE ANYTHING:
#
#   adb -s <serial> shell logcat -b all -G 64M
#
# This is not a nicety. E-091 measured the MAL retry loop this bug produces at
# 3835 iterations in 89 s -- ~42 iterations and ~640 log lines per SECOND --
# which wraps a 16 MiB ring in about ninety seconds. Every post-hoc `logcat -d`
# verdict this tool produced during that investigation was therefore sampling a
# window that no longer contained the cause: it reported "mal_datamngr_set_data_
# call_info was never called" when the call HAD happened and chatty had pruned
# the line. Stage 0 below refuses to judge anything if the radio ring is smaller
# than 32 MiB, the floor the diagnostic tiers ship (ro.logd.size.radio=32M);
# 64 MiB is still what you want when deliberately reproducing this fault.
#
# Usage: check-volte-chain.sh <adb-serial-or-host:port> [capture-dir]
#
# Nothing here writes to the device. With a capture directory it also saves the
# raw logs it judged, so a verdict can be re-read later.

set -uo pipefail

SERIAL="${1:-}"
CAPTURE="${2:-}"
if [[ -z "${SERIAL}" ]]; then
    echo "usage: $(basename "$0") <adb-serial-or-host:port> [capture-dir]" >&2
    exit 2
fi

ADB_BIN="${ADB_BIN:-/home/desmond/Android/Sdk/platform-tools/adb}"
# platform-tools 37 needs this to enumerate this single-interface MTK device
# over USB; harmless over TCP.
export ADB_LIBUSB="${ADB_LIBUSB:-1}"

if [[ ! -x "${ADB_BIN}" ]]; then
    echo "adb not executable: ${ADB_BIN}" >&2
    exit 2
fi

sh_() { "${ADB_BIN}" -s "${SERIAL}" shell "$@" 2>/dev/null | tr -d '\r'; }

# Never `sh_ ... | grep -q`. sh_ is itself a pipeline ending in tr, and under
# `set -o pipefail` a grep -q that exits at its first match SIGPIPEs that tr,
# whose status then wins -- so a SUCCESSFUL match reads as a failure and this
# tool names the wrong link in the chain. Measured on this handset against the
# previous revision of this file:
#
#   $ ( set -uo pipefail; sh_ 'lshal' | grep -q 'android.hardware'; echo $? )
#   72                       # the pattern is on line 8 of 42262 bytes
#   $ ( set -uo pipefail; out="$(sh_ 'lshal')"; grep -q 'android.hardware' <<<"$out"; echo $? )
#   0
#
# i.e. `bad "the wfo HAL is not in lshal"` on a handset where it IS in lshal.
# That is HANDOFF trap 6, and this file's producers are the worst case for it:
# service list is 8.6 kB, lshal 42 kB, dumpsys telephony.registry 162 kB.
# Capture first, then match a here-string, which is not a pipeline.
sh_has() {
    local pattern="$1" output
    shift
    output="$(sh_ "$@")"
    grep -q -- "${pattern}" <<<"${output}"
}

if ! "${ADB_BIN}" -s "${SERIAL}" get-state >/dev/null 2>&1; then
    echo "device not reachable: ${SERIAL}" >&2
    exit 2
fi

pass=0; fail=0; unknown=0
ok()      { printf '  PASS  %s\n' "$*"; pass=$((pass + 1)); }
bad()     { printf '  FAIL  %s\n' "$*"; fail=$((fail + 1)); }
unk()     { printf '  ????  %s\n' "$*"; unknown=$((unknown + 1)); }
stage()   { printf '\n== %s ==\n' "$*"; }

# -v threadtime is pinned, not assumed. Stage 6 now compares log TIMESTAMPS
# (see the 'rat error' block), and a logcat whose default format changed to
# brief would silently strip them and turn a real FAIL into an unreadable one.
LOGS="$(sh_ 'logcat -b radio,main,system -d -v threadtime')"
if [[ -z "${LOGS}" ]]; then
    echo "could not read logcat; every stage below would be unreadable" >&2
    exit 2
fi
if [[ -n "${CAPTURE}" ]]; then
    mkdir -p "${CAPTURE}"
    printf '%s\n' "${LOGS}" >"${CAPTURE}/logcat-combined.txt"
fi

# grep -c on a variable, never on a pipe from a long-running producer: with
# `set -o pipefail` a producer that takes SIGPIPE reports 141 (HANDOFF trap 6).
count() { printf '%s\n' "${LOGS}" | grep -c -- "$1"; }

# logcat stamps lines "MM-DD HH:MM:SS.mmm" with no year, so do not try to parse
# them as dates -- fold them into a comparable integer instead. 2678400 is 31
# days, which keeps months in order; differences inside one month are exact to
# the second, and a difference that spans a month boundary comes out far too
# large, which for an "is this fault still happening" test errs safe (it reports
# the fault as stale, and staleness is independently corroborated by +CIREGU).
log_ts() {
    awk '/^[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ {
             split($1, d, "-"); split($2, t, ":");
             printf "%d\n", d[1]*2678400 + d[2]*86400 + t[1]*3600 + t[2]*60 + int(t[3]);
             exit
         }'
}
# The retry loop iterates ~42 times a second, so if it is running its most
# recent record is a fraction of a second from the end of the window. Thirty
# seconds is two orders of magnitude of slack.
RAT_ERROR_LIVE_S=30
# 32 MiB is the floor because that is what the diagnostic tiers now SHIP:
# device.mk sets ro.logd.size.radio=32M, so a flashed Tier-1 image has it from
# the first boot with no adb setup -- which is the boot that matters, because
# `logcat -G` does not survive the userdata wipe every flash performs.
#
# 64 MiB is still the right size for DELIBERATELY REPRODUCING the IMSM retry
# loop: E-091 measured it at ~640 lines/s, which wraps 16 MiB in ninety seconds,
# so 32 MiB holds roughly three minutes of it. If you are chasing that fault
# specifically rather than reading a boot, run
# `adb shell logcat -b all -G 64M` first.
LOGCAT_MIN_RING_MIB=32

stage "0. the capture window"
ring_line="$(sh_ 'logcat -b radio -g')"
ring_desc="$(grep -o 'ring buffer is [0-9]* [KMG]iB' <<<"${ring_line}" | tail -1)"
ring_desc="${ring_desc#ring buffer is }"
ring_num="${ring_desc//[^0-9]/}"
case "${ring_desc##* }" in
    KiB) ring_mib=0 ;;
    MiB) ring_mib="${ring_num}" ;;
    GiB) ring_mib=$(( ring_num * 1024 )) ;;
    *)   ring_mib="" ;;
esac
if [[ -z "${ring_mib}" ]]; then
    unk "could not read the radio ring size; 'logcat -b radio -g' said: ${ring_line:-<nothing>}"
elif (( ring_mib < LOGCAT_MIN_RING_MIB )); then
    unk "radio ring is ${ring_desc}, under the ${LOGCAT_MIN_RING_MIB} MiB the diagnostic tiers ship (ro.logd.size.radio=32M). Something shrank it, or this is not a Tier 1/2 image. Run 'adb -s ${SERIAL} shell logcat -b all -G 64M', reproduce, re-run. Refusing to judge a window the fault can wrap"
else
    ok "radio ring is ${ring_desc}"
fi

stage "1. radio baseline"
sim="$(sh_ 'getprop gsm.sim.state')"
case "${sim}" in
    LOADED,LOADED)   ok "both SIMs LOADED" ;;
    *PIN_REQUIRED*)  bad "a SIM is PIN-locked (${sim}). IMS only runs on phone 0; turn the PIN lock off" ;;
    *)               bad "unexpected SIM state: ${sim}" ;;
esac
# VoPS, read from PHONE 0 and decoded properly. Both halves of this used to be
# wrong and they cancelled out into a confident PASS:
#
#   * it took `tail -1` over the whole log, which on a dual-SIM handset is
#     whichever phone logged last. Measured live: phone 0 = 3, phone 1 = 1, and
#     the gate was reporting phone 1's number about phone 0's IMS.
#   * it passed anything that was not 0, and 0 is not a value the enum has.
#     LteVopsSupportInfo.java:46-56 defines 1 = NOT_AVAILABLE, 2 = SUPPORTED,
#     3 = NOT_SUPPORTED. So 3 -- "the network says no VoPS" -- read as a PASS.
#
# And yet: this handset has been measured REGISTERED, with
# `MmTel Capabilities - [Voice: true ...]`, while phone 0 reported 3. So a bad
# VoPS value cannot be a hard failure either; the modem plainly does not treat
# it as one. It is reported honestly and left unread rather than guessed at.
# Capture, then match a here-string. `sh_ ... | awk '... exit'` is the trap
# documented forty lines above: awk exits at the first hit and the tr inside
# sh_ takes SIGPIPE, so under pipefail a successful read reports 141. The
# `first()` helper that stood beside count() was the same construction and had
# no caller at all; it is gone.
registry_dump="$(sh_ 'dumpsys telephony.registry')"
vops="$(awk '/Phone Id=0/{p=1; next}
             /Phone Id=[1-9]/{p=0}
             p && match($0, /mVopsSupport = [0-9]+/) {
                 s = substr($0, RSTART, RLENGTH); sub(/.* /, "", s);
                 print s; exit }' <<<"${registry_dump}")"
case "${vops}" in
    2)  ok "phone 0 serving cell advertises VoPS (LTE_STATUS_SUPPORTED)" ;;
    1)  unk "phone 0 reports mVopsSupport = 1 (LTE_STATUS_NOT_AVAILABLE): the network did not say either way" ;;
    3)  unk "phone 0 reports mVopsSupport = 3 (LTE_STATUS_NOT_SUPPORTED). This handset HAS registered IMS in this state, so it is not decisive -- but if the rest of the chain stalls, this is the first thing to re-check against a different cell" ;;
    "") unk "no LteVopsSupportInfo for phone 0 in dumpsys telephony.registry" ;;
    *)  unk "phone 0 reports an mVopsSupport this tool does not know: ${vops}" ;;
esac

stage "2. the ePDG feature gate (E-087, barrier 1)"
wfc="$(sh_ 'getprop persist.vendor.mtk_wfc_support')"
if [[ "${wfc}" == "1" ]]; then
    ok "persist.vendor.mtk_wfc_support=1"
else
    bad "persist.vendor.mtk_wfc_support=${wfc:-<unset>}; isEpdgSupport() is false, so the RIL will never tell MAL the IMS PDN went active"
fi
wrong="$(count 'for IMS in wrong state')"
notified="$(count 'Call mal_datamngr_set_data_call_info')"
if [[ "${wrong}" -eq 0 ]]; then
    ok "no dm_get_ims_pdn_req refusal"
else
    bad "dm_get_ims_pdn_req refused ${wrong} times: MAL was never told the PDN is up"
fi
if [[ "${notified}" -gt 0 ]]; then
    ok "responseUnsolDataCallRspToMal reached MAL (${notified} calls)"
else
    bad "mal_datamngr_set_data_call_info was never called"
fi

stage "3. the WFO framework service (E-087, barrier 2)"
if sh_has '[[:space:]]wfo:' 'service list'; then
    ok "binder service \"wfo\" is published"
else
    bad "binder service \"wfo\" is absent: ImsService did not reach WfoService.makeWfoService()"
fi
if [[ "$(count 'WfoService new WifiOffloadService')" -gt 0 ]]; then
    ok "WfoService took the WifiOffloadService branch"
else
    unk "no 'WfoService new WifiOffloadService' line (log may have rotated past boot)"
fi
if [[ "$(count 'WfoService cannot be found')" -gt 0 ]]; then
    bad "LegacyComponentFactory returned null: mediatek-wfo-legacy.jar was not loadable"
fi

stage "4. the WFO HIDL service"
if sh_has 'hardware.wfo@1.0::IWifiOffload' 'lshal'; then
    ok "vendor.mediatek.hardware.wfo@1.0::IWifiOffload is registered"
else
    bad "the wfo HAL is not in lshal: check that mtk_hal_wfo started"
fi
if [[ "$(count 'initHidlService() fail')" -gt 0 ]]; then
    bad "initHidlService() failed. With PRODUCT_ENFORCE_VINTF_MANIFEST true this is what a MISSING manifest.xml <hal> entry looks like: the server registers, and getService() still returns null forever"
elif [[ "$(count 'initHidlService() succeed')" -gt 0 ]]; then
    ok "the framework got a handle to the HAL"
else
    unk "no initHidlService() result in this log window"
fi

stage "5. RDS's Epdgs gate"
# Anchor on RDS's own wording. A bare "is not ready" also matches
# DynamicSystemService's GsiService chatter, which has nothing to do with this.
#
# This gate USED to be a bare count, and a bare count is wrong here for the same
# reason it was wrong for `rat error` (trap 29). The Epdgs flag is published by
# WfoService a few seconds AFTER the RDS task starts, so a healthy boot refuses
# a handful of times and then works: measured on a registered handset,
# 05:21:05 -> 05:21:14 refusing, 05:21:14.475 onward succeeding, +CIREGU: 1,5
# at 05:21:23. Counting over the window called that a failure.
#
# What matters is whether the LAST refusal is followed by RDS actually running
# ru_ims_ctrl_send_atcmd, which is the function E-085 established RDS skips
# while the flag is 0.
notready="$(count 'or Epdgs(')"
if [[ "${notready}" -eq 0 ]]; then
    ok "RDS never reported MDmngr/Epdgs not ready"
else
    flags="$(printf '%s\n' "${LOGS}" | grep -o 'MDmngr([0-9]*) or Epdgs([0-9]*)' | tail -1)"
    last_refusal="$(printf '%s\n' "${LOGS}" | grep 'or Epdgs(' | tail -1 | log_ts)"
    last_ctrl="$(printf '%s\n' "${LOGS}" | grep 'ru_ims_ctrl_send_atcmd, 1617' | tail -1 | log_ts)"
    if [[ -z "${last_refusal}" ]]; then
        unk "RDS refused ${notready} times but the records carry no parseable timestamp; run with -v threadtime"
    elif [[ -n "${last_ctrl}" && "${last_ctrl}" -ge "${last_refusal}" ]]; then
        ok "RDS refused ${notready} times during startup and then opened (last refusal precedes the last ru_ims_ctrl_send_atcmd)"
    else
        bad "RDS is STILL refusing: ${flags:-MDmngr/Epdgs not ready}, ${notready} times, with no later ru_ims_ctrl_send_atcmd. WfoService never published the flag"
    fi
fi

stage "6. the IMS RAT (E-091)"
# The AUTHORITATIVE signal here is queryEpdgRat's verdict, not epdgConfig's.
# E-091: mtk-ril.so's queryEpdgRat (0x95028) is the ONLY producer of the IMS
# PDN's eran_type, it is called from every requestSetupDataCall* variant, and
# its second gate is property_get("persist.vendor.wfc.sys_wfc_support") -> atoi
# at 0x950bc-0x950c8. With that property at 0 -- this port's value; stock has 1
# at system/system/etc/prop.default:45 -- the cbz at 0x950c8 branches straight
# to "[queryEpdgRat] EPDG is not supported", no RAT is ever computed, and every
# downstream stage fails for a reason that looks like something else. That is
# the exact shape of the bug E-091 root-caused, so test for it by name and name
# the property in the failure text: it reads as a WiFi-calling switch and is
# not one (HANDOFF trap 25, second occurrence).
sys_wfc="$(sh_ 'getprop persist.vendor.wfc.sys_wfc_support')"
qe="$(grep -o '\[queryEpdgRat\] EPDG is not supported\|\[queryEpdgRat\] Call rild_rds_sdc_req success' <<<"${LOGS}" | tail -1)"
if [[ "${qe}" == *"EPDG is not supported"* ]]; then
    bad "[queryEpdgRat] EPDG is not supported -- persist.vendor.wfc.sys_wfc_support=${sys_wfc:-<unset>}. queryEpdgRat is the only producer of the IMS PDN's eran_type, so nothing downstream can work. Set it to 1 (stock's value); it routes NOTHING over WiFi -- queryEpdgRat still takes its 'setup thru mobile' branch (E-091)"
elif [[ -n "${qe}" ]]; then
    ok "queryEpdgRat computed a RAT (${qe}); persist.vendor.wfc.sys_wfc_support=${sys_wfc:-<unset>}"
else
    unk "no [queryEpdgRat] verdict in this window (persist.vendor.wfc.sys_wfc_support=${sys_wfc:-<unset>})"
fi
# epdgConfig is kept, demoted to corroboration. E-087 read the standalone
# configEpdg at 0xa9400 as the emitter and E-091 showed that function has no
# call sites -- but its BODY is inlined into the three requestSetupDataCall*
# variants, so the line IS emitted and still reports the eran_type that
# queryEpdgRat handed over. It is a readout of stage 6's result, not its cause.
eran="$(printf '%s\n' "${LOGS}" | grep -o 'epdgConfig, isHandOver: [0-9]*, eran_type: [0-9]*' | tail -1)"
if [[ -z "${eran}" ]]; then
    unk "no epdgConfig line: the IMS PDN was probably never requested"
elif [[ "${eran}" == *"eran_type: 0" ]]; then
    bad "${eran} -- RAT unassigned, IMSM will log 'rat error!!' and abort the PDN"
else
    ok "${eran}"
fi
# WAS BROKEN: this was `count 'rat error'` tested against 0, i.e. a count of
# occurrences over the whole buffer. That is unusable for THIS fault, and the
# reason is arithmetic, not style. The retry loop runs at ~42 iterations and
# ~640 log lines per second (E-091: 3835 iterations in 89 s), which wraps a
# 16 MiB ring in about ninety seconds -- so the buffer is a sliding window whose
# CONTENTS say nothing about WHEN the loop stopped. During the E-091 fix this
# very line printed
#     FAIL  IMSM logged 'rat error!!' 12597 times
# on a handset that had been registered on IMS for thirty seconds. A count
# cannot separate "happening now" from "happened before the fix and has not yet
# scrolled out"; only a timestamp can. So find the LAST 'rat error' and ask how
# long before the END of the captured window it was, and treat a '+CIREGU: 1..'
# that arrives after it as proof the loop stopped.
raterr_line="$(grep -- 'rat error' <<<"${LOGS}" | tail -1)"
window_end_line="$(grep -E '^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"${LOGS}" | tail -1)"
ciregu_reg_line="$(grep -E '\+CIREGU: [1-9]' <<<"${LOGS}" | tail -1)"
if [[ -z "${raterr_line}" ]]; then
    ok "IMSM logged no rat error in this window"
else
    raterr_ts="$(log_ts <<<"${raterr_line}")"
    end_ts="$(log_ts <<<"${window_end_line}")"
    reg_ts="$(log_ts <<<"${ciregu_reg_line}")"
    if [[ -z "${raterr_ts}" || -z "${end_ts}" ]]; then
        unk "'rat error' is present but its timestamp is unreadable, so whether the loop is still running cannot be told (need -v threadtime)"
    elif [[ -n "${reg_ts}" ]] && (( reg_ts >= raterr_ts )); then
        ok "'rat error' stopped: the last one is $(( reg_ts - raterr_ts ))s before the last '+CIREGU: [1-9]'"
    elif (( end_ts - raterr_ts >= RAT_ERROR_LIVE_S )); then
        ok "'rat error' last seen $(( end_ts - raterr_ts ))s before the end of the window; the loop is not running now"
    else
        bad "IMSM is logging 'rat error!!' NOW (last one $(( end_ts - raterr_ts ))s before the end of the window): no IMS RAT was assigned"
    fi
fi

stage "7. the IMS PDN"
[[ "$(count 'MSG_ID_WRAP_IMSM_IMSPA_PDN_ACT_COMPLETED')" -gt 0 ]] \
    && ok "PDN_ACT_COMPLETED" || bad "the IMS PDN never completed activation"
aborted="$(count 'MSG_ID_WRAP_IMSM_IMSPA_PDN_ABORT')"
[[ "${aborted}" -eq 0 ]] && ok "the PDN was not aborted" \
                         || bad "the PDN was aborted ${aborted} times"

stage "8. modem IMS registration"
# WAS BROKEN: this collected every +CIREGU value in the buffer through
# `sort -u`, which throws ordering away, and then asked whether ANY of them was
# non-zero. A transient "1,5" early in the window followed by a permanent "0"
# therefore read as PASS -- the one stage that reports whether IMS is registered
# RIGHT NOW was answering "was it ever momentarily registered". Every other
# stage in this file already takes the last occurrence; so does this one now.
# The full multiset is still printed, because "1,5 then 0" and "0 throughout"
# are different faults and the counts are what tell them apart.
ciregu="$(grep -o '+CIREGU: [0-9,]*' <<<"${LOGS}" | tail -1)"
ciregu_seen="$(grep -o '+CIREGU: [0-9,]*' <<<"${LOGS}" | sort | uniq -c | tr -s ' ' | sed 's/^ //' | tr '\n' ';')"
if [[ -z "${ciregu}" ]]; then
    unk "no +CIREGU in this log window"
elif grep -qE '\+CIREGU: [1-9]' <<<"${ciregu}"; then
    ok "+CIREGU reports registered (last: ${ciregu}) [seen: ${ciregu_seen}]"
else
    bad "+CIREGU last reported unregistered (last: ${ciregu}) [seen: ${ciregu_seen}]"
fi
# WAS BROKEN: this grepped `dumpsys telephony.registry` for "Voice: true".
# TelephonyRegistry never prints that string, so the gate could not pass on any
# build, on any handset, ever -- the strongest IMS signal in the tool was a
# permanent FAIL. The string comes from MmTelCapabilities.toString()
# (frameworks/base/telephony/java/android/telephony/ims/feature/MmTelFeature.java:299-311)
# and has exactly one printer: ImsPhoneCallTracker.dump()
# (frameworks/opt/telephony/src/java/com/android/internal/telephony/imsphone/
# ImsPhoneCallTracker.java:3594), reachable only through TelephonyDebugService
# -> DebugService.dump() -> PhoneFactory.dump(). TelephonyDebugService is an
# app service guarded by android.permission.DUMP
# (packages/services/Telephony/AndroidManifest.xml:448-452), so it is dumped
# through `dumpsys activity service`, not by a registered service name.
# Measured on 0123456789ABCDEF: `dumpsys telephony.registry` -> 0 matches for
# "MmTel Capabilities"; the command below -> 2, one per phone.
tds="$(sh_ 'dumpsys activity service com.android.phone/.TelephonyDebugService')"
# PhoneFactory.dump() walks sPhones in phone-id order, so the FIRST
# mMmTelCapabilities line is phone 0's -- and phone 0 is the only phone on this
# platform where IMS can run at all (HANDOFF "State"). sed -n 1p rather than
# head -1 or grep -m1 so nothing exits early on the 320 kB payload.
mmtel="$(grep -o 'MmTel Capabilities - \[[^]]*\]' <<<"${tds}" | sed -n '1p')"
if [[ -z "${tds}" || "${tds}" == *"(nothing)"* ]]; then
    unk "could not dump TelephonyDebugService; is com.android.phone running?"
elif [[ -z "${mmtel}" ]]; then
    unk "TelephonyDebugService printed no MmTelCapabilities line"
elif [[ "${mmtel}" == *"Voice: true"* ]]; then
    ok "phone 0 ${mmtel}"
else
    bad "phone 0 ${mmtel} -- the framework has no MMTEL voice capability even if the modem reports +CIREGU registered"
fi

printf '\nchain: pass=%d fail=%d unread=%d\n' "${pass}" "${fail}" "${unknown}"
[[ -n "${CAPTURE}" ]] && printf 'logs: %s/logcat-combined.txt\n' "${CAPTURE}"
# Unread is not a pass. A stage this tool could not read is a stage nobody
# checked, and the whole point is to name the link that failed.
[[ "${fail}" -eq 0 && "${unknown}" -eq 0 ]]
