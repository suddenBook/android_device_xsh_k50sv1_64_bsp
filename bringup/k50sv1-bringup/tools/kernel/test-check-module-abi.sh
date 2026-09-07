#!/usr/bin/env bash
# Disposable positive/negative fixtures for check-module-abi.sh.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../../.." && pwd)"
GATE="${TOOL_DIR}/check-module-abi.sh"
TEST_ROOT="$(mktemp -d '/tmp/k50-module-abi-test.XXXXXX')"
# A captured stock directory can be supplied after product prebuilts are removed.
(($# <= 1)) || { echo "usage: $0 [STOCK_MODULE_DIR]" >&2; exit 2; }
MODULE_SOURCE="${1:-${PROJECT_ROOT}/lineage-17.1/vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib/modules}"
CROSS_OBJCOPY="${PROJECT_ROOT}/lineage-17.1/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android-objcopy"

cleanup() {
    if [[ -d "${TEST_ROOT:-}" && ! -L "${TEST_ROOT}" && \
          "${TEST_ROOT}" == /tmp/k50-module-abi-test.* ]]; then
        find "${TEST_ROOT}" -mindepth 1 -depth -delete
        rmdir "${TEST_ROOT}"
    fi
}
trap cleanup EXIT

[[ -x "${CROSS_OBJCOPY}" ]] \
    || { printf 'fixture AArch64 objcopy is unavailable\n' >&2; exit 2; }
command -v gzip >/dev/null 2>&1 \
    || { printf 'fixture gzip is unavailable\n' >&2; exit 2; }

mkdir "${TEST_ROOT}/fakebin" "${TEST_ROOT}/modules"
for module in wmt_drv.ko wmt_chrdev_wifi.ko wlan_drv_gen2.ko bt_drv.ko gps_drv.ko; do
    [[ -f "${MODULE_SOURCE}/${module}" && ! -L "${MODULE_SOURCE}/${module}" ]] \
        || { printf 'fixture stock module is unavailable: %s\n' "${module}" >&2; exit 2; }
    cp -- "${MODULE_SOURCE}/${module}" "${TEST_ROOT}/modules/${module}"
done

# The fake tools model the exact fixed shape without storing binary fixtures:
# one consumer imports 339 vmlinux pairs and 29 pairs exported by wmt_drv.ko.
cat >"${TEST_ROOT}/fakebin/modinfo" <<'MODINFO_EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 3 && "$1" == -F ]]
field="$2"
module="$(basename "$3")"
case "${field}" in
    vermagic)
        if [[ "${FAKE_MODINFO_MODE:-}" == vermagic_replaced ]]; then
            printf '%s\n' '3.18.120 SMP preempt mod_unload modversions aarch64'
        elif [[ "${FAKE_MODINFO_MODE:-}" == vermagic_split && \
              "${module}" == gps_drv.ko ]]; then
            printf '%s\n' '3.18.120 SMP preempt mod_unload modversions aarch64'
        else
            printf '%s\n' '3.18.119 SMP preempt mod_unload modversions aarch64'
        fi
        ;;
    sig_id)
        [[ "${FAKE_MODINFO_MODE:-}" == signed_all || \
           ("${FAKE_MODINFO_MODE:-}" == signed_one && "${module}" == gps_drv.ko) ]] \
            && printf '%s\n' PKCS#7 || printf '\n'
        ;;
    signer)
        [[ "${FAKE_MODINFO_MODE:-}" == signed_all || \
           ("${FAKE_MODINFO_MODE:-}" == signed_one && "${module}" == gps_drv.ko) ]] \
            && printf '%s\n' fixture-key || printf '\n'
        ;;
    sig_key)
        [[ "${FAKE_MODINFO_MODE:-}" == signed_all || \
           ("${FAKE_MODINFO_MODE:-}" == signed_one && "${module}" == gps_drv.ko) ]] \
            && printf '%s\n' '12:34' || printf '\n'
        ;;
    sig_hashalgo)
        [[ "${FAKE_MODINFO_MODE:-}" == signed_all || \
           ("${FAKE_MODINFO_MODE:-}" == signed_one && "${module}" == gps_drv.ko) ]] \
            && printf '%s\n' sha256 || printf '\n'
        ;;
    *) exit 3 ;;
esac
MODINFO_EOF

cat >"${TEST_ROOT}/fakebin/modprobe" <<'MODPROBE_EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 && "$1" == --dump-modversions ]]
module="$(basename "$2")"
case "${module}" in
    wlan_drv_gen2.ko)
        printf '0x%s\tmodule_layout\n' "${FAKE_MODULE_LAYOUT:-a415c974}"
        for i in $(seq 1 338); do
            [[ "${FAKE_IMPORT_MODE:-}" == missing_crc && "${i}" -eq 1 ]] && continue
            printf '0x%08x\tbuiltin%03d\n' "$((0x10000000 + i))" "${i}"
        done
        if [[ -n "${FAKE_SOURCE_MODE:-}" ]]; then
            printf '0x30000001\tsource_only_symbol\n'
            if [[ "${FAKE_IMPORT_MODE:-}" == extra_crc ]]; then
                printf '0x30000002\tunreferenced_symbol\n'
            elif [[ "${FAKE_IMPORT_MODE:-}" == duplicate_crc ]]; then
                printf '0x10000001\tbuiltin001\n'
            fi
        fi
        for i in $(seq 1 29); do
            printf '0x%08x\tinter%03d\n' "$((0x20000000 + i))" "${i}"
        done
        ;;
    wmt_drv.ko|wmt_chrdev_wifi.ko|bt_drv.ko|gps_drv.ko)
        [[ -z "${FAKE_SOURCE_MODE:-}" ]] || printf '0x%s\tmodule_layout\n' "${FAKE_MODULE_LAYOUT:-a415c974}"
        ;;
    *)
        exit 3
        ;;
esac
MODPROBE_EOF

cat >"${TEST_ROOT}/fakebin/nm" <<'NM_EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" -eq 2 ]]
module="$(basename "$2")"
if [[ "$1" == --undefined-only ]]; then
    [[ -n "${FAKE_SOURCE_MODE:-}" ]]
    if [[ "${module}" == wlan_drv_gen2.ko ]]; then
        for i in $(seq 1 338); do printf ' U builtin%03d\n' "${i}"; done
        for i in $(seq 1 29); do printf ' U inter%03d\n' "${i}"; done
        printf ' U source_only_symbol\n'
        [[ "${FAKE_IMPORT_MODE:-}" != extra_undefined ]] || printf ' U never_versioned\n'
    fi
    exit 0
