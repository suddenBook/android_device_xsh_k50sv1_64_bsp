#!/usr/bin/env bash
# Offline adversarial regression matrix for classify-pstore.sh.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_ROOT="$(cd "${TOOL_DIR}/.." && pwd)"
WORK_ROOT="$(cd "${CASE_ROOT}/.." && pwd)"
CLASSIFIER="${TOOL_DIR}/classify-pstore.sh"
MANIFEST="${CASE_ROOT}/evidence/E-074-console-SHA256SUMS.txt"
CURRENT_FIXTURE="${WORK_ROOT}/.capture-staging/pstore-stock-preflash-20260824T1619+0200"
HISTORICAL_FIXTURE="${CASE_ROOT}/evidence/pstore-20260824"

for required in "${CLASSIFIER}" "${MANIFEST}" \
                "${CURRENT_FIXTURE}/console-ramoops" \
                "${CURRENT_FIXTURE}/console-ramoops-2" \
                "${CURRENT_FIXTURE}/pmsg-ramoops-0" \
                "${HISTORICAL_FIXTURE}/console-ramoops" \
                "${HISTORICAL_FIXTURE}/console-ramoops-2"; do
    [[ -f "${required}" && ! -L "${required}" ]] \
        || { printf 'missing classifier fixture: %s\n' "${required}" >&2; exit 1; }
done

TEST_ROOT="$(mktemp -d '/tmp/k50-pstore-test-#-XXXXXX')"
cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-pstore-test-#-* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT

for name in stale historical pmsg_only orderly_changed arbitrary \
            bug_orderly serror_split split_markers benign_timeout \
            debug_prose; do
    mkdir "${TEST_ROOT}/${name}"
done

cp "${CURRENT_FIXTURE}/console-ramoops" \
   "${CURRENT_FIXTURE}/console-ramoops-2" "${TEST_ROOT}/stale/"
cp "${HISTORICAL_FIXTURE}/console-ramoops" \
   "${HISTORICAL_FIXTURE}/console-ramoops-2" "${TEST_ROOT}/historical/"
cp "${CURRENT_FIXTURE}/pmsg-ramoops-0" "${TEST_ROOT}/pmsg_only/"
cp "${CURRENT_FIXTURE}/console-ramoops" \
   "${TEST_ROOT}/orderly_changed/console-ramoops-3"
printf '%s\n' 'ordinary predecessor text with no terminal reboot trail' \
    >"${TEST_ROOT}/arbitrary/console-ramoops"

printf '%s\n' \
    'BUG: scheduling while atomic: kworker/0:1/42/0x00000002' \
    "init: Received sys.powerctl='reboot,' from system_server" \
    'init: Reboot start, reason: reboot' \
    "reboot: Restarting system with command ''" \
    >"${TEST_ROOT}/bug_orderly/console-ramoops"
printf '%s\n' \
    'SError Interrupt on CPU0, code 0xbf000002' \
    "init: Received sys.powerctl='reboot,' from system_server" \
    >"${TEST_ROOT}/serror_split/console-ramoops"
printf '%s\n' 'init: Reboot start, reason: reboot' \
    >"${TEST_ROOT}/serror_split/console-ramoops-1"
printf '%s\n' "reboot: Restarting system with command ''" \
    >"${TEST_ROOT}/serror_split/console-ramoops-2"
printf '%s\n' "init: Received sys.powerctl='reboot,' from system_server" \
    >"${TEST_ROOT}/split_markers/console-ramoops"
printf '%s\n' 'init: Reboot start, reason: reboot' \
    >"${TEST_ROOT}/split_markers/console-ramoops-1"
printf '%s\n' "reboot: Restarting system with command ''" \
    >"${TEST_ROOT}/split_markers/console-ramoops-2"
# Pins the B4 fix: this fixture is an ORDERLY reboot whose console also
# carries ordinary vendor prose containing BUG:/Oops as substrings. Before the
# fix, `grep -Eaiq 'BUG:|Oops:'` matched `DEBUG:` and the fault branch -- which
# is evaluated before the stale and orderly branches -- forced
# kernel_fault_signature on a clean predecessor.
printf '%s\n' \
    'wlan_drv: DEBUG: scan table flushed' \
    'ccci_fsm: [MC debug] Oopsie handler registered' \
    "init: Received sys.powerctl='reboot,' from system_server" \
    'init: Reboot start, reason: reboot' \
    "reboot: Restarting system with command ''" \
    >"${TEST_ROOT}/debug_prose/console-ramoops"

printf '%s\n' \
    'optional sensor read timeout; continuing' \
    "init: Received sys.powerctl='reboot,' from system_server" \
    'init: Reboot start, reason: reboot' \
    "reboot: Restarting system with command ''" \
    >"${TEST_ROOT}/benign_timeout/console-ramoops"

run_case() {
    local name="$1" expected="$2" expected_rc="$3" output rc
    set +e
    output="$("${CLASSIFIER}" "${TEST_ROOT}/${name}" "${MANIFEST}")"
    rc=$?
    set -e
    printf '%-18s rc=%-3s %s\n' "${name}" "${rc}" "${output}"
    [[ "${rc}" -eq "${expected_rc}" && \
       "${output}" == "classification=${expected}" ]]
}

# The pre-transition manifest is what makes stale_pretransition_record
# reachable. An empty or malformed one cannot equal a real capture manifest, so
# it did not fail the comparison -- it deleted the branch, and the stale fixture
# below was then reported as an orderly predecessor reboot with rc 0. Both
# shapes are input errors now.
run_bad_manifest() {
    local name="$1" manifest="$2" rc
    set +e
    "${CLASSIFIER}" "${TEST_ROOT}/stale" "${manifest}" >/dev/null 2>&1
    rc=$?
    set -e
    printf '%-18s rc=%-3s (rejected bad pre-transition manifest)\n' "${name}" "${rc}"
    [[ "${rc}" -eq 2 ]]
}
: >"${TEST_ROOT}/manifest-empty"
printf '%s\n' 'this is not a manifest' >"${TEST_ROOT}/manifest-garbage"
printf '%s  %s\n' \
    'bfdd389099ae95a660f5691931b27da095aeb9ae8965a5b1d968345f8fa17667' \
    'pmsg-ramoops-0' >"${TEST_ROOT}/manifest-wrong-records"
run_bad_manifest manifest_empty "${TEST_ROOT}/manifest-empty"
run_bad_manifest manifest_garbage "${TEST_ROOT}/manifest-garbage"
run_bad_manifest manifest_records "${TEST_ROOT}/manifest-wrong-records"

run_case stale stale_pretransition_record 1
run_case historical kernel_fault_signature 1
run_case pmsg_only console_evidence_unavailable 2
run_case orderly_changed orderly_controlled_predecessor_reboot 0
run_case arbitrary unclassified_predecessor_record 1
run_case bug_orderly kernel_fault_signature 1
run_case serror_split kernel_fault_signature 1
run_case split_markers unclassified_predecessor_record 1
run_case benign_timeout orderly_controlled_predecessor_reboot 0
run_case debug_prose orderly_controlled_predecessor_reboot 0

printf 'PSTORE CLASSIFIER ADVERSARIAL MATRIX: PASS\n'
