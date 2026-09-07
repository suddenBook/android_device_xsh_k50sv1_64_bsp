#!/usr/bin/env bash
# Normalize AVC denials with exact raw qualifiers and compare them to a reviewed
# allowlist. Host-only; no target access.

set -uo pipefail

usage() {
    printf 'Usage: %s [--min-evidence-lines N] <expected-rules> <output-dir> <log>...\n' \
        "$0" >&2
    exit 2
}

# The floor below which this tool refuses to answer at all.
#
# `denial_count=0 unexpected_count=0` with rc 0 was produced identically by a
# clean capture, by a zero-byte file, and by a file that is not a log at all --
# and rc 0 is this tool's "no unexpected denial" answer, the strongest result it
# can give. Two floors now stand between those cases: every input must be a
# non-empty ordinary file, and at least MIN_EVIDENCE_LINES lines across all
# inputs must carry the shape of a kernel or logcat record. Failing either is
# exit 3, "unread": not a clean policy, an unexamined one.
MIN_EVIDENCE_LINES=1
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --min-evidence-lines)
            [[ "$#" -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 1 ]] \
                || { printf -- '--min-evidence-lines needs a positive integer\n' >&2
                     exit 2; }
            MIN_EVIDENCE_LINES="$2"
            shift 2
            ;;
        --) shift; break ;;
        -*) printf 'unknown AVC classifier option: %s\n' "$1" >&2; exit 2 ;;
        *)  break ;;
    esac
done
[[ "$#" -ge 3 ]] || usage
EXPECTED_FILE="$1"
OUTPUT_DIR="$2"
shift 2