fi
[[ "$1" == --defined-only ]]
if [[ "${module}" == vmlinux ]]; then
    if [[ -n "${FAKE_SOURCE_MODE:-}" ]]; then
        printf '0000000000000000 D __ksymtab_source_only_symbol\n'
        printf '0000000030000001 A __crc_source_only_symbol\n'
    fi
    printf '0000000000000000 D __ksymtab_module_layout\n'
    if [[ "${FAKE_NM_MODE:-}" != vmlinux_crc_missing ]]; then
        if [[ "${FAKE_NM_MODE:-}" == vmlinux_crc_mismatch ]]; then
            printf '00000000deadbeef A __crc_module_layout\n'
        else
            printf '00000000%s A __crc_module_layout\n' "${FAKE_MODULE_LAYOUT:-a415c974}"
        fi
        [[ "${FAKE_NM_MODE:-}" == vmlinux_crc_duplicate ]] && \
            printf '00000000%s A __crc_module_layout\n' "${FAKE_MODULE_LAYOUT:-a415c974}"
    fi
    if [[ "${FAKE_NM_MODE:-}" == vmlinux_inter_collision ]]; then
        printf '0000000020000001 A __crc_inter001\n'
    fi
    if [[ "${FAKE_NM_MODE:-}" == vmlinux_inter_export_collision ]]; then
        printf '0000000000000000 D __ksymtab_inter001\n'
    fi
    for i in $(seq 1 338); do
        if [[ "${FAKE_NM_MODE:-}" != vmlinux_export_missing || "${i}" -ne 1 ]]; then
            printf '0000000000000000 D __ksymtab_builtin%03d\n' "${i}"
        fi
        if [[ "${FAKE_NM_MODE:-}" == vmlinux_export_duplicate && "${i}" -eq 2 ]]; then
            printf '0000000000000000 D __ksymtab_builtin002\n'
        fi
        printf '%016x A __crc_builtin%03d\n' "$((0x10000000 + i))" "${i}"
    done
elif [[ "${module}" == wmt_drv.ko ]]; then
    if [[ -n "${FAKE_SOURCE_MODE:-}" ]]; then
        printf '0000000000000000 D __ksymtab_unused_source_export\n'
        if [[ "${FAKE_NM_MODE:-}" == unused_export_mismatch ]]; then
            printf '00000000deadbeef A __crc_unused_source_export\n'
        else
            printf '0000000040000001 A __crc_unused_source_export\n'
        fi
    fi
    for i in $(seq 1 29); do
        printf '0000000000000000 D __ksymtab_inter%03d\n' "${i}"
        if [[ "${FAKE_NM_MODE:-}" == crc_mismatch && "${i}" -eq 1 ]]; then
            printf '000000002fffffff A __crc_inter001\n'
        elif [[ "${FAKE_NM_MODE:-}" != missing_crc || "${i}" -ne 3 ]]; then
            printf '%016x A __crc_inter%03d\n' "$((0x20000000 + i))" "${i}"
        fi
    done
elif [[ "${module}" == bt_drv.ko && "${FAKE_NM_MODE:-}" == duplicate_provider ]]; then
    printf '0000000000000000 D __ksymtab_inter002\n'
    printf '0000000020000002 A __crc_inter002\n'
fi
NM_EOF

chmod +x "${TEST_ROOT}/fakebin/modinfo" "${TEST_ROOT}/fakebin/modprobe" \
    "${TEST_ROOT}/fakebin/nm"

make_positive_symvers() {
    local output="$1" i crc
    {
        # Exercise provider-path normalization and the 4-column legacy form.
        printf '0xA415C974\tmodule_layout\t/build/kernel/vmlinux\tEXPORT_SYMBOL\n'
        for i in $(seq 1 338); do
            printf -v crc '%08x' "$((0x10000000 + i))"
            case "$((i % 3))" in
                0)
                    # Modern 5-column form with namespace.
                    printf '0x%s\tbuiltin%03d\t./out/vmlinux\tEXPORT_SYMBOL_GPL\tTEST_NS\n' \
                        "${crc}" "${i}"
                    ;;
                1)
                    # CRC without 0x is accepted by older generated fixtures.
                    printf '%s builtin%03d vmlinux EXPORT_SYMBOL\n' "${crc^^}" "${i}"
                    ;;
                2)
                    # Three columns are sufficient for the ABI identity.
                    printf '0x%s\tbuiltin%03d\tvmlinux\n' "${crc}" "${i}"
                    ;;
            esac
        done
    } >"${output}"
}

make_candidate_output() {
    local output="$1"
    local vermagic="${2:-3.18.119 SMP preempt mod_unload modversions aarch64}"
    local modules="${3:-y}"
    local modversions="${4:-y}"
    local module_sig="${5:-n}"
    local module_sig_force="${6:-n}"
    local module_sig_all="${7:-n}"
    local uts_release="${vermagic%% *}"
    local key value

    mkdir -p "${output}/include/config" "${output}/include/generated" \
        "${output}/arch/arm64/boot"
    make_positive_symvers "${output}/Module.symvers"
    : >"${output}/.config"
    : >"${output}/include/config/auto.conf"
    : >"${output}/include/generated/autoconf.h"
    for key in \
        CONFIG_MODULES \
        CONFIG_MODVERSIONS \
        CONFIG_MODULE_SIG \
        CONFIG_MODULE_SIG_FORCE \
        CONFIG_MODULE_SIG_ALL; do
        case "${key}" in
            CONFIG_MODULES) value="${modules}" ;;
            CONFIG_MODVERSIONS) value="${modversions}" ;;
            CONFIG_MODULE_SIG) value="${module_sig}" ;;
            CONFIG_MODULE_SIG_FORCE) value="${module_sig_force}" ;;
            CONFIG_MODULE_SIG_ALL) value="${module_sig_all}" ;;
        esac
        if [[ "${value}" == y ]]; then
            printf '%s=y\n' "${key}" >>"${output}/.config"
            printf '%s=y\n' "${key}" >>"${output}/include/config/auto.conf"
            printf '#define %s 1\n' "${key}" \
                >>"${output}/include/generated/autoconf.h"
        else
            printf '# %s is not set\n' "${key}" >>"${output}/.config"
        fi
    done
    printf '#define UTS_RELEASE "%s"\n' "${uts_release}" \
        >"${output}/include/generated/utsrelease.h"
    printf '%s\n' "${uts_release}" >"${output}/include/config/kernel.release"
    # A minimal ELF with a real sized vermagic symbol exercises the ELF reader
    # and trusted objcopy without compiling a kernel or fixture program.
    python3 - "${output}/vmlinux" "${vermagic}" <<'ELF_EOF'
