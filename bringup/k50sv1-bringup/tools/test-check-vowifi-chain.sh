#!/usr/bin/env bash
# Full-script fake-adb fixtures for the MTK IWLAN transport discriminator.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
GATE="${TOOL_DIR}/check-vowifi-chain.sh"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd -P)"
FRAMEWORK_RES="${K50_TEST_FRAMEWORK_RES_SOURCE:-${PROJECT_ROOT}/lineage-17.1/out/target/product/k50sv1_64_bsp/system/framework/framework-res.apk}"
TEST_ROOT="$(mktemp -d /tmp/k50-vowifi-gate-test.XXXXXX)"

cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-vowifi-gate-test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT

[[ -f "${FRAMEWORK_RES}" && ! -L "${FRAMEWORK_RES}" && -s "${FRAMEWORK_RES}" ]] || {
    printf 'built framework-res fixture is unavailable: %s\n' "${FRAMEWORK_RES}" >&2
    exit 1
}

FAKE_ADB="${TEST_ROOT}/adb"
cat >"${FAKE_ADB}" <<'ADB_EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == -s && "$2" == fixture ]]
shift 2
verb="$1"
shift
case "${verb}" in
    get-state)
        printf 'device\n'
        ;;
    exec-out)
        [[ "$*" == 'cat /system/framework/framework-res.apk' ]]
        cat "${K50_TEST_FRAMEWORK_RES}"
        ;;
    shell)
        command="$*"
        case "${command}" in
            'logcat -b radio,main,system -d -v threadtime')
                cat <<EOF
08-26 23:00:00.000 D IMS: +CIREGU: 1,5
08-26 23:00:00.010 D epdg_wod: Reset settings[1] to default
08-26 23:00:00.020 D RIL: attach-APN re-send armed
08-26 23:00:01.000 D epdg_wod: Query [epdg.epc.mnc001.mcc460.pub.3gppnetwork.org]
08-26 23:00:01.010 D epdg_wod: DNS v4 addr_num:1
08-26 23:00:01.020 D charon: authentication of 'ims' succeeded
08-26 23:00:01.030 D charon: IKE_SA ims[1] established
08-26 23:00:01.040 D RIL-DATA: setup thru wifi with rsp
08-26 23:00:01.050 D epdg_wod: +woattach:0,ims,0,0,epdg1,2
08-26 23:00:01.060 D RIL-DATA: epdgConfig, isHandOver: 0, eran_type: ${K50_TEST_ERAN_TYPE}
08-26 23:00:01.070 I ImsService: [0] state 2 updateImsRegstration, tech 1, reason null
08-26 23:00:01.080 D MtkMmTelFeature: [0] notifyCapabilitiesStatusChanged MmTel Capabilities - [Voice: true Video: false UT: true SMS: true]
EOF
                ;;
            'logcat -b radio -g')
                printf 'ring buffer is 32 MiB\n'
                ;;
            'dumpsys activity service com.android.phone')
                printf 'mMmTelCapabilities=MmTel Capabilities - [Voice: true Video: false UT: true SMS: true]\n'
                ;;
            *'__K50_FILE_RC='*)
                printf '%s\n' \
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
                    /vendor/etc/ipsec/wod_optr.conf
                printf '__K50_FILE_RC=0\n'
                ;;
            'getprop init.svc.wfca'|'getprop init.svc.vendor.epdg_wod')
                printf 'running\n'
                ;;
            *'__K50_TOMBSTONE_RC='*)
                printf '__K50_TOMBSTONE_RC=0\n'
                ;;
            'ls /data/tombstones 2>/dev/null')
                ;;
            'getprop persist.vendor.radio.msimmode')
                printf 'dsds\n'
                ;;
            'dumpsys wifi | head -1')
                printf 'Wi-Fi is enabled\n'
                ;;
            'pidof wpa_supplicant')
                printf '123\n'
                ;;
            'cat /proc/123/cmdline')
                printf 'wpa_supplicant -O/data/vendor/wifi/sock\n'
                ;;
            'ls /data/vendor/wifi/sock/wlan0 2>/dev/null')
                printf '/data/vendor/wifi/sock/wlan0\n'
                ;;
            'mount')
                printf '/dev/block/dm-0 on /data type ext4 (rw,seclabel)\n'
                ;;
            'getprop vendor.gsm.ril.uicctype')
                printf 'USIM\n'
                ;;
            'getprop persist.vendor.mtk_wfc_support'|'getprop persist.vendor.wfc.sys_wfc_support')
                printf '1\n'
                ;;
            'getprop persist.dbg.wfc_avail_ovr'|\
            'getprop persist.dbg.wfc_avail_ovr0'|\
            'getprop persist.dbg.wfc_avail_ovr1')
                printf '0\n'
                ;;
            *'__K50_CARRIER_CONFIG_RC='*)
                if [[ "${K50_TEST_CARRIER_MODE:-readable}" == unread ]]; then
                    exit 0
                fi
                cat <<'EOF'