if [[ ! -f "${EXPECTED_FILE}" || -L "${EXPECTED_FILE}" || \
      ! -r "${EXPECTED_FILE}" || \
      ! -d "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
    printf 'AVC classifier requires ordinary expected/output paths\n' >&2
    exit 2
fi
empty_inputs=""
for log_file in "$@"; do
    if [[ ! -f "${log_file}" || -L "${log_file}" || ! -r "${log_file}" ]]; then
        printf 'missing AVC input log: %s\n' "${log_file}" >&2
        exit 2
    fi
    [[ -s "${log_file}" ]] || empty_inputs+="${log_file} "
done

declare -a expected_rules=()
declare -A expected_rule_set=()
while IFS= read -r rule; do
    [[ "${rule}" =~ ^[[:space:]]*(#|$) ]] && continue
    tuple="${rule%% | *}"
    qualifiers=""
    [[ "${rule}" == *" | "* ]] && qualifiers="${rule#* | }"
    if [[ ! "${tuple}" =~ ^[[:alnum:]_]+\ -\>\ [[:alnum:]_]+\ :\ [[:alnum:]_]+\ [[:alnum:]_]+$ ]]; then
        printf 'malformed AVC tuple: %s\n' "${rule}" >&2
        exit 2
    fi
    if [[ -n "${qualifiers}" ]]; then
        declare -A seen_keys=()
        # `for x in ${var}` also runs PATHNAME expansion, so a rule qualifier
        # containing a glob character was rewritten from whatever happened to
        # be in the caller's working directory. Measured, in a directory
        # holding two files named property=gsm.sim.state and property=other:
        #   required='property=* service=x'
        #   for token in ${required}; do echo "[$token]"; done
        #   [property=gsm.sim.state] [property=other] [service=x]
        # `read -a` word-splits on IFS and never globs, which is what the
        # expected-rule header means by "not regular expressions".
        read -r -a qualifier_tokens <<<"${qualifiers}"
        for qualifier in "${qualifier_tokens[@]}"; do
            # `permissive` was missing from this list AND from the perl
            # capture below, so the enforcing/permissive bit of every denial
            # was discarded. Consequence: a Tier-2 run in which half the vendor
            # policy is still permissive produced byte-identical output to a
            # fully-enforcing one -- same tuples, same qualifiers, same counts,
            # same exit code -- which makes Tier 2's entire claim ("this policy
            # is enforced") unverifiable from this tool's artifacts. It is the
            # one field that says whether a denial was ENFORCED or merely
            # logged, and it is present on every raw line (274 of 274 in the
            # tier1-verify-20260824T153250Z fixture).
            if [[ ! "${qualifier}" =~ ^(property|service|interface|path|dev|name|app|ioctlcmd|permissive)=[^[:space:]]+$ ]]; then
                printf 'malformed AVC qualifier: %s\n' "${rule}" >&2
                exit 2
            fi
            key="${qualifier%%=*}"
            if [[ -n "${seen_keys[${key}]:-}" ]]; then
                printf 'duplicate AVC qualifier key: %s\n' "${rule}" >&2
                exit 2
            fi
            seen_keys["${key}"]=1
        done
        unset seen_keys
    fi
    if [[ -n "${expected_rule_set[${rule}]:-}" ]]; then
        printf 'duplicate AVC rule: %s\n' "${rule}" >&2
        exit 2
    fi
    expected_rules+=("${rule}")
    expected_rule_set["${rule}"]=1
done <"${EXPECTED_FILE}"

if ! log_content="$(cat -- "$@")"; then
    printf 'could not read AVC input logs\n' >&2
    exit 2
fi
# What a kernel or logcat record looks like, in the four shapes this project's
# captures actually contain: a dmesg `[   12.345678]` stamp, logcat threadtime
# `MM-DD HH:MM:SS.mmm`, logcat monotonic `12.345 `, and a raw `avc: denied`
# line (the shape hand-written fixtures use). Anything else is not evidence
# this tool can conclude from.
evidence_lines="$(printf '%s\n' "${log_content}" | grep -Ec \
    '^\[[[:space:]]*[0-9]+\.[0-9]+\]|^[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}|^[[:space:]]*[0-9]+\.[0-9]+[[:space:]]|avc: +denied' \
    || true)"
denial_lines="$(printf '%s\n' "${log_content}" \
    | grep -E 'avc: +denied' || true)"
denial_count="$(printf '%s\n' "${denial_lines}" \
    | awk '/avc:/ {count++} END {print count + 0}')"
unparsed="$(printf '%s\n' "${denial_lines}" \
    | grep -Ev 'scontext=u:r:[^ ]+ .*tcontext=u:(r|object_r):[^ ]+ .*tclass=[^ ]+' || true)"
unparsed_count="$(printf '%s\n' "${unparsed}" \
    | awk 'NF {count++} END {print count + 0}')"

normalized="$(printf '%s\n' "${denial_lines}" | perl -ne '
    next unless /avc:\s+denied\s+\{\s*([^}]*)\}.*scontext=u:r:([^: ]+):\S+.*tcontext=u:(?:r|object_r):([^: ]+):\S+.*tclass=([^ ]+)/;
    my ($permissions, $source, $target, $class) = ($1, $2, $3, $4);
    my @permission_tokens = grep { length($_) } split(/\s+/, $permissions);
    next unless @permission_tokens && !grep { $_ !~ /^[[:alnum:]_]+$/ } @permission_tokens;
    $permissions = join(" ", @permission_tokens);
    my @qualifiers;
    push @qualifiers, "property=$1" if /(?:^|\s)property=([^\s\\]+)/;
    push @qualifiers, "service=$1" if /(?:^|\s)service=([^\s\\]+)/;
    push @qualifiers, "interface=$1" if /(?:^|\s)interface=([^\s\\]+)/;
    push @qualifiers, "path=$1" if /(?:^|\s)path="([^"]*)"/;
    push @qualifiers, "dev=$1" if /(?:^|\s)dev="([^"]*)"/;
    push @qualifiers, "name=$1" if /(?:^|\s)name="([^"]*)"/;
    push @qualifiers, "app=$1" if /(?:^|\s)app=([^\s\\]+)/;
    push @qualifiers, "ioctlcmd=$1" if /(?:^|\s)ioctlcmd=([^\s\\]+)/;
    # Last, because that is where the kernel prints it -- after tclass -- so a
    # normalized record reads in the same order as the raw line it came from.
    push @qualifiers, "permissive=$1" if /(?:^|\s)permissive=([0-9]+)/;
    print join("|", $source, $target, $class, $permissions, join(" ", @qualifiers)), "\n";
')"
normalized_count="$(printf '%s\n' "${normalized}" \
    | awk -F'|' 'NF == 5 {count++} END {print count + 0}')"
records="$(printf '%s\n' "${normalized}" | awk -F'|' '
    NF == 5 {
        count = split($4, permissions, /[[:space:]]+/)
        for (i = 1; i <= count; i++) {
            if (permissions[i] != "") {
                print $1 " -> " $2 " : " $3 " " permissions[i] "\t" $5
            }
        }
    }
' | sort -u)"
tuples="$(printf '%s\n' "${records}" | sed 's/\t.*//' | sort -u)"