import pathlib, struct, sys
payload = sys.argv[2].encode("ascii") + b"\0"
names = b"\0.rodata\0.strtab\0.symtab\0.shstrtab\0"
strings = b"\0vermagic\0"
symbols = bytes(24) + struct.pack("<IBBHQQ", 1, 0x11, 0, 1, 0x10000, len(payload))
blob = bytearray(64)
sections = [bytes(64)]
for name, data, kind, flags, address, link, info, align, entsize in (
    (b".rodata", payload, 1, 2, 0x10000, 0, 0, 1, 0),
    (b".strtab", strings, 3, 0, 0, 0, 0, 1, 0),
    (b".symtab", symbols, 2, 0, 0, 2, 1, 8, 24),
    (b".shstrtab", names, 3, 0, 0, 0, 0, 1, 0),
):
    blob.extend(bytes((-len(blob)) % align))
    offset = len(blob)
    blob.extend(data)
    sections.append(struct.pack("<IIQQQQIIQQ", names.index(name), kind, flags,
                                address, offset, len(data), link, info, align, entsize))
blob.extend(bytes((-len(blob)) % 8))
section_offset = len(blob)
blob.extend(b"".join(sections))
ident = b"\x7fELF\x02\x01\x01" + bytes(9)
blob[:64] = ident + struct.pack("<HHIQQQIHHHHHH", 2, 183, 1, 0x10000, 0,
                              section_offset, 0, 64, 0, 0, 64, len(sections), 4)
pathlib.Path(sys.argv[1]).write_bytes(blob)
ELF_EOF
    "${CROSS_OBJCOPY}" -O binary -R .note -R .note.gnu.build-id \
        -R .comment -S "${output}/vmlinux" "${output}/arch/arm64/boot/Image"
    gzip -n -f -9 -c "${output}/arch/arm64/boot/Image" \
        >"${output}/arch/arm64/boot/Image.gz"
}

run_gate() {
    PATH="${TEST_ROOT}/fakebin:${PATH}" "${GATE}" \
        --module-dir "${TEST_ROOT}/modules" "$@"
}

assert_line() {
    local expected="$1" text="$2"
    grep -Fxq "${expected}" <<<"${text}"
}

make_candidate_output "${TEST_ROOT}/positive-output"

# A detached Module.symvers is no longer an admissible candidate input: it
# cannot prove vermagic, generated config, or signature policy.
set +e
run_gate "${TEST_ROOT}/positive-output/Module.symvers" >/dev/null \
    2>"${TEST_ROOT}/detached-symvers.err"
detached_symvers_rc=$?
set -e
[[ "${detached_symvers_rc}" -eq 2 ]]
grep -Fq 'candidate build output is missing or symlinked' \
    "${TEST_ROOT}/detached-symvers.err"

positive="$(run_gate --report "${TEST_ROOT}/positive-report.tsv" \
    "${TEST_ROOT}/positive-output")"
assert_line 'status=PASS' "${positive}"
assert_line "candidate_output=${TEST_ROOT}/positive-output" "${positive}"
assert_line 'expected_pairs=368' "${positive}"
assert_line 'built_in_expected=339' "${positive}"
assert_line 'inter_module_expected=29' "${positive}"
assert_line 'stock_inter_ok=29' "${positive}"
assert_line 'stock_vermagic_expected=3.18.119 SMP preempt mod_unload modversions aarch64' \
    "${positive}"
assert_line 'stock_vermagic=3.18.119 SMP preempt mod_unload modversions aarch64' \
    "${positive}"
assert_line 'stock_module_signature=unsigned' "${positive}"
assert_line 'stock_module_sha256.wmt_drv.ko=f30b22f3c39b8dd5816fee034c6b19d422c608768b345bded7cb29e574cb1c46' "${positive}"
assert_line 'stock_module_sha256.wmt_chrdev_wifi.ko=c1372b4c3759186179ec8c2e720ef05ae771d2a16a36b84e2d8e07fbca155a19' "${positive}"
assert_line 'stock_module_sha256.wlan_drv_gen2.ko=658b5fa6378267368c4b809f540b270efaee80062c374fb7250db7928a8bb84f' "${positive}"
assert_line 'stock_module_sha256.bt_drv.ko=d64e7dccc2453ab00dca022f68193940de303c282abcaeb1c67b46ffe7925a4b' "${positive}"
assert_line 'stock_module_sha256.gps_drv.ko=af865da4f38bbf45a31222ecd2b0445926eecd41e391bdd11abd0e49c1033949' "${positive}"
assert_line 'candidate_uts_release=3.18.119' "${positive}"
assert_line 'candidate_vermagic=3.18.119 SMP preempt mod_unload modversions aarch64' \
    "${positive}"
assert_line 'candidate_config_modules=y' "${positive}"
assert_line 'candidate_config_modversions=y' "${positive}"
assert_line 'candidate_config_module_sig=n' "${positive}"
assert_line 'candidate_config_module_sig_force=n' "${positive}"
assert_line 'candidate_config_module_sig_all=n' "${positive}"
assert_line 'module_signature_compatible=yes' "${positive}"
assert_line 'candidate_metadata_errors=0' "${positive}"
positive_image_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/arch/arm64/boot/Image" | awk '{ print $1 }')"
positive_image_gz_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/arch/arm64/boot/Image.gz" | awk '{ print $1 }')"
positive_vmlinux_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/vmlinux" | awk '{ print $1 }')"
positive_dot_config_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/.config" | awk '{ print $1 }')"
positive_auto_conf_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/include/config/auto.conf" | awk '{ print $1 }')"
positive_kernel_release_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/include/config/kernel.release" | awk '{ print $1 }')"
positive_autoconf_h_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/include/generated/autoconf.h" | awk '{ print $1 }')"
positive_utsrelease_h_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/include/generated/utsrelease.h" | awk '{ print $1 }')"
positive_symvers_sha="$(sha256sum \
    "${TEST_ROOT}/positive-output/Module.symvers" | awk '{ print $1 }')"
assert_line "candidate_dot_config_sha256=${positive_dot_config_sha}" "${positive}"
assert_line "candidate_auto_conf_sha256=${positive_auto_conf_sha}" "${positive}"
assert_line "candidate_kernel_release_sha256=${positive_kernel_release_sha}" "${positive}"
assert_line "candidate_autoconf_h_sha256=${positive_autoconf_h_sha}" "${positive}"
assert_line "candidate_utsrelease_h_sha256=${positive_utsrelease_h_sha}" "${positive}"
assert_line "candidate_symvers_sha256=${positive_symvers_sha}" "${positive}"
assert_line "candidate_vmlinux_sha256=${positive_vmlinux_sha}" "${positive}"
assert_line "candidate_image_sha256=${positive_image_sha}" "${positive}"
assert_line "candidate_image_derived_sha256=${positive_image_sha}" "${positive}"
assert_line "candidate_image_gz_sha256=${positive_image_gz_sha}" "${positive}"
assert_line 'candidate_builtin_ok=339' "${positive}"
assert_line 'candidate_missing=0' "${positive}"
assert_line 'candidate_crc_mismatch=0' "${positive}"
assert_line 'candidate_wrong_provider=0' "${positive}"
assert_line 'candidate_duplicate=0' "${positive}"
assert_line 'candidate_vmlinux_crc_ok=339' "${positive}"
assert_line 'candidate_vmlinux_crc_missing=0' "${positive}"
assert_line 'candidate_vmlinux_crc_mismatch=0' "${positive}"
assert_line 'candidate_vmlinux_crc_duplicate=0' "${positive}"
assert_line 'candidate_vmlinux_export_ok=339' "${positive}"
assert_line 'candidate_vmlinux_export_missing=0' "${positive}"
assert_line 'candidate_vmlinux_export_duplicate=0' "${positive}"
assert_line 'candidate_inter_ok=29' "${positive}"
assert_line 'candidate_inter_symvers_collision=0' "${positive}"
assert_line 'candidate_inter_vmlinux_crc_collision=0' "${positive}"
assert_line 'candidate_inter_vmlinux_export_collision=0' "${positive}"
assert_line 'module_layout_actual=a415c974@vmlinux' "${positive}"
assert_line 'module_layout_vmlinux_actual=a415c974@__crc_module_layout' "${positive}"

