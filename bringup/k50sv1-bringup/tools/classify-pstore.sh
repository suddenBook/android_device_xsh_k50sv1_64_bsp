#!/usr/bin/env bash
# Classify pstore records from the preceding boot without attributing them to
# the currently running ROM.

set -uo pipefail

usage() {
    printf 'Usage: %s <captured-pstore-directory> <pre-transition-manifest>\n' \
        "$0" >&2
    exit 2
}

[[ "$#" -eq 2 ]] || usage
CAPTURE_DIR="$1"
PRETRANSITION_FILE="$2"

if [[ ! -d "${CAPTURE_DIR}" || -L "${CAPTURE_DIR}" || \
      ! -f "${PRETRANSITION_FILE}" || -L "${PRETRANSITION_FILE}" ]]; then
    printf 'pstore classifier requires ordinary capture/manifest paths\n' >&2
    exit 2
fi

if ! pretransition_manifest="$(cat "${PRETRANSITION_FILE}")"; then
    printf 'could not read pre-transition manifest\n' >&2
    exit 2
fi
# The pre-transition manifest is the ONLY input that can make
# stale_pretransition_record reachable: that branch fires when the captured
# manifest is byte-identical to this one. An empty or malformed file can never
# be byte-identical to a real capture manifest, so it does not fail the
# comparison -- it deletes the branch, and every stale record then falls through
# to the orderly/unclassified split below and is reported as a fresh record from
# the predecessor boot. Both shapes were accepted silently. Require the exact
# `<sha256>  <console|dmesg record>` form sha256sum writes, on every line, and
# at least one line.
read -r pretransition_total pretransition_wellformed <<<"$(awk '
    NF == 0 { next }
    { total++ }
    NF == 2 && $1 ~ /^[0-9a-f]{64}$/ && \
        ($2 ~ /^console-ramoops/ || $2 ~ /^dmesg-ramoops/) { wellformed++ }
    END { printf "%d %d\n", total + 0, wellformed + 0 }
' <<<"${pretransition_manifest}")"
if [[ "${pretransition_total}" -lt 1 || \
      "${pretransition_total}" -ne "${pretransition_wellformed}" ]]; then
    printf 'pre-transition manifest is not a sha256sum manifest of console/dmesg ramoops records (%s of %s lines well formed): %s\n' \
        "${pretransition_wellformed}" "${pretransition_total}" \
        "${PRETRANSITION_FILE}" >&2
    exit 2
fi
if ! manifest="$(
    cd "${CAPTURE_DIR}" || exit 1
    find . -maxdepth 1 -type f \
        \( -name 'console-ramoops*' -o -name 'dmesg-ramoops*' \) \
        -printf '%P\0' \
        | LC_ALL=C sort -z \
        | xargs -0 -r sha256sum --
)"; then
    printf 'could not hash captured pstore consoles\n' >&2
    exit 2
fi
# `printf '%s\n' ""` writes one newline, so a capture holding no console/dmesg
# record used to produce a 1-byte manifest rather than an empty one, and
# consumers count lines (test-avc-classifier.sh:49 does exactly that on the
# sibling artifact). Write a genuinely empty file when there is no record.
write_manifest() {
    if [[ -z "${manifest}" ]]; then
        : >"${CAPTURE_DIR}/FAULT-SHA256SUMS"
    else
        printf '%s\n' "${manifest}" >"${CAPTURE_DIR}/FAULT-SHA256SUMS"
    fi
}
if ! write_manifest; then
    printf 'could not write captured pstore manifest\n' >&2
    exit 2
fi

mapfile -d '' -t console_files < <(
    find "${CAPTURE_DIR}" -maxdepth 1 -type f \
        \( -name 'console-ramoops*' -o -name 'dmesg-ramoops*' \) \
        -print0 | LC_ALL=C sort -z
)

classification=""
result=0
if [[ "${#console_files[@]}" -eq 0 || -z "${manifest}" ]]; then
    classification="console_evidence_unavailable"
    result=2
# No -i, and the short tokens are anchored on a non-alphanumeric boundary.
#
# The fault branch is evaluated FIRST, so one matching line overrides both the
# stale and the orderly verdicts. `-i` plus an unanchored `BUG:` made ordinary
# vendor prose do exactly that; measured:
#
#   $ printf 'DEBUG: something benign\n' | grep -Eaiq 'BUG:|Oops:' ; echo $?
#   0
#
# and dropping -i alone is NOT enough, because `DEBUG:` still contains `BUG:`
# as a substring -- only the boundary anchor rejects it:
#
#   $ printf 'DEBUG: something benign\n' | grep -Eaq '(^|[^[:alnum:]])BUG:'; echo $?
#   1
#
# Real captures on this handset do carry such prose ([MC debug], .debug.loggeru
# in evidence/pstore-20260824/console-ramoops), so this was live-reachable.
#
# Where the kernel itself capitalizes, the case is spelled out rather than
# folded away: mm/slab.c prints "Slab corruption (%s)", arm64 fault_info[]
# prints lowercase "synchronous external abort", and the stack-protector line
# is "Kernel stack is corrupted in". Case folding was hiding the ambiguity,
# not providing coverage.
elif grep -Eaq \
        'Kernel panic|(^|[^[:alnum:]])BUG:|(^|[^[:alnum:]])Oops[[:space:]:]|Unable to handle|Internal error:|Unhandled fault:|Fatal exception|SError Interrupt|Unhandled SError|[Ee]xternal abort|[Dd]ata abort|general protection fault|invalid opcode|divide error|stack-protector: Kernel stack|[Kk]ernel stack (is )?corrupt|stack overflow|soft lockup|hard LOCKUP|[Ww]atchdog[^[:cntrl:]]*bite|[Hh]ung task|blocked for more than [0-9]+ seconds|rcu[^[:cntrl:]]*(stall|self-detected)|KASAN:|UBSAN:|KFENCE:|[Ll]ist corruption|[Ss]lab corruption|read_timeout_handler|([Ss]ystracker|SYSTRACKER|AXI)[^[:cntrl:]]*(read[^[:cntrl:]]*)?([Tt]imeout|TIMEOUT)' \
        "${console_files[@]}"; then
    classification="kernel_fault_signature"
    result=1
elif [[ "${manifest}" == "${pretransition_manifest}" ]]; then
    classification="stale_pretransition_record"
    result=1
else
    orderly=false
    for console_file in "${console_files[@]}"; do
        if awk '
            state == 0 && /Received sys[.]powerctl=/ && /reboot,/ {
                state=1; next
            }
            state == 1 && /Reboot start, reason: reboot/ {
                state=2; next
            }
            state == 2 && /reboot: Restarting system with command/ {
                found=1; exit
            }
            END { exit(found ? 0 : 1) }
        ' "${console_file}"; then
            orderly=true
            break
        fi
    done
    if [[ "${orderly}" == true ]]; then
        classification="orderly_controlled_predecessor_reboot"
    else
        classification="unclassified_predecessor_record"
        result=1
    fi
fi

if ! printf 'classification=%s\n' "${classification}" \
        >"${CAPTURE_DIR}/CLASSIFICATION.txt"; then
    printf 'could not write pstore classification\n' >&2
    exit 2
fi
printf 'classification=%s\n' "${classification}"
exit "${result}"