Phone Id = 0
    Default Values from CarrierConfigManager :
        carrier_wfc_ims_available_bool = false
    mConfigFromDefaultApp :
        carrier_wfc_ims_available_bool = true
    mConfigFromCarrierApp : null
__K50_CARRIER_CONFIG_RC=0
EOF
                ;;
            'getprop persist.vendor.mtk.wfc.enable')
                printf '%s\n' "${K50_TEST_WFC_ENABLE-1}"
                ;;
            'pidof charon')
                printf '999\n'
                ;;
            'getprop gsm.operator.numeric')
                printf '46001,46000\n'
                ;;
            *)
                printf 'unexpected fake-adb shell command: %s\n' "${command}" >&2
                exit 3
                ;;
        esac
        ;;
    *)
        printf 'unexpected fake-adb verb: %s\n' "${verb}" >&2
        exit 3
        ;;
esac
ADB_EOF
chmod 0755 "${FAKE_ADB}"

run_fixture() {
    local eran_type="$1"
    local output="$2"
    local carrier_mode="${3:-readable}"
    local wfc_enable=1
    if [[ "$#" -ge 4 ]]; then
        wfc_enable="$4"
    fi
    set +e
    K50_TEST_FRAMEWORK_RES="${FRAMEWORK_RES}" \
    K50_TEST_ERAN_TYPE="${eran_type}" \
    K50_TEST_CARRIER_MODE="${carrier_mode}" \
    K50_TEST_WFC_ENABLE="${wfc_enable}" \
    ADB_BIN="${FAKE_ADB}" \
        "${GATE}" fixture >"${output}" 2>&1
    local rc=$?
    set -e
    printf '%s' "${rc}"
}

type2_rc="$(run_fixture 2 "${TEST_ROOT}/type2.txt")"
[[ "${type2_rc}" -eq 0 ]]
grep -Fq 'successful Wi-Fi IMS PDN' "${TEST_ROOT}/type2.txt"
grep -Fq 'vendor ImsService registered slot 0 on IWLAN' "${TEST_ROOT}/type2.txt"
grep -Fq '0 fail, 0 unread' "${TEST_ROOT}/type2.txt"

for invalid_type in 0 1; do
    invalid_rc="$(run_fixture "${invalid_type}" \
        "${TEST_ROOT}/type${invalid_type}.txt")"
    [[ "${invalid_rc}" -eq 1 ]]
    grep -Fq 'lacks ordered DNS, authentication, established IKE, Wi-Fi response, attach success, or Wi-Fi PDN evidence' \
        "${TEST_ROOT}/type${invalid_type}.txt"
    ! grep -Fq 'successful Wi-Fi IMS PDN' "${TEST_ROOT}/type${invalid_type}.txt"
done

carrier_unread_rc="$(run_fixture 2 "${TEST_ROOT}/carrier-unread.txt" unread 1)"
[[ "${carrier_unread_rc}" -eq 2 ]]
grep -Fq 'CarrierConfig dump/default-app section is unreadable' \
    "${TEST_ROOT}/carrier-unread.txt"
! grep -Fq 'home carrier does not advertise WFC' \
    "${TEST_ROOT}/carrier-unread.txt"

wfc_unread_rc="$(run_fixture 2 "${TEST_ROOT}/wfc-unread.txt" readable '')"
[[ "${wfc_unread_rc}" -eq 2 ]]
grep -Fq 'persist.vendor.mtk.wfc.enable is unreadable' \
    "${TEST_ROOT}/wfc-unread.txt"

printf 'K50 VOWIFI IWLAN TRANSPORT FIXTURE MATRIX: PASS\n'