cp -- "${TEST_ROOT}/modules/bt_drv.ko" "${TEST_ROOT}/bt_drv.ko.clean"
printf 'tamper\n' >>"${TEST_ROOT}/modules/bt_drv.ko"
set +e
run_gate "${TEST_ROOT}/positive-output" >/dev/null \
    2>"${TEST_ROOT}/module-digest.err"
module_digest_rc=$?
set -e
[[ "${module_digest_rc}" -eq 2 ]]
grep -Fq 'stock module digest changed for bt_drv.ko' \
    "${TEST_ROOT}/module-digest.err"
cp -- "${TEST_ROOT}/bt_drv.ko.clean" "${TEST_ROOT}/modules/bt_drv.ko"

printf 'extra module\n' >"${TEST_ROOT}/modules/extra.ko"
set +e
run_gate "${TEST_ROOT}/positive-output" >/dev/null \
    2>"${TEST_ROOT}/module-set.err"
module_set_rc=$?
set -e
[[ "${module_set_rc}" -eq 2 ]]
grep -Fq 'stock module directory must contain exactly' \
    "${TEST_ROOT}/module-set.err"
find "${TEST_ROOT}/modules/extra.ko" -maxdepth 0 -type f -delete
[[ "$(wc -l <"${TEST_ROOT}/positive-report.tsv")" -eq 398 ]]
grep -Fqx $'stock-inter\tok\tinter001\t20000001\tone-stock-module\t20000001@wmt_drv.ko' \
    "${TEST_ROOT}/positive-report.tsv"
grep -Fqx $'candidate-builtin\tok\tmodule_layout\ta415c974\tvmlinux+__crc+__ksymtab\tsymvers=a415c974@vmlinux[line=1];vmlinux=a415c974@__crc_module_layout[line=2];ksymtab=1' \
    "${TEST_ROOT}/positive-report.tsv"
grep -Fqx $'candidate-inter\tok\tinter001\t20000001\tstock-module-only\tsymvers=<absent>;vmlinux=<absent>;ksymtab=0' \
    "${TEST_ROOT}/positive-report.tsv"

# The report must be reproducible byte-for-byte, including row ordering.
run_gate --report "${TEST_ROOT}/positive-report-2.tsv" \
    "${TEST_ROOT}/positive-output" >/dev/null
cmp "${TEST_ROOT}/positive-report.tsv" "${TEST_ROOT}/positive-report-2.tsv"

# A report path may not alias either candidate metadata or a stock module input.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/protected-output"
set +e
run_gate --report "${TEST_ROOT}/protected-output/Module.symvers" \
    "${TEST_ROOT}/protected-output" >/dev/null 2>"${TEST_ROOT}/protected.err"
protected_rc=$?
set -e
[[ "${protected_rc}" -eq 2 ]]
cmp "${TEST_ROOT}/positive-output/Module.symvers" \
    "${TEST_ROOT}/protected-output/Module.symvers"
grep -Fq 'refusing to overwrite an ABI input' "${TEST_ROOT}/protected.err"

# One fixture independently exercises every candidate failure class.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/negative-output"
awk '
    $2 == "builtin001" { next }
    $2 == "builtin002" { $1 = "0xdeadbeef" }
    $2 == "builtin003" { $3 = "drivers/net/wrong_module" }
    { print }
' OFS='\t' "${TEST_ROOT}/positive-output/Module.symvers" \
    >"${TEST_ROOT}/negative-output/Module.symvers"
grep -E '[[:space:]]builtin004[[:space:]]' \
    "${TEST_ROOT}/positive-output/Module.symvers" \
    >>"${TEST_ROOT}/negative-output/Module.symvers"

set +e
negative="$(run_gate --report "${TEST_ROOT}/negative-report.tsv" \
    "${TEST_ROOT}/negative-output")"
negative_rc=$?
set -e
[[ "${negative_rc}" -eq 1 ]]
assert_line 'status=FAIL' "${negative}"
assert_line 'candidate_builtin_ok=335' "${negative}"
assert_line 'candidate_missing=1' "${negative}"
assert_line 'candidate_crc_mismatch=1' "${negative}"
assert_line 'candidate_wrong_provider=1' "${negative}"
assert_line 'candidate_duplicate=1' "${negative}"
grep -Fq $'candidate-builtin\tmissing\tbuiltin001\t' \
    "${TEST_ROOT}/negative-report.tsv"
grep -Fq $'candidate-builtin\tcrc_mismatch\tbuiltin002\t' \
    "${TEST_ROOT}/negative-report.tsv"
grep -Fq $'candidate-builtin\twrong_provider\tbuiltin003\t' \
    "${TEST_ROOT}/negative-report.tsv"
grep -Fq $'candidate-builtin\tduplicate\tbuiltin004\t' \
    "${TEST_ROOT}/negative-report.tsv"

# module_layout is checked explicitly, not merely included in an aggregate.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/bad-layout-output"
awk '$2 == "module_layout" { $1 = "0x00000000" } { print }' OFS='\t' \
    "${TEST_ROOT}/positive-output/Module.symvers" \
    >"${TEST_ROOT}/bad-layout-output/Module.symvers"
set +e
bad_layout="$(run_gate "${TEST_ROOT}/bad-layout-output")"
bad_layout_rc=$?
set -e
[[ "${bad_layout_rc}" -eq 1 ]]
assert_line 'candidate_crc_mismatch=1' "${bad_layout}"
assert_line 'module_layout_expected=a415c974' "${bad_layout}"
assert_line 'module_layout_actual=00000000@vmlinux' "${bad_layout}"

# A copied/stale Module.symvers can match stock while belonging to another
# vmlinux. The independently extracted __crc_* objects must catch all three
# binding failure shapes.
set +e
stale_symvers="$(FAKE_NM_MODE=vmlinux_crc_mismatch run_gate \
    "${TEST_ROOT}/positive-output")"