# Qualifier matching is deliberately a SUBSET test: only the qualifiers a rule
# names are required, and a denial may carry others. That is what the
# expected-rule header describes, and tightening it to exact-set equality would
# turn dozens of already-reviewed records into failures without any denial
# having changed, so it is left as it is.
rule_matches() {
    local tuple="$1" actual="$2" rule rule_tuple required token matches
    local -a required_tokens=()
    for rule in "${expected_rules[@]}"; do
        rule_tuple="${rule%% | *}"
        [[ "${rule_tuple}" == "${tuple}" ]] || continue
        [[ "${rule}" == *" | "* ]] || return 0
        required="${rule#* | }"
        matches=true
        # Same unquoted-expansion hazard as the parse loop above: `for token in
        # ${required}` globbed the required list against the working directory,
        # so a rule qualifier with a wildcard could silently be replaced by
        # unrelated filenames -- widening or narrowing the allowlist depending
        # on where the tool was run from.
        read -r -a required_tokens <<<"${required}"
        for token in "${required_tokens[@]}"; do
            if [[ " ${actual} " != *" ${token} "* ]]; then
                matches=false
                break
            fi
        done
        [[ "${matches}" == true ]] && return 0
    done
    return 1
}

expected_records=""
unexpected_records=""
while IFS=$'\t' read -r tuple qualifiers; do
    [[ -n "${tuple}" ]] || continue
    record="${tuple}${qualifiers:+ | ${qualifiers}}"
    if rule_matches "${tuple}" "${qualifiers:-}"; then
        expected_records+="${record}"$'\n'
    else
        unexpected_records+="${record}"$'\n'
    fi
done <<<"${records}"
expected_records="${expected_records%$'\n'}"
unexpected_records="${unexpected_records%$'\n'}"
expected_count="$(printf '%s\n' "${expected_records}" \
    | awk 'NF {count++} END {print count + 0}')"
unexpected_count="$(printf '%s\n' "${unexpected_records}" \
    | awk 'NF {count++} END {print count + 0}')"

# `printf '%s\n' ""` emits one newline, so an empty result used to be written as
# a 1-byte file rather than an empty one. That matters because a consumer counts
# lines: test-avc-classifier.sh:49 asserts
#   [[ "$(wc -l <".../avc-unexpected.txt")" -eq 3 ]]
# and the same idiom on a clean run would have read 1 unexpected record where
# there were none. Write nothing when there is nothing.
write_artifact() {
    local content="$1" path="$2"
    if [[ -z "${content}" ]]; then
        : >"${path}"
    else
        printf '%s\n' "${content}" >"${path}"
    fi
}
if ! {
    write_artifact "${tuples}" "${OUTPUT_DIR}/avc-tuples.txt" &&
    write_artifact "${records}" "${OUTPUT_DIR}/avc-records.txt" &&
    write_artifact "${expected_records}" "${OUTPUT_DIR}/avc-expected.txt" &&
    write_artifact "${unexpected_records}" "${OUTPUT_DIR}/avc-unexpected.txt" &&
    write_artifact "${unparsed}" "${OUTPUT_DIR}/avc-unparsed.txt"
}; then
    printf 'could not write AVC classification artifacts\n' >&2
    exit 2
fi

printf 'evidence_lines=%s\n' "${evidence_lines}"
printf 'min_evidence_lines=%s\n' "${MIN_EVIDENCE_LINES}"
printf 'denial_count=%s\n' "${denial_count}"
printf 'normalized_count=%s\n' "${normalized_count}"
printf 'unparsed_count=%s\n' "${unparsed_count}"
printf 'expected_count=%s\n' "${expected_count}"
printf 'unexpected_count=%s\n' "${unexpected_count}"
while IFS= read -r record; do
    [[ -n "${record}" ]] && printf 'expected\t%s\n' "${record}"
done <<<"${expected_records}"
while IFS= read -r record; do
    [[ -n "${record}" ]] && printf 'unexpected\t%s\n' "${record}"
done <<<"${unexpected_records}"

# Unread before verdict. Any record found is still printed above, so nothing is
# hidden by this exit; what it withholds is the claim that the absence of a
# record means anything.
if [[ -n "${empty_inputs}" ]]; then
    printf 'unread: empty AVC input log(s): %s\n' "${empty_inputs% }" >&2
    exit 3
fi
if [[ "${evidence_lines}" -lt "${MIN_EVIDENCE_LINES}" ]]; then
    printf 'unread: %s kernel/logcat record(s) examined, below the required %s; these inputs are not an AVC-bearing capture\n' \
        "${evidence_lines}" "${MIN_EVIDENCE_LINES}" >&2
    exit 3
fi

if [[ "${normalized_count}" -ne "${denial_count}" || \
      "${unparsed_count}" -ne 0 || "${unexpected_count}" -ne 0 ]]; then
    exit 1
fi
exit 0