stale_symvers_rc=$?
set -e
[[ "${stale_symvers_rc}" -eq 1 ]]
assert_line 'candidate_crc_mismatch=0' "${stale_symvers}"
assert_line 'candidate_vmlinux_crc_mismatch=1' "${stale_symvers}"
assert_line 'candidate_vmlinux_crc_ok=338' "${stale_symvers}"

set +e
vmlinux_crc_missing="$(FAKE_NM_MODE=vmlinux_crc_missing run_gate \
    "${TEST_ROOT}/positive-output")"
vmlinux_crc_missing_rc=$?
set -e
[[ "${vmlinux_crc_missing_rc}" -eq 1 ]]
assert_line 'candidate_vmlinux_crc_missing=1' "${vmlinux_crc_missing}"

set +e
vmlinux_crc_duplicate="$(FAKE_NM_MODE=vmlinux_crc_duplicate run_gate \
    "${TEST_ROOT}/positive-output")"
vmlinux_crc_duplicate_rc=$?
set -e
[[ "${vmlinux_crc_duplicate_rc}" -eq 1 ]]
assert_line 'candidate_vmlinux_crc_duplicate=1' "${vmlinux_crc_duplicate}"

set +e
vmlinux_export_missing="$(FAKE_NM_MODE=vmlinux_export_missing run_gate \
    "${TEST_ROOT}/positive-output")"
vmlinux_export_missing_rc=$?
set -e
[[ "${vmlinux_export_missing_rc}" -eq 1 ]]
assert_line 'candidate_vmlinux_export_missing=1' "${vmlinux_export_missing}"
assert_line 'candidate_vmlinux_export_duplicate=0' "${vmlinux_export_missing}"

set +e
vmlinux_export_duplicate="$(FAKE_NM_MODE=vmlinux_export_duplicate run_gate \
    "${TEST_ROOT}/positive-output")"
vmlinux_export_duplicate_rc=$?
set -e
[[ "${vmlinux_export_duplicate_rc}" -eq 1 ]]
assert_line 'candidate_vmlinux_export_missing=0' "${vmlinux_export_duplicate}"
assert_line 'candidate_vmlinux_export_duplicate=1' "${vmlinux_export_duplicate}"

# The 29 symbols intentionally supplied by another shipped module must not be
# duplicated by the candidate kernel or any candidate-built module.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/inter-symvers-output"
printf '0x20000001\tinter001\tvmlinux\tEXPORT_SYMBOL\n' \
    >>"${TEST_ROOT}/inter-symvers-output/Module.symvers"
set +e
inter_symvers_collision="$(run_gate \
    "${TEST_ROOT}/inter-symvers-output")"
inter_symvers_collision_rc=$?
set -e
[[ "${inter_symvers_collision_rc}" -eq 1 ]]
assert_line 'candidate_inter_ok=28' "${inter_symvers_collision}"
assert_line 'candidate_inter_symvers_collision=1' "${inter_symvers_collision}"
assert_line 'candidate_inter_vmlinux_crc_collision=0' "${inter_symvers_collision}"
assert_line 'candidate_inter_vmlinux_export_collision=0' "${inter_symvers_collision}"

set +e
inter_vmlinux_collision="$(FAKE_NM_MODE=vmlinux_inter_collision run_gate \
    "${TEST_ROOT}/positive-output")"
inter_vmlinux_collision_rc=$?
set -e
[[ "${inter_vmlinux_collision_rc}" -eq 1 ]]
assert_line 'candidate_inter_ok=28' "${inter_vmlinux_collision}"
assert_line 'candidate_inter_symvers_collision=0' "${inter_vmlinux_collision}"
assert_line 'candidate_inter_vmlinux_crc_collision=1' "${inter_vmlinux_collision}"
assert_line 'candidate_inter_vmlinux_export_collision=0' "${inter_vmlinux_collision}"

set +e
inter_vmlinux_export_collision="$(
    FAKE_NM_MODE=vmlinux_inter_export_collision run_gate \
        "${TEST_ROOT}/positive-output"
)"
inter_vmlinux_export_collision_rc=$?
set -e
[[ "${inter_vmlinux_export_collision_rc}" -eq 1 ]]
assert_line 'candidate_inter_ok=28' "${inter_vmlinux_export_collision}"
assert_line 'candidate_inter_symvers_collision=0' \
    "${inter_vmlinux_export_collision}"
assert_line 'candidate_inter_vmlinux_crc_collision=0' \
    "${inter_vmlinux_export_collision}"
assert_line 'candidate_inter_vmlinux_export_collision=1' \
    "${inter_vmlinux_export_collision}"

# Image must be the exact trusted-objcopy projection of vmlinux, and Image.gz
# must decompress to that Image. A replaced boot artifact is malformed input.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/replaced-image-output"
printf 'replacement\n' >>"${TEST_ROOT}/replaced-image-output/arch/arm64/boot/Image"
set +e
run_gate "${TEST_ROOT}/replaced-image-output" >/dev/null \
    2>"${TEST_ROOT}/replaced-image.err"
replaced_image_rc=$?
set -e
[[ "${replaced_image_rc}" -eq 2 ]]
grep -Fq 'Image is not the deterministic objcopy output' \
    "${TEST_ROOT}/replaced-image.err"

# All five stock modules must carry the same real module vermagic.
set +e
stock_vermagic_split="$(FAKE_MODINFO_MODE=vermagic_split run_gate \
    "${TEST_ROOT}/positive-output" 2>"${TEST_ROOT}/stock-vermagic-split.err")"
stock_vermagic_split_rc=$?
set -e
[[ "${stock_vermagic_split_rc}" -eq 1 ]]
assert_line 'status=FAIL' "${stock_vermagic_split}"
assert_line 'stock_invariant_errors=2' "${stock_vermagic_split}"
assert_line 'stock_vermagic=<conflict>' "${stock_vermagic_split}"
grep -Fq 'stock modules do not share one vermagic' \
    "${TEST_ROOT}/stock-vermagic-split.err"
grep -Fq 'stock vermagic authority changed' \
    "${TEST_ROOT}/stock-vermagic-split.err"

# Agreement among five replaced modules is not authority. Pin the measured
# stock literal so a uniformly swapped module set cannot redefine the target.
set +e
stock_vermagic_replaced="$(FAKE_MODINFO_MODE=vermagic_replaced run_gate \
    "${TEST_ROOT}/positive-output" 2>"${TEST_ROOT}/stock-vermagic-replaced.err")"
stock_vermagic_replaced_rc=$?
set -e
[[ "${stock_vermagic_replaced_rc}" -eq 1 ]]
assert_line 'stock_invariant_errors=1' "${stock_vermagic_replaced}"
assert_line 'stock_vermagic=3.18.120 SMP preempt mod_unload modversions aarch64' \
    "${stock_vermagic_replaced}"
grep -Fq 'stock vermagic authority changed' \
    "${TEST_ROOT}/stock-vermagic-replaced.err"

# The candidate vermagic comes from the ELF vmlinux object. A self-consistent
# candidate output with the common out-of-tree "+" suffix must still fail the
# exact stock comparison.
make_candidate_output "${TEST_ROOT}/bad-vermagic-output" \
    '3.18.119+ SMP preempt mod_unload modversions aarch64'
set +e
bad_vermagic="$(run_gate "${TEST_ROOT}/bad-vermagic-output" \
    2>"${TEST_ROOT}/bad-vermagic.err")"
bad_vermagic_rc=$?
set -e
[[ "${bad_vermagic_rc}" -eq 1 ]]
assert_line 'candidate_uts_release=3.18.119+' "${bad_vermagic}"
assert_line 'candidate_vermagic=3.18.119+ SMP preempt mod_unload modversions aarch64' \
    "${bad_vermagic}"
assert_line 'candidate_metadata_errors=1' "${bad_vermagic}"
grep -Fq 'does not equal stock' "${TEST_ROOT}/bad-vermagic.err"

# A version-like string supplied alongside a stripped/different kernel is not
# evidence. The exact vmlinux must retain the real kernel/module.c ELF object.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/no-vermagic-output"
"${CROSS_OBJCOPY}" --strip-symbol=vermagic "${TEST_ROOT}/no-vermagic-output/vmlinux"
"${CROSS_OBJCOPY}" -O binary -R .note -R .note.gnu.build-id -R .comment -S \
    "${TEST_ROOT}/no-vermagic-output/vmlinux" \
    "${TEST_ROOT}/no-vermagic-output/arch/arm64/boot/Image"
gzip -n -f -9 -c "${TEST_ROOT}/no-vermagic-output/arch/arm64/boot/Image" \
    >"${TEST_ROOT}/no-vermagic-output/arch/arm64/boot/Image.gz"
set +e
run_gate "${TEST_ROOT}/no-vermagic-output" >/dev/null \
    2>"${TEST_ROOT}/no-vermagic.err"
no_vermagic_rc=$?
set -e
[[ "${no_vermagic_rc}" -eq 2 ]]
grep -Fq 'expected exactly one ELF vermagic object, found 0' \
    "${TEST_ROOT}/no-vermagic.err"

# CONFIG_MODULES and CONFIG_MODVERSIONS are loadability requirements, not
# implied by a matching Module.symvers text file.
make_candidate_output "${TEST_ROOT}/modules-off-output" \
    '3.18.119 SMP preempt aarch64' n n
set +e
modules_off="$(run_gate "${TEST_ROOT}/modules-off-output" \
    2>"${TEST_ROOT}/modules-off.err")"
modules_off_rc=$?
set -e
[[ "${modules_off_rc}" -eq 1 ]]
assert_line 'candidate_config_modules=n' "${modules_off}"
assert_line 'candidate_config_modversions=n' "${modules_off}"
grep -Fq 'CONFIG_MODULES is not y' "${TEST_ROOT}/modules-off.err"

make_candidate_output "${TEST_ROOT}/modversions-off-output" \
    '3.18.119 SMP preempt mod_unload aarch64' y n
set +e
modversions_off="$(run_gate "${TEST_ROOT}/modversions-off-output" \
    2>"${TEST_ROOT}/modversions-off.err")"
modversions_off_rc=$?
set -e
[[ "${modversions_off_rc}" -eq 1 ]]
assert_line 'candidate_config_modules=y' "${modversions_off}"
assert_line 'candidate_config_modversions=n' "${modversions_off}"
grep -Fq 'CONFIG_MODVERSIONS is not y' "${TEST_ROOT}/modversions-off.err"

# Generated metadata must describe one build, not a hand-edited .config paired
# with stale auto.conf/autoconf.h.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/config-drift-output"
sed -i '/^CONFIG_MODVERSIONS=/d' \
    "${TEST_ROOT}/config-drift-output/include/config/auto.conf"
set +e
run_gate "${TEST_ROOT}/config-drift-output" >/dev/null \
    2>"${TEST_ROOT}/config-drift.err"
config_drift_rc=$?
set -e
[[ "${config_drift_rc}" -eq 2 ]]
grep -Fq 'generated config disagrees for CONFIG_MODVERSIONS' \
    "${TEST_ROOT}/config-drift.err"

# The shipped modules are unsigned. A candidate that forces module signatures
# can match every CRC and still reject all five at load time.
make_candidate_output "${TEST_ROOT}/signature-force-output" \
    '3.18.119 SMP preempt mod_unload modversions aarch64' y y y y n
set +e
signature_force="$(run_gate "${TEST_ROOT}/signature-force-output" \
    2>"${TEST_ROOT}/signature-force.err")"
signature_force_rc=$?
set -e
[[ "${signature_force_rc}" -eq 1 ]]
assert_line 'candidate_config_module_sig=y' "${signature_force}"
assert_line 'candidate_config_module_sig_force=y' "${signature_force}"
assert_line 'module_signature_compatible=no' "${signature_force}"
grep -Fq 'rejects one or more unsigned stock modules' \
    "${TEST_ROOT}/signature-force.err"

# A consistently signed stock set is compatible when enforcement is off, but
# force-on still fails closed because a vmlinux build output does not prove its
# trusted key is the key that signed those external modules.
signed_stock="$(FAKE_MODINFO_MODE=signed_all run_gate \
    "${TEST_ROOT}/positive-output")"
assert_line 'status=PASS' "${signed_stock}"
assert_line 'stock_module_signature=signed' "${signed_stock}"
assert_line 'module_signature_compatible=yes' "${signed_stock}"
set +e
signed_force="$(FAKE_MODINFO_MODE=signed_all run_gate \
    "${TEST_ROOT}/signature-force-output" 2>"${TEST_ROOT}/signed-force.err")"
signed_force_rc=$?
set -e
[[ "${signed_force_rc}" -eq 1 ]]
assert_line 'stock_module_signature=signed' "${signed_force}"
assert_line 'module_signature_compatible=no' "${signed_force}"
grep -Fq 'cannot prove the vmlinux trusted key matches' \
    "${TEST_ROOT}/signed-force.err"

# A mixed stock set is loadable when enforcement is off; with force on, its
# unsigned members must be rejected.
stock_signature_mixed="$(FAKE_MODINFO_MODE=signed_one run_gate \
    "${TEST_ROOT}/positive-output")"
assert_line 'status=PASS' "${stock_signature_mixed}"
assert_line 'stock_module_signature=mixed' "${stock_signature_mixed}"
assert_line 'module_signature_compatible=yes' "${stock_signature_mixed}"
set +e
mixed_force="$(FAKE_MODINFO_MODE=signed_one run_gate \
    "${TEST_ROOT}/signature-force-output" 2>"${TEST_ROOT}/mixed-force.err")"
mixed_force_rc=$?
set -e
[[ "${mixed_force_rc}" -eq 1 ]]
assert_line 'stock_module_signature=mixed' "${mixed_force}"
assert_line 'module_signature_compatible=no' "${mixed_force}"
grep -Fq 'rejects one or more unsigned stock modules' \
    "${TEST_ROOT}/mixed-force.err"

# The stock side is independently verified from __ksymtab_*/__crc_* metadata.
set +e
missing_crc="$(FAKE_NM_MODE=missing_crc run_gate "${TEST_ROOT}/positive-output")"
missing_crc_rc=$?
set -e
[[ "${missing_crc_rc}" -eq 1 ]]
assert_line 'stock_inter_missing_crc=1' "${missing_crc}"

set +e
crc_mismatch="$(FAKE_NM_MODE=crc_mismatch run_gate "${TEST_ROOT}/positive-output")"
crc_mismatch_rc=$?
set -e
[[ "${crc_mismatch_rc}" -eq 1 ]]
assert_line 'stock_inter_crc_mismatch=1' "${crc_mismatch}"
assert_line 'stock_inter_duplicate=0' "${crc_mismatch}"

set +e
duplicate_provider="$(FAKE_NM_MODE=duplicate_provider run_gate \
    "${TEST_ROOT}/positive-output")"
duplicate_provider_rc=$?
set -e
[[ "${duplicate_provider_rc}" -eq 1 ]]
assert_line 'stock_inter_duplicate=1' "${duplicate_provider}"

# Malformed candidate input is an input error, not an apparent ABI mismatch.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/malformed-output"
printf 'not-a-crc symbol vmlinux\n' \
    >"${TEST_ROOT}/malformed-output/Module.symvers"
set +e
run_gate "${TEST_ROOT}/malformed-output" >/dev/null 2>"${TEST_ROOT}/malformed.err"
malformed_rc=$?
set -e
[[ "${malformed_rc}" -eq 2 ]]
grep -Fq 'invalid CRC' "${TEST_ROOT}/malformed.err"

inventory="$(PATH="${TEST_ROOT}/fakebin:${PATH}" "${GATE}" \
    --module-dir "${TEST_ROOT}/modules" --inventory-only)"
assert_line 'modules=5' "${inventory}"
assert_line 'expected_pairs=368' "${inventory}"
assert_line 'built_in_providers=339' "${inventory}"
assert_line 'inter_module_providers=29' "${inventory}"
assert_line 'module_layout=a415c974' "${inventory}"
assert_line 'stock_vermagic_expected=3.18.119 SMP preempt mod_unload modversions aarch64' \
    "${inventory}"
assert_line 'stock_vermagic=3.18.119 SMP preempt mod_unload modversions aarch64' \
    "${inventory}"
assert_line 'stock_module_signature=unsigned' "${inventory}"

# Source mode reads native Kbuild paths, without any stock digest/count fallback.
cp -a "${TEST_ROOT}/positive-output" "${TEST_ROOT}/source-output"
SOURCE_PREFIX=drivers/misc/mediatek/connectivity/source
declare -A SOURCE_PATH=(
    [wmt_drv]=common/wmt_drv.ko
    [wmt_chrdev_wifi]=wlan/adaptor/wmt_chrdev_wifi.ko
    [wlan_drv_gen2]=wlan/core/gen2/wlan_drv_gen2.ko
    [bt_drv]=bt/legacy/bt_drv.ko
    [gps_drv]=gps/gps_drv.ko
)
for module in "${!SOURCE_PATH[@]}"; do
    path="${TEST_ROOT}/source-output/${SOURCE_PREFIX}/${SOURCE_PATH[${module}]}"
    mkdir -p "$(dirname "${path}")"
    cp "${TEST_ROOT}/modules/${module}.ko" "${path}"
    printf 'source fixture\n' >>"${path}"
done
printf 'CONFIG_MTK_CONNECTIVITY_SOURCE=m\n' >>"${TEST_ROOT}/source-output/.config"
printf 'CONFIG_MTK_CONNECTIVITY_SOURCE=m\n' >>"${TEST_ROOT}/source-output/include/config/auto.conf"
printf '#define CONFIG_MTK_CONNECTIVITY_SOURCE_MODULE 1\n' >>"${TEST_ROOT}/source-output/include/generated/autoconf.h"
{
    printf '0x30000001\tsource_only_symbol\tvmlinux\tEXPORT_SYMBOL\n'
    for i in $(seq 1 29); do
        printf '0x%08x\tinter%03d\t%s/common/wmt_drv\tEXPORT_SYMBOL\n' \
            "$((0x20000000 + i))" "${i}" "${SOURCE_PREFIX}"
    done
    printf '0x40000001\tunused_source_export\t%s/common/wmt_drv\tEXPORT_SYMBOL\n' "${SOURCE_PREFIX}"
} >>"${TEST_ROOT}/source-output/Module.symvers"
run_source_gate() {
    PATH="${TEST_ROOT}/fakebin:${PATH}" FAKE_SOURCE_MODE=1 \
        "${GATE}" --module-mode source "$@"
}
source_positive="$(run_source_gate --report "${TEST_ROOT}/source-report.tsv" "${TEST_ROOT}/source-output")"
assert_line 'status=PASS' "${source_positive}"
assert_line 'module_mode=source' "${source_positive}"
assert_line 'expected_pairs=369' "${source_positive}"
assert_line 'built_in_expected=340' "${source_positive}"
assert_line 'inter_module_expected=29' "${source_positive}"
assert_line 'undefined_symbols=368' "${source_positive}"
assert_line 'versioned_imports=373' "${source_positive}"
assert_line 'module_exports_expected=30' "${source_positive}"
assert_line 'candidate_module_exports_ok=30' "${source_positive}"
assert_line 'candidate_inter_ok=29' "${source_positive}"
! grep -q '^stock_' <<<"${source_positive}"
cp -a "${TEST_ROOT}/source-output" "${TEST_ROOT}/source-layout-change"
awk '$2 == "module_layout" { $1 = "0xdeadbeef" } { print }' OFS='\t' \
    "${TEST_ROOT}/source-output/Module.symvers" >"${TEST_ROOT}/source-layout-change/Module.symvers"
source_new_layout="$(FAKE_MODULE_LAYOUT=deadbeef run_source_gate "${TEST_ROOT}/source-layout-change")"
assert_line 'status=PASS' "${source_new_layout}"
assert_line 'module_layout_expected=deadbeef' "${source_new_layout}"
assert_line 'module_layout_actual=deadbeef@vmlinux' "${source_new_layout}"

for defect in missing_crc extra_crc duplicate_crc extra_undefined; do
    if FAKE_IMPORT_MODE="${defect}" run_source_gate "${TEST_ROOT}/source-output" \
            >"${TEST_ROOT}/source-${defect}.out" 2>"${TEST_ROOT}/source-${defect}.err"; then
        printf 'source import defect escaped: %s\n' "${defect}" >&2
        exit 1
    fi
    grep -Eq 'import CRC coverage|duplicate import records' "${TEST_ROOT}/source-${defect}.err"
done
for defect in missing wrong_provider crc_mismatch duplicate; do
    cp -a "${TEST_ROOT}/source-output" "${TEST_ROOT}/source-${defect}"
    awk -v defect="${defect}" '
        $2 == "inter001" {
            if (defect == "missing") next
            if (defect == "wrong_provider") $3 = "drivers/other/unknown"
            if (defect == "crc_mismatch") $1 = "0xdeadbeef"
            if (defect == "duplicate") print
        }
        { print }
    ' OFS='\t' "${TEST_ROOT}/source-output/Module.symvers" \
        >"${TEST_ROOT}/source-${defect}/Module.symvers"
    if output="$(run_source_gate "${TEST_ROOT}/source-${defect}")"; then
        printf 'source provider defect escaped: %s\n' "${defect}" >&2
        exit 1
    fi
    assert_line "candidate_inter_${defect}=1" "${output}"
done
if output="$(FAKE_NM_MODE=unused_export_mismatch run_source_gate "${TEST_ROOT}/source-output")"; then
    echo 'unconsumed source export mismatch escaped' >&2
    exit 1
fi
assert_line 'candidate_module_exports_ok=29' "${output}"
cp -a "${TEST_ROOT}/source-output" "${TEST_ROOT}/source-stock-substitution"
cp "${TEST_ROOT}/modules/bt_drv.ko" \
    "${TEST_ROOT}/source-stock-substitution/${SOURCE_PREFIX}/bt/legacy/bt_drv.ko"
if run_source_gate "${TEST_ROOT}/source-stock-substitution" \
        >/dev/null 2>"${TEST_ROOT}/source-stock-substitution.err"; then
    echo 'stock substitution escaped source mode' >&2
    exit 1
fi
grep -Fq 'source mode received the pinned stock binary' "${TEST_ROOT}/source-stock-substitution.err"

# Receipt validation shares the dynamic inventory rules with all build/stage callers.
SOURCE_ABI="${source_positive}" python3 - "${TEST_ROOT}/source-contract" <<'CONTRACT_EOF'
import os, pathlib, sys
abi = dict(line.split("=", 1) for line in os.environ["SOURCE_ABI"].splitlines())
mapping = {
    "module_mode": "module_mode", "module_install": "module_install",
    "module_strip_tool_sha256": "module_strip_tool_sha256", "modules": "modules", "abi.status": "status",
    "abi.metadata_errors": "candidate_metadata_errors", "module_invariant_errors": "module_invariant_errors",
    "abi.module_signature_compatible": "module_signature_compatible", "module_signature": "module_signature",
    "expected_pairs": "expected_pairs", "builtin_expected": "built_in_expected",
    "inter_module_expected": "inter_module_expected", "module_inter_ok": "module_inter_ok",
    "candidate_builtin_ok": "candidate_builtin_ok", "candidate_inter_ok": "candidate_inter_ok",
    "module_exports": "module_exports_expected", "candidate_exports_ok": "candidate_module_exports_ok",
    "undefined_symbols": "undefined_symbols", "versioned_imports": "versioned_imports",
    "module_layout": "module_layout_actual", "module_layout_vmlinux": "module_layout_vmlinux_actual",
}
for module in ("wmt_drv", "wmt_chrdev_wifi", "wlan_drv_gen2", "bt_drv", "gps_drv"):
    for field in ("path", "sha256", "bytes", "installed_sha256", "installed_bytes"):
        mapping[f"module.{module}.{field}"] = f"module_{field}.{module}.ko"
pathlib.Path(sys.argv[1]).write_text("".join(f"kernel.{key}={abi[value]}\n" for key, value in mapping.items()))
CONTRACT_EOF
"${GATE}" --verify-contract "${TEST_ROOT}/source-contract" >/dev/null
mkdir "${TEST_ROOT}/installed-source-modules"
for module in "${!SOURCE_PATH[@]}"; do
    "${CROSS_OBJCOPY%objcopy}strip" --strip-debug -o \
        "${TEST_ROOT}/installed-source-modules/${module}.ko" \
        "${TEST_ROOT}/source-output/${SOURCE_PREFIX}/${SOURCE_PATH[${module}]}"
done
"${GATE}" --verify-contract "${TEST_ROOT}/source-contract" \
    --verify-installed "${TEST_ROOT}/installed-source-modules" >/dev/null
printf 'installed module tamper\n' >>"${TEST_ROOT}/installed-source-modules/bt_drv.ko"
if "${GATE}" --verify-contract "${TEST_ROOT}/source-contract" \
        --verify-installed "${TEST_ROOT}/installed-source-modules" \
        >/dev/null 2>"${TEST_ROOT}/installed-tamper.err"; then
    echo 'installed source-module tamper escaped' >&2
    exit 1
fi
grep -Fq 'installed bt_drv.ko differs' "${TEST_ROOT}/installed-tamper.err"
for defect in count layout hash missing; do
    CONTRACT_DEFECT="${defect}" python3 - "${TEST_ROOT}/source-contract" "${TEST_ROOT}/bad-contract" <<'BAD_CONTRACT_EOF'
import os, pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
defect = os.environ["CONTRACT_DEFECT"]
if defect == "count":
    text = text.replace("kernel.expected_pairs=369", "kernel.expected_pairs=368")
elif defect == "layout":
    text = text.replace("a415c974@vmlinux", "deadbeef@vmlinux")
elif defect == "hash":
    lines = [line for line in text.splitlines() if not line.startswith("kernel.module.bt_drv.sha256=")]
    text = "\n".join(lines) + "\nkernel.module.bt_drv.sha256=invalid\n"
else:
    text = "\n".join(line for line in text.splitlines() if not line.startswith("kernel.undefined_symbols=")) + "\n"
pathlib.Path(sys.argv[2]).write_text(text)
BAD_CONTRACT_EOF
    if "${GATE}" --verify-contract "${TEST_ROOT}/bad-contract" >/dev/null 2>"${TEST_ROOT}/bad-contract.err"; then
        printf 'source contract defect escaped: %s\n' "${defect}" >&2
        exit 1
    fi
done
printf 'K50 SOURCE MODULE ABI AND RECEIPT FIXTURE MATRIX: PASS\n'

printf 'K50 MODULE ABI GATE FIXTURE MATRIX: PASS\n'
