#!/usr/bin/env bash
# Offline ABI gate for the five MediaTek connectivity modules.
#
# Stock mode pins the shipped files; source mode inventories the actual build's
# modules, including every undefined symbol, import CRC and exported provider.
# The complete final KERNEL_OBJ supplies generated config, vmlinux vermagic,
# built-in CRCs and Module.symvers for the same module/kernel build. Source HEAD/tree provenance is owned separately by the clean-build
# source-state receipt; this gate does not attribute an arbitrary output tree
# to the currently checked-out source. This tool never invokes modprobe in load
# mode and never modifies a module or CRC.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../../.." && pwd)"
DEFAULT_MODULE_DIR="${PROJECT_ROOT}/lineage-17.1/vendor/xsh/k50sv1_64_bsp/proprietary/vendor/lib/modules"
DEFAULT_CANDIDATE_OUTPUT="${PROJECT_ROOT}/lineage-17.1/out/target/product/k50sv1_64_bsp/obj/KERNEL_OBJ"
CROSS_OBJCOPY="${PROJECT_ROOT}/lineage-17.1/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android-objcopy"

CROSS_STRIP="${CROSS_OBJCOPY%objcopy}strip"

module_dir=""
module_mode=stock
contract=""
installed_dir=""
report=""
inventory_only=0
candidate_output=""

usage() {
    cat <<'EOF'
usage: check-module-abi.sh [--module-mode stock|source] [--module-dir DIR]
                           [--report FILE|-] [CANDIDATE_OUTPUT]
       check-module-abi.sh [--module-mode stock|source] [--module-dir DIR]
                           --inventory-only
       check-module-abi.sh --verify-contract RECEIPT [--verify-installed DIR]

Compare the five connectivity modules with one exact candidate kernel build
output. Stock mode (the default) pins the shipped files. Source mode reads the
five native Kbuild paths below CANDIDATE_OUTPUT, or an explicit flat module
inventory with --module-dir. It checks all undefined symbols and import CRCs
against vmlinux and the modules' own exports, including Module.symvers providers.
--verify-contract checks the source-module fields already bound by a clean-build
receipt. --verify-installed additionally binds the installed files to the
receipt's strip-debug projections. These receipt checks do not re-run the ABI
check or establish source provenance. Source artifact checks hash both the raw
Kbuild modules and temporary copies processed by the toolchain's strip-debug.
The default CANDIDATE_OUTPUT is the Android build's final
out/target/product/k50sv1_64_bsp/obj/KERNEL_OBJ. It must contain .config,
include/config/{auto.conf,kernel.release},
include/generated/{autoconf.h,utsrelease.h}, vmlinux, Module.symvers, and
arch/arm64/boot/{Image,Image.gz}. The optional TSV report records every
expected built-in and inter-module pair. Source revision provenance comes from
the clean-build source-state receipt, not from this offline output check.
Exit status is 0 for a complete match, 1 for an ABI incompatibility, and 2 for
an invalid invocation or unreadable/internally inconsistent build output.
EOF
}

while (($#)); do
    case "$1" in
        --module-mode)
            (($# >= 2)) || { echo "missing value for --module-mode" >&2; exit 2; }
            [[ "$2" == stock || "$2" == source ]] \
                || { echo "--module-mode must be stock or source" >&2; exit 2; }
            module_mode="$2"
            shift 2
            ;;
        --verify-installed)
            (($# >= 2)) || { echo "missing value for --verify-installed" >&2; exit 2; }
            [[ -z "${installed_dir}" ]] || { echo "duplicate --verify-installed" >&2; exit 2; }
            installed_dir="$2"
            shift 2
            ;;
        --verify-contract)
            (($# >= 2)) || { echo "missing value for --verify-contract" >&2; exit 2; }
            [[ -z "${contract}" ]] || { echo "duplicate --verify-contract" >&2; exit 2; }
            contract="$2"
            shift 2
            ;;
        --module-dir)
            (($# >= 2)) || { echo "missing value for --module-dir" >&2; usage >&2; exit 2; }
            module_dir="$2"
            shift 2
            ;;
        --report)
            (($# >= 2)) || { echo "missing value for --report" >&2; usage >&2; exit 2; }
            report="$2"
            shift 2
            ;;
        --inventory-only)
            inventory_only=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            if (($#)); then
                [[ -z "${candidate_output}" && $# -eq 1 ]] \
                    || { echo "too many positional arguments" >&2; usage >&2; exit 2; }
                candidate_output="$1"
                shift
            fi
            ;;
        -*)
            printf 'unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
        *)
            [[ -z "${candidate_output}" ]] \
                || { echo "too many positional arguments" >&2; usage >&2; exit 2; }
            candidate_output="$1"
            shift
            ;;
    esac
done

if [[ -n "${installed_dir}" && -z "${contract}" ]]; then
    echo "--verify-installed requires --verify-contract" >&2
    exit 2
fi
if [[ -n "${contract}" ]]; then
    [[ -z "${candidate_output}${module_dir}${report}" && "${inventory_only}" == 0 ]] \
        || { echo "--verify-contract cannot be combined with artifact options" >&2; exit 2; }
elif ((inventory_only)); then
    [[ -z "${candidate_output}" ]] \
        || { echo "--inventory-only does not accept CANDIDATE_OUTPUT" >&2; exit 2; }
    [[ -z "${report}" ]] \
        || { echo "--report requires a candidate build output" >&2; exit 2; }
else
    [[ -n "${candidate_output}" ]] || candidate_output="${DEFAULT_CANDIDATE_OUTPUT}"
fi

if [[ "${module_mode}" == stock && -z "${module_dir}" ]]; then
    module_dir="${DEFAULT_MODULE_DIR}"
fi
if ((inventory_only)) && [[ "${module_mode}" == source && -z "${module_dir}" ]]; then
    echo "source --inventory-only requires --module-dir" >&2
    exit 2
fi

required_tools=(python3)
[[ -n "${contract}" ]] || required_tools+=(nm modinfo modprobe)
for tool in "${required_tools[@]}"; do
    command -v "${tool}" >/dev/null 2>&1 \
        || { printf 'required tool is unavailable: %s\n' "${tool}" >&2; exit 2; }
done
if (( ! inventory_only )) && [[ -z "${contract}" ]]; then
    [[ -x "${CROSS_OBJCOPY}" ]] \
        || { printf 'required AArch64 objcopy is unavailable: %s\n' "${CROSS_OBJCOPY}" >&2; exit 2; }
fi

if [[ "${module_mode}" == source && -z "${contract}" ]]; then
    [[ -x "${CROSS_STRIP}" ]] \
        || { printf 'required AArch64 strip is unavailable: %s\n' "${CROSS_STRIP}" >&2; exit 2; }
fi

MODE="$(if [[ -n "${contract}" ]]; then echo contract; elif ((inventory_only)); then echo inventory; else echo compare; fi)" \
MODULE_MODE="${module_mode}" CONTRACT="${contract}" INSTALLED_DIR="${installed_dir}" \
MODULE_DIR="${module_dir}" CANDIDATE_OUTPUT="${candidate_output}" REPORT="${report}" \
MODINFO_BIN="$(command -v modinfo)" MODPROBE_BIN="$(command -v modprobe)" \
NM_BIN="$(command -v nm)" OBJCOPY_BIN="${CROSS_OBJCOPY}" STRIP_BIN="${CROSS_STRIP}" \
python3 - <<'PYTHON_EOF'
import collections
import gzip
import hashlib
import os
import pathlib
import re
import struct
import subprocess
import sys
import tempfile


MODULES = (
    "wmt_drv.ko",
    "wmt_chrdev_wifi.ko",
    "wlan_drv_gen2.ko",
    "bt_drv.ko",
    "gps_drv.ko",
)
SOURCE_MODULE_PATHS = {
    "wmt_drv.ko": "common/wmt_drv.ko",
    "wmt_chrdev_wifi.ko": "wlan/adaptor/wmt_chrdev_wifi.ko",
    "wlan_drv_gen2.ko": "wlan/core/gen2/wlan_drv_gen2.ko",
    "bt_drv.ko": "bt/legacy/bt_drv.ko",
    "gps_drv.ko": "gps/gps_drv.ko",
}
SOURCE_MODULE_PATHS = {
    module: "drivers/misc/mediatek/connectivity/source/" + path
    for module, path in SOURCE_MODULE_PATHS.items()
}
EXPECTED_MODULE_SHA256 = {
    "wmt_drv.ko": "f30b22f3c39b8dd5816fee034c6b19d422c608768b345bded7cb29e574cb1c46",
    "wmt_chrdev_wifi.ko": "c1372b4c3759186179ec8c2e720ef05ae771d2a16a36b84e2d8e07fbca155a19",
    "wlan_drv_gen2.ko": "658b5fa6378267368c4b809f540b270efaee80062c374fb7250db7928a8bb84f",
    "bt_drv.ko": "d64e7dccc2453ab00dca022f68193940de303c282abcaeb1c67b46ffe7925a4b",
    "gps_drv.ko": "af865da4f38bbf45a31222ecd2b0445926eecd41e391bdd11abd0e49c1033949",
}
EXPECTED_PAIR_COUNT = 368
EXPECTED_BUILTIN_COUNT = 339
EXPECTED_INTER_COUNT = 29
EXPECTED_MODULE_LAYOUT = "a415c974"
EXPECTED_STOCK_VERMAGIC = (
    "3.18.119 SMP preempt mod_unload modversions aarch64"
)
CONFIG_KEYS = (
    "CONFIG_MODULES",
    "CONFIG_MODVERSIONS",
    "CONFIG_MODULE_SIG",
    "CONFIG_MODULE_SIG_FORCE",
    "CONFIG_MODULE_SIG_ALL",
    "CONFIG_MTK_CONNECTIVITY_SOURCE",
)

MODE = os.environ["MODE"]
MODULE_MODE = os.environ["MODULE_MODE"]
MODULE_DIR = pathlib.Path(os.environ["MODULE_DIR"]) if os.environ["MODULE_DIR"] else None
CONTRACT = os.environ["CONTRACT"]
INSTALLED_DIR = os.environ["INSTALLED_DIR"]
CANDIDATE_OUTPUT = (
    pathlib.Path(os.environ["CANDIDATE_OUTPUT"])
    if os.environ["CANDIDATE_OUTPUT"]
    else None
)
REPORT = os.environ["REPORT"]
MODINFO = os.environ["MODINFO_BIN"]
MODPROBE = os.environ["MODPROBE_BIN"]
NM = os.environ["NM_BIN"]
OBJCOPY = os.environ["OBJCOPY_BIN"]
STRIP = os.environ["STRIP_BIN"]
CANDIDATE_INPUTS = []
MODULE_INPUTS = {}
MODULE_METADATA = {}


class InputError(Exception):
    pass


def crc32(text, context):
    value = text.strip().lower()
    if value.startswith("0x"):
        value = value[2:]
    if not re.fullmatch(r"[0-9a-f]+", value):
        raise InputError(f"{context}: invalid CRC {text!r}")
    number = int(value, 16)
    if number > 0xFFFFFFFF:
        raise InputError(f"{context}: CRC exceeds 32 bits: {text!r}")
    return f"{number:08x}"


def run_readonly(command, context):
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
        )
    except OSError as error:
        raise InputError(f"{context}: could not execute {command[0]}: {error}") from error
    if result.returncode:
        detail = result.stderr.strip().splitlines()
        suffix = f": {detail[0]}" if detail else ""
        raise InputError(f"{context}: command exited {result.returncode}{suffix}")
    return result.stdout


def modinfo_field(path, module, field, *, required=False):
    text = run_readonly(
        [MODINFO, "-F", field, os.fspath(path)],
        f"read {field} from {module}",
    )
    lines = text.splitlines()
    if len(lines) > 1:
        raise InputError(f"{module}: modinfo returned multiple {field} values")
    value = lines[0].strip() if lines else ""
    if required and not value:
        raise InputError(f"{module}: modinfo returned an empty {field}")
    if any(ord(character) < 0x20 or ord(character) > 0x7E for character in value):
        raise InputError(f"{module}: modinfo returned unsafe {field} text")
    return value


def parse_modversions(text, module):
    records = []
    for line_number, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        fields = line.split()
        if len(fields) < 2:
            raise InputError(
                f"{module}: malformed --dump-modversions line {line_number}: {line!r}"
            )
        crc = crc32(fields[0], f"{module}: --dump-modversions line {line_number}")
        symbol = fields[1]
        if not symbol or any(character.isspace() for character in symbol):
            raise InputError(f"{module}: invalid imported symbol on line {line_number}")
        records.append((symbol, crc, module))
    return records


def parse_nm(text, module):
    export_counts = collections.Counter()
    crc_values = collections.defaultdict(list)
    for line_number, line in enumerate(text.splitlines(), 1):
        fields = line.split()
        if len(fields) < 2:
            continue
        symbol = fields[-1]
        if symbol.startswith("__ksymtab_") and symbol != "__ksymtab_strings":
            export_counts[symbol[len("__ksymtab_"):]] += 1
        elif symbol.startswith("__crc_"):
            if len(fields) < 3 or fields[-2] not in ("A", "a"):
                raise InputError(f"{module}: {symbol} is not an absolute CRC symbol")
            crc_values[symbol[len("__crc_"):]].append(
                crc32(fields[0], f"{module}: nm line {line_number}")
            )
    return export_counts, crc_values


def parse_vmlinux_crcs(text, path):
    """Extract exact absolute __crc_* symbol values from candidate vmlinux."""
    crc_values = collections.defaultdict(list)
    for line_number, line in enumerate(text.splitlines(), 1):
        fields = line.split()
        if len(fields) < 3 or not fields[-1].startswith("__crc_"):
            continue
        symbol_type = fields[-2]
        symbol = fields[-1][len("__crc_"):]
        if symbol_type not in ("A", "a"):
            raise InputError(
                f"{path}: __crc_{symbol} at nm line {line_number} "
                f"is type {symbol_type}, expected absolute"
            )
        crc_values[symbol].append(
            {
                "crc": crc32(fields[0], f"{path}: nm line {line_number}"),
                "line": line_number,
            }
        )
    return crc_values


def validate_source_imports(path, module, imports):
    with path.open("rb") as handle:
        header = handle.read(20)
    if (len(header) != 20 or header[:7] != b"\x7fELF\x02\x01\x01"
            or struct.unpack_from("<HH", header, 16) != (1, 183)):
        raise InputError(f"{module}: expected an ELF64 little-endian AArch64 module")
    undefined = collections.Counter()
    for line in run_readonly([NM, "--undefined-only", os.fspath(path)],
                             f"read all undefined symbols from {module}").splitlines():
        fields = line.split()
        if len(fields) != 2 or fields[0] not in ("U", "w", "v"):
            raise InputError(f"{module}: malformed undefined symbol record: {line!r}")
        undefined[fields[1]] += 1
    versioned = collections.Counter(symbol for symbol, _crc, _module in imports)
    duplicates = sorted(symbol for symbol, count in versioned.items() if count != 1)
    duplicates += sorted(symbol for symbol, count in undefined.items() if count != 1)
    if duplicates:
        raise InputError(f"{module}: duplicate import records: {','.join(duplicates)}")
    missing = sorted(set(undefined) - set(versioned))
    extra = sorted(set(versioned) - set(undefined) - {"module_layout"})
    if missing or extra or versioned.get("module_layout") != 1:
        raise InputError(
            f"{module}: import CRC coverage differs from the complete undefined-symbol set: "
            f"missing={','.join(missing) or '<none>'}; "
            f"extra={','.join(extra) or '<none>'}; "
            f"module_layout_records={versioned.get('module_layout', 0)}"
        )
    return len(undefined), len(imports)


def installed_module_metadata(path, module):
    # Mirror INSTALL_MOD_STRIP=1 without modifying the Kbuild output.
    with tempfile.TemporaryDirectory(prefix="k50-module-strip.") as temporary:
        installed = pathlib.Path(temporary) / module
        run_readonly([STRIP, "--strip-debug", "-o", os.fspath(installed), os.fspath(path)],
                     f"derive modules_install bytes for {module}")
        digest, size = file_sha256_and_size(installed, f"installed reference {module}")
    return {"installed_sha256": digest, "installed_bytes": size}


def collect_module_inventory():
    if MODULE_DIR is None:
        for module, relative in SOURCE_MODULE_PATHS.items():
            MODULE_INPUTS[module] = CANDIDATE_OUTPUT / relative
    else:
        collect_flat_module_paths()

    imports = []
    exports = {}
    export_crcs = {}
    vermagics = {}
    signatures = {}
    module_sha256 = {}
    for module in MODULES:
        path = MODULE_INPUTS[module]
        if not path.is_file() or path.is_symlink():
            raise InputError(f"{MODULE_MODE} module is missing: {path}")
        digest, size = file_sha256_and_size(path, f"{MODULE_MODE} module {module}")
        module_sha256[module] = digest
        if MODULE_MODE == "stock" and digest != EXPECTED_MODULE_SHA256[module]:
            raise InputError(
                f"stock module digest changed for {module}: "
                f"expected {EXPECTED_MODULE_SHA256[module]}, found {digest}"
            )
        if MODULE_MODE == "source" and digest == EXPECTED_MODULE_SHA256[module]:
            raise InputError(f"{module}: source mode received the pinned stock binary")
        vermagics[module] = modinfo_field(path, module, "vermagic", required=True)
        signature = {
            field: modinfo_field(path, module, field)
            for field in ("sig_id", "signer", "sig_key", "sig_hashalgo")
        }
        signature["signed"] = any(signature.values())
        signatures[module] = signature
        module_imports = parse_modversions(
            run_readonly([MODPROBE, "--dump-modversions", os.fspath(path)],
                         f"read imports from {module}"), module,
        )
        imports.extend(module_imports)
        undefined_count, version_count = (0, len(module_imports))
        if MODULE_MODE == "source":
            undefined_count, version_count = validate_source_imports(path, module, module_imports)
        MODULE_METADATA[module] = {
            "sha256": digest, "bytes": size,
            "path": SOURCE_MODULE_PATHS[module] if MODULE_DIR is None else os.fspath(path),
            "undefined": undefined_count, "versioned": version_count,
        }
        if MODULE_MODE == "source":
            MODULE_METADATA[module].update(installed_module_metadata(path, module))
        export_counts, crc_values = parse_nm(
            run_readonly([NM, "--defined-only", os.fspath(path)],
                         f"read exports from {module}"), module,
        )
        exports[module] = export_counts
        export_crcs[module] = crc_values

    pair_consumers = collections.defaultdict(set)
    for symbol, crc, consumer in imports:
        pair_consumers[(symbol, crc)].add(consumer)
    pairs = sorted(pair_consumers)
    inter, builtin = [], []
    for symbol, crc in pairs:
        providers = tuple(module for module in MODULES if exports[module].get(symbol, 0))
        record = {
            "symbol": symbol, "crc": crc,
            "consumers": tuple(sorted(pair_consumers[(symbol, crc)])), "providers": providers,
        }
        (inter if providers else builtin).append(record)
    return pairs, builtin, inter, exports, export_crcs, vermagics, signatures, module_sha256


def collect_flat_module_paths():
    if not MODULE_DIR.is_dir() or MODULE_DIR.is_symlink():
        raise InputError(f"{MODULE_MODE} module directory is missing: {MODULE_DIR}")
    try:
        module_names = sorted(path.name for path in MODULE_DIR.iterdir())
    except OSError as error:
        raise InputError(f"cannot enumerate {MODULE_MODE} module directory {MODULE_DIR}: {error}") from error
    if module_names != sorted(MODULES):
        raise InputError(
            f"{MODULE_MODE} module directory must contain exactly: "
            + ",".join(sorted(MODULES))
        )

    MODULE_INPUTS.update((module, MODULE_DIR / module) for module in MODULES)


def verify_inventory(pairs, builtin, inter, exports, export_crcs, vermagics, signatures):
    invariant_errors = []
    if MODULE_MODE == "stock" and len(pairs) != EXPECTED_PAIR_COUNT:
        invariant_errors.append(
            f"expected {EXPECTED_PAIR_COUNT} distinct imported pairs, found {len(pairs)}"
        )
    if MODULE_MODE == "stock" and len(builtin) != EXPECTED_BUILTIN_COUNT:
        invariant_errors.append(
            f"expected {EXPECTED_BUILTIN_COUNT} built-in pairs, found {len(builtin)}"
        )
    if MODULE_MODE == "stock" and len(inter) != EXPECTED_INTER_COUNT:
        invariant_errors.append(
            f"expected {EXPECTED_INTER_COUNT} inter-module pairs, found {len(inter)}"
        )

    crcs_by_symbol = collections.defaultdict(set)
    for symbol, crc in pairs:
        crcs_by_symbol[symbol].add(crc)
    conflicts = sorted(symbol for symbol, crcs in crcs_by_symbol.items() if len(crcs) != 1)
    if conflicts:
        invariant_errors.append(
            f"{MODULE_MODE} consumers require conflicting CRCs for: " + ",".join(conflicts)
        )

    module_layout = sorted(crcs_by_symbol.get("module_layout", ()))
    if len(module_layout) != 1 or (MODULE_MODE == "stock" and module_layout != [EXPECTED_MODULE_LAYOUT]):
        rendered = ",".join(module_layout) if module_layout else "<missing>"
        expected = EXPECTED_MODULE_LAYOUT if MODULE_MODE == "stock" else "one consistent CRC"
        invariant_errors.append(f"module_layout must be {expected}, found {rendered}")

    distinct_vermagics = sorted(set(vermagics.values()))
    if len(distinct_vermagics) != 1:
        invariant_errors.append(
            f"{MODULE_MODE} modules do not share one vermagic: "
            + "; ".join(
                f"{module}={vermagics[module]!r}" for module in MODULES
            )
        )
    stock_vermagic = distinct_vermagics[0] if len(distinct_vermagics) == 1 else "<conflict>"
    if MODULE_MODE == "stock" and stock_vermagic != EXPECTED_STOCK_VERMAGIC:
        invariant_errors.append(
            "stock vermagic authority changed: expected "
            f"{EXPECTED_STOCK_VERMAGIC!r}, found {stock_vermagic!r}"
        )

    signed_states = {signatures[module]["signed"] for module in MODULES}
    if len(signed_states) != 1:
        stock_signature = "mixed"
    elif signed_states == {False}:
        stock_signature = "unsigned"
    else:
        stock_signature = "signed"

    rows = []
    counts = collections.Counter()
    for record in sorted(inter, key=lambda item: (item["symbol"], item["crc"])):
        symbol = record["symbol"]
        expected_crc = record["crc"]
        providers = record["providers"]
        problems = []
        actual = []

        if len(providers) != 1:
            problems.append("provider_duplicate")
            counts["duplicate"] += 1

        for provider in providers:
            export_count = exports[provider][symbol]
            crcs = export_crcs[provider].get(symbol, [])
            if export_count != 1 or len(crcs) > 1:
                if "provider_duplicate" not in problems:
                    problems.append("provider_duplicate")
                    counts["duplicate"] += 1
            if not crcs:
                problems.append("provider_crc_missing")
                counts["missing_crc"] += 1
                actual.append(f"<missing>@{provider}")
                continue
            for actual_crc in crcs:
                actual.append(f"{actual_crc}@{provider}")
            if any(actual_crc != expected_crc for actual_crc in crcs):
                problems.append("provider_crc_mismatch")
                counts["crc_mismatch"] += 1

        status = ",".join(dict.fromkeys(problems)) if problems else "ok"
        if not problems:
            counts["ok"] += 1
        rows.append(
            (
                f"{MODULE_MODE}-inter",
                status,
                symbol,
                expected_crc,
                f"one-{MODULE_MODE}-module",
                ",".join(sorted(actual)) if actual else "<missing>",
            )
        )

    return invariant_errors, counts, rows, stock_vermagic, stock_signature


def collect_source_exports(exports, export_crcs):
    records, errors = [], []
    for symbol in sorted(set().union(*(set(value) for value in exports.values()))):
        providers = tuple(module for module in MODULES if exports[module].get(symbol))
        crcs = [crc for module in providers for crc in export_crcs[module].get(symbol, [])]
        if (len(providers) != 1 or any(exports[module][symbol] != 1 for module in providers)
                or len(crcs) != 1):
            errors.append(f"source export {symbol} requires exactly one module provider and CRC")
        records.append({"symbol": symbol, "crc": crcs[0] if crcs else "<missing>",
                        "providers": providers})
    return records, errors


def print_module_inventory(invariant_errors, vermagic, signature):
    print(f"module_mode={MODULE_MODE}")
    print(f"module_invariant_errors={len(invariant_errors)}")
    print(f"module_vermagic={vermagic}")
    print(f"module_signature={signature}")
    print(f"undefined_symbols={sum(item['undefined'] for item in MODULE_METADATA.values())}")
    print(f"versioned_imports={sum(item['versioned'] for item in MODULE_METADATA.values())}")
    for module in MODULES:
        for field in ("path", "sha256", "bytes", "installed_sha256", "installed_bytes"):
            if field in MODULE_METADATA[module]:
                print(f"module_{field}.{module}={MODULE_METADATA[module][field]}")
    if MODULE_MODE == "source":
        print("module_install=strip-debug")
        print(f"module_strip_tool_sha256={file_sha256_and_size(pathlib.Path(STRIP), 'strip tool')[0]}")
    if MODULE_MODE == "stock":
        print(f"stock_invariant_errors={len(invariant_errors)}")
        print(f"stock_vermagic_expected={EXPECTED_STOCK_VERMAGIC}")
        print(f"stock_vermagic={vermagic}")
        print(f"stock_module_signature={signature}")
        for module in MODULES:
            print(f"stock_module_sha256.{module}={MODULE_METADATA[module]['sha256']}")


def verify_source_contract(path):
    """Validate shared receipt fields; artifact/source provenance stays with its owner."""
    path = pathlib.Path(path)
    if not path.is_file() or path.is_symlink():
        raise InputError(f"source-module contract is not an ordinary file: {path}")
    values = {}
    for line in read_text(path, "source-module contract").splitlines():
        if not line.strip():
            continue
        if "=" not in line:
            raise InputError("source-module contract has a malformed field")
        key, value = line.split("=", 1)
        if key in values or not value or any(ord(c) < 32 or ord(c) > 126 for c in value):
            raise InputError(f"source-module contract has duplicate or unsafe field {key}")
        values[key] = value

    def field(key):
        key = "kernel." + key
        if key not in values:
            raise InputError(f"source-module contract lacks {key}")
        return values[key]

    def number(key):
        value = field(key)
        if not re.fullmatch(r"0|[1-9][0-9]{0,8}", value):
            raise InputError(f"source-module contract has invalid count kernel.{key}")
        return int(value)

    for key, expected in {
        "module_mode": "source", "module_install": "strip-debug",
        "modules": "5", "abi.status": "PASS",
        "abi.metadata_errors": "0", "module_invariant_errors": "0",
        "abi.module_signature_compatible": "yes",
    }.items():
        if field(key) != expected:
            raise InputError(f"source-module contract has invalid kernel.{key}")
    if not re.fullmatch(r"[0-9a-f]{64}", field("module_strip_tool_sha256")):
        raise InputError("source-module contract has no strip tool identity")
    if field("module_signature") not in ("unsigned", "signed", "mixed"):
        raise InputError("source-module contract has invalid module signature state")
    counts = {key: number(key) for key in (
        "expected_pairs", "builtin_expected", "inter_module_expected", "module_inter_ok",
        "candidate_builtin_ok", "candidate_inter_ok", "module_exports",
        "candidate_exports_ok", "undefined_symbols", "versioned_imports",
    )}
    if (counts["builtin_expected"] <= 0 or counts["inter_module_expected"] <= 0
            or counts["expected_pairs"] != counts["builtin_expected"] + counts["inter_module_expected"]
            or counts["module_inter_ok"] != counts["inter_module_expected"]
            or counts["candidate_inter_ok"] != counts["inter_module_expected"]
            or counts["candidate_builtin_ok"] != counts["builtin_expected"]
            or counts["module_exports"] < counts["inter_module_expected"]
            or counts["candidate_exports_ok"] != counts["module_exports"]
            or counts["versioned_imports"] != counts["undefined_symbols"] + len(MODULES)
            or counts["expected_pairs"] > counts["versioned_imports"]):
        raise InputError("source-module contract counts do not describe a complete ABI inventory")
    layout = field("module_layout")
    if (not re.fullmatch(r"[0-9a-f]{8}@vmlinux", layout)
            or field("module_layout_vmlinux") != layout.split("@", 1)[0] + "@__crc_module_layout"):
        raise InputError("source-module contract has inconsistent module_layout CRCs")
    for module, relative in SOURCE_MODULE_PATHS.items():
        key = "module." + module.removesuffix(".ko")
        digest = field(key + ".sha256")
        if (field(key + ".path") != relative or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or not re.fullmatch(r"[0-9a-f]{64}", field(key + ".installed_sha256"))
                or digest == EXPECTED_MODULE_SHA256[module] or number(key + ".bytes") <= 0
                or number(key + ".installed_bytes") <= 0):
            raise InputError(f"source-module contract has invalid artifact identity for {module}")
        if INSTALLED_DIR:
            directory = pathlib.Path(INSTALLED_DIR)
            installed = directory / module
            if not directory.is_dir() or directory.is_symlink() or not installed.is_file() or installed.is_symlink():
                raise InputError(f"installed source module is missing or symlinked: {installed}")
            actual = file_sha256_and_size(installed, f"installed source module {module}")
            expected = field(key + ".installed_sha256"), number(key + ".installed_bytes")
            if actual != expected:
                raise InputError(f"installed {module} differs from receipt-bound strip-debug output")


def normalize_provider(provider):
    normalized = provider.strip().replace("\\", "/").rstrip("/")
    return normalized.rsplit("/", 1)[-1] if normalized else normalized


def require_candidate_output(output):
    if output is None or not output.is_dir() or output.is_symlink():
        raise InputError(f"candidate build output is missing or symlinked: {output}")
    paths = {
        "dot_config": output / ".config",
        "auto_conf": output / "include/config/auto.conf",
        "kernel_release": output / "include/config/kernel.release",
        "autoconf_h": output / "include/generated/autoconf.h",
        "utsrelease_h": output / "include/generated/utsrelease.h",
        "vmlinux": output / "vmlinux",
        "symvers": output / "Module.symvers",
        "image": output / "arch/arm64/boot/Image",
        "image_gz": output / "arch/arm64/boot/Image.gz",
    }
    for label, path in paths.items():
        if not path.is_file() or path.is_symlink():
            raise InputError(
                f"candidate build output lacks ordinary {label}: {path}"
            )
    return paths


def read_text(path, context):
    try:
        return path.read_text(encoding="utf-8", errors="strict")
    except (OSError, UnicodeError) as error:
        raise InputError(f"{context}: cannot read {path}: {error}") from error


def parse_dot_config(path):
    values = {}
    present = set()
    enabled_pattern = re.compile(r"^(CONFIG_[A-Z0-9_]+)=(.*)$")
    disabled_pattern = re.compile(r"^# (CONFIG_[A-Z0-9_]+) is not set$")
    for line_number, line in enumerate(read_text(path, "candidate .config").splitlines(), 1):
        enabled = enabled_pattern.fullmatch(line)
        disabled = disabled_pattern.fullmatch(line)
        if enabled and enabled.group(1) in CONFIG_KEYS:
            key, value = enabled.groups()
        elif disabled and disabled.group(1) in CONFIG_KEYS:
            key, value = disabled.group(1), "n"
        else:
            continue
        if key in present:
            raise InputError(f"{path}: duplicate {key} at line {line_number}")
        allowed = ("y", "m", "n") if key == "CONFIG_MTK_CONNECTIVITY_SOURCE" else ("y", "n")
        if value not in allowed:
            raise InputError(f"{path}: {key} has invalid value {value!r}")
        present.add(key)
        values[key] = value
    for required in ("CONFIG_MODULES", "CONFIG_MODVERSIONS"):
        if required not in present:
            raise InputError(f"{path}: no explicit {required} result")
    for key in CONFIG_KEYS:
        values.setdefault(key, "n")
    return values


def parse_auto_conf(path):
    values = {}
    pattern = re.compile(r"^(CONFIG_[A-Z0-9_]+)=(.*)$")
    for line_number, line in enumerate(read_text(path, "candidate auto.conf").splitlines(), 1):
        match = pattern.fullmatch(line)
        if not match or match.group(1) not in CONFIG_KEYS:
            continue
        key, value = match.groups()
        if key in values:
            raise InputError(f"{path}: duplicate {key} at line {line_number}")
        allowed = ("y", "m") if key == "CONFIG_MTK_CONNECTIVITY_SOURCE" else ("y",)
        if value not in allowed:
            raise InputError(f"{path}: enabled {key} has invalid value {value!r}")
        values[key] = value
    return values


def parse_autoconf_h(path):
    values = {}
    pattern = re.compile(r"^#define (CONFIG_[A-Z0-9_]+) 1$")
    for line_number, line in enumerate(read_text(path, "candidate autoconf.h").splitlines(), 1):
        match = pattern.fullmatch(line)
        if not match:
            continue
        key, value = match.group(1), "y"
        if key == "CONFIG_MTK_CONNECTIVITY_SOURCE_MODULE":
            key, value = "CONFIG_MTK_CONNECTIVITY_SOURCE", "m"
        if key not in CONFIG_KEYS:
            continue
        if key in values:
            raise InputError(f"{path}: duplicate {key} at line {line_number}")
        values[key] = value
    return values


def validate_generated_config(paths):
    dot_config = parse_dot_config(paths["dot_config"])
    auto_conf = parse_auto_conf(paths["auto_conf"])
    autoconf_h = parse_autoconf_h(paths["autoconf_h"])
    for key in CONFIG_KEYS:
        expected = dot_config[key]
        auto_value = auto_conf.get(key, "n")
        header_value = autoconf_h.get(key, "n")
        if auto_value != expected or header_value != expected:
            raise InputError(
                f"candidate generated config disagrees for {key}: "
                f".config={dot_config[key]}, auto.conf="
                f"{auto_value}, autoconf.h={header_value}"
            )
    return dot_config


def parse_uts_release(path):
    matches = re.findall(
        r'^#define UTS_RELEASE "([^"\\\n]+)"$',
        read_text(path, "candidate utsrelease.h"),
        flags=re.MULTILINE,
    )
    if len(matches) != 1:
        raise InputError(f"{path}: expected exactly one simple UTS_RELEASE define")
    return matches[0]


def parse_kernel_release(path):
    lines = read_text(path, "candidate kernel.release").splitlines()
    if len(lines) != 1 or not lines[0] or not re.fullmatch(r"[!-~]+", lines[0]):
        raise InputError(f"{path}: expected one printable kernel release")
    return lines[0]


def read_exact(handle, offset, size, context):
    try:
        handle.seek(offset)
        data = handle.read(size)
    except OSError as error:
        raise InputError(f"{context}: cannot read ELF data: {error}") from error
    if len(data) != size:
        raise InputError(f"{context}: truncated ELF data")
    return data


def unpack_exact(fmt, data, context):
    try:
        return struct.unpack(fmt, data)
    except struct.error as error:
        raise InputError(f"{context}: malformed ELF structure: {error}") from error


def extract_vmlinux_vermagic(path):
    """Read the kernel/module.c vermagic object from this exact ELF vmlinux."""
    try:
        handle = path.open("rb")
    except OSError as error:
        raise InputError(f"candidate vmlinux cannot be opened: {path}: {error}") from error

    with handle:
        ident = read_exact(handle, 0, 16, f"{path}")
        if ident[:4] != b"\x7fELF":
            raise InputError(f"candidate vmlinux is not ELF: {path}")
        elf_class = ident[4]
        data_encoding = ident[5]
        if elf_class not in (1, 2) or data_encoding not in (1, 2):
            raise InputError(f"candidate vmlinux has unsupported ELF class/data encoding")
        endian = "<" if data_encoding == 1 else ">"

        if elf_class == 2:
            header_fmt = endian + "HHIQQQIHHHHHH"
            section_fmt = endian + "IIQQQQIIQQ"
            symbol_fmt = endian + "IBBHQQ"
        else:
            header_fmt = endian + "HHIIIIIHHHHHH"
            section_fmt = endian + "IIIIIIIIII"
            symbol_fmt = endian + "IIIBBH"
        header_size = struct.calcsize(header_fmt)
        header = unpack_exact(
            header_fmt,
            read_exact(handle, 16, header_size, f"{path}"),
            f"{path}",
        )
        section_offset = header[5]
        section_entry_size = header[10]
        section_count = header[11]
        expected_section_size = struct.calcsize(section_fmt)
        if section_count == 0 or section_entry_size < expected_section_size:
            raise InputError(f"candidate vmlinux has no ordinary section table")

        sections = []
        for index in range(section_count):
            raw = read_exact(
                handle,
                section_offset + index * section_entry_size,
                expected_section_size,
                f"{path}: section {index}",
            )
            fields = unpack_exact(section_fmt, raw, f"{path}: section {index}")
            sections.append(
                {
                    "type": fields[1],
                    "address": fields[3],
                    "offset": fields[4],
                    "size": fields[5],
                    "link": fields[6],
                    "entry_size": fields[9],
                }
            )

        symbol_size = struct.calcsize(symbol_fmt)
        found = []
        for section_index, symbol_section in enumerate(sections):
            if symbol_section["type"] != 2:  # SHT_SYMTAB
                continue
            entry_size = symbol_section["entry_size"]
            if entry_size < symbol_size or symbol_section["size"] % entry_size:
                raise InputError(f"{path}: malformed symbol table section {section_index}")
            string_index = symbol_section["link"]
            if string_index >= len(sections):
                raise InputError(f"{path}: symbol table has invalid string-table link")
            string_section = sections[string_index]
            strings = read_exact(
                handle,
                string_section["offset"],
                string_section["size"],
                f"{path}: symbol string table",
            )
            entries = symbol_section["size"] // entry_size
            for index in range(entries):
                raw = read_exact(
                    handle,
                    symbol_section["offset"] + index * entry_size,
                    symbol_size,
                    f"{path}: symbol {index}",
                )
                fields = unpack_exact(symbol_fmt, raw, f"{path}: symbol {index}")
                if elf_class == 2:
                    name_offset, info, _other, target_section, value, size = fields
                else:
                    name_offset, value, size, info, _other, target_section = fields
                if name_offset >= len(strings):
                    raise InputError(f"{path}: symbol {index} has invalid name offset")
                name_end = strings.find(b"\0", name_offset)
                if name_end < 0:
                    raise InputError(f"{path}: unterminated symbol name")
                if strings[name_offset:name_end] != b"vermagic":
                    continue
                if (info & 0x0F) != 1 or size < 2:  # STT_OBJECT, including NUL
                    raise InputError(f"{path}: vermagic is not a sized ELF object")
                if target_section == 0 or target_section >= len(sections):
                    raise InputError(f"{path}: vermagic has invalid target section")
                payload_section = sections[target_section]
                if payload_section["type"] == 8:  # SHT_NOBITS
                    raise InputError(f"{path}: vermagic unexpectedly resides in NOBITS")
                relative = value - payload_section["address"]
                if relative < 0 or relative + size > payload_section["size"]:
                    raise InputError(f"{path}: vermagic lies outside its ELF section")
                payload = read_exact(
                    handle,
                    payload_section["offset"] + relative,
                    size,
                    f"{path}: vermagic payload",
                )
                if payload[-1:] != b"\0" or b"\0" in payload[:-1]:
                    raise InputError(f"{path}: vermagic is not one NUL-terminated string")
                try:
                    found.append(payload[:-1].decode("ascii", errors="strict"))
                except UnicodeError as error:
                    raise InputError(f"{path}: vermagic is not ASCII: {error}") from error

        if len(found) != 1:
            raise InputError(
                f"{path}: expected exactly one ELF vermagic object, found {len(found)}"
            )
        return found[0]


def file_sha256_and_size(path, context, *, allow_empty=False):
    digest = hashlib.sha256()
    size = 0
    try:
        with path.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                digest.update(chunk)
                size += len(chunk)
    except OSError as error:
        raise InputError(f"{context}: cannot hash {path}: {error}") from error
    if size == 0 and not allow_empty:
        raise InputError(f"{context}: {path} is empty")
    return digest.hexdigest(), size


def streams_equal(first, second):
    while True:
        left = first.read(1024 * 1024)
        right = second.read(1024 * 1024)
        if left != right:
            return False
        if not left:
            return True


def validate_kernel_images(paths):
    """Bind boot Image and Image.gz to this exact candidate vmlinux."""
    vmlinux_sha, vmlinux_size = file_sha256_and_size(
        paths["vmlinux"], "candidate vmlinux"
    )
    with tempfile.TemporaryDirectory(prefix="k50-kernel-image-derive.") as temporary:
        derived = pathlib.Path(temporary) / "Image"
        run_readonly(
            [
                OBJCOPY,
                "-O", "binary",
                "-R", ".note",
                "-R", ".note.gnu.build-id",
                "-R", ".comment",
                "-S",
                os.fspath(paths["vmlinux"]),
                os.fspath(derived),
            ],
            "derive candidate Image from vmlinux",
        )
        derived_sha, derived_size = file_sha256_and_size(
            derived, "derived candidate Image"
        )
        image_sha, image_size = file_sha256_and_size(
            paths["image"], "candidate Image"
        )
        if image_sha != derived_sha or image_size != derived_size:
            raise InputError(
                "candidate Image is not the deterministic objcopy output of its vmlinux"
            )

    try:
        with gzip.open(paths["image_gz"], "rb") as compressed, \
             paths["image"].open("rb") as image:
            if not streams_equal(compressed, image):
                raise InputError(
                    "candidate Image.gz does not decompress exactly to candidate Image"
                )
    except InputError:
        raise
    except (OSError, EOFError, gzip.BadGzipFile) as error:
        raise InputError(f"candidate Image.gz cannot be validated: {error}") from error

    image_gz_sha, image_gz_size = file_sha256_and_size(
        paths["image_gz"], "candidate Image.gz"
    )
    return {
        "vmlinux_sha256": vmlinux_sha,
        "vmlinux_bytes": vmlinux_size,
        "image_sha256": image_sha,
        "image_bytes": image_size,
        "image_gz_sha256": image_gz_sha,
        "image_gz_bytes": image_gz_size,
        "derived_image_sha256": derived_sha,
    }


def validate_candidate_metadata(paths, stock_vermagic, stock_signature):
    config = validate_generated_config(paths)
    uts_release = parse_uts_release(paths["utsrelease_h"])
    kernel_release = parse_kernel_release(paths["kernel_release"])
    if kernel_release != uts_release:
        raise InputError(
            "candidate kernel.release and generated UTS_RELEASE disagree: "
            f"{kernel_release!r} vs {uts_release!r}"
        )
    candidate_vermagic = extract_vmlinux_vermagic(paths["vmlinux"])
    if not candidate_vermagic.startswith(uts_release + " "):
        raise InputError(
            "candidate vmlinux vermagic and generated UTS_RELEASE disagree: "
            f"{candidate_vermagic!r} vs {uts_release!r}"
        )
    vermagic_tokens = candidate_vermagic.split()[1:]
    has_modversions_token = "modversions" in vermagic_tokens
    if has_modversions_token != (config["CONFIG_MODVERSIONS"] == "y"):
        raise InputError(
            "candidate vmlinux vermagic disagrees with CONFIG_MODVERSIONS: "
            f"vermagic={candidate_vermagic!r}, config={config['CONFIG_MODVERSIONS']}"
        )
    if config["CONFIG_MODULE_SIG_FORCE"] == "y" and config["CONFIG_MODULE_SIG"] != "y":
        raise InputError("candidate CONFIG_MODULE_SIG_FORCE=y without CONFIG_MODULE_SIG=y")
    if config["CONFIG_MODULE_SIG_ALL"] == "y" and config["CONFIG_MODULE_SIG"] != "y":
        raise InputError("candidate CONFIG_MODULE_SIG_ALL=y without CONFIG_MODULE_SIG=y")

    errors = []
    if (MODULE_MODE == "source" and MODULE_DIR is None
            and config["CONFIG_MTK_CONNECTIVITY_SOURCE"] != "m"):
        errors.append("native source-module build lacks CONFIG_MTK_CONNECTIVITY_SOURCE=m")
    if MODULE_MODE == "source" and config["CONFIG_MODULE_SIG_ALL"] == "y":
        errors.append("source installation projection does not support automatic module signing")
    if config["CONFIG_MODULES"] != "y":
        errors.append("candidate CONFIG_MODULES is not y")
    if config["CONFIG_MODVERSIONS"] != "y":
        errors.append("candidate CONFIG_MODVERSIONS is not y")
    # Deliberately compare the complete string. This 3.18 loader's
    # CONFIG_MODVERSIONS path can skip the first release token when a module has
    # CRCs, but this gate is the stricter exact build-metadata contract: it must
    # not normalize away a LOCALVERSION/setlocalversion difference.
    if candidate_vermagic != stock_vermagic:
        errors.append(
            f"candidate vermagic {candidate_vermagic!r} does not equal {MODULE_MODE} {stock_vermagic!r}"
        )

    signature_compatible = True
    if config["CONFIG_MODULE_SIG_FORCE"] == "y":
        signature_compatible = False
        if stock_signature in ("unsigned", "mixed"):
            errors.append(
                f"candidate CONFIG_MODULE_SIG_FORCE=y rejects one or more unsigned {MODULE_MODE} modules"
            )
        else:
            errors.append(
                "candidate CONFIG_MODULE_SIG_FORCE=y but this gate cannot prove "
                f"the vmlinux trusted key matches the {MODULE_MODE} module signing identity"
            )

    return config, uts_release, candidate_vermagic, signature_compatible, errors


def parse_module_symvers(path):
    if path is None or not path.is_file():
        raise InputError(f"candidate Module.symvers is missing: {path}")
    entries = collections.defaultdict(list)
    try:
        with path.open("r", encoding="utf-8", errors="strict", newline=None) as handle:
            for line_number, line in enumerate(handle, 1):
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                fields = stripped.split()
                if len(fields) < 3:
                    raise InputError(
                        f"{path}: malformed line {line_number}: expected at least 3 columns"
                    )
                crc = crc32(fields[0], f"{path}: line {line_number}")
                symbol = fields[1]
                raw_provider = fields[2]
                entries[symbol].append(
                    {
                        "crc": crc,
                        "provider": normalize_provider(raw_provider),
                        "raw_provider": raw_provider,
                        "line": line_number,
                    }
                )
    except UnicodeError as error:
        raise InputError(f"{path}: not a UTF-8 text Module.symvers: {error}") from error
    except OSError as error:
        raise InputError(f"could not read candidate Module.symvers {path}: {error}") from error
    return entries


def compare_builtins(builtin, entries, vmlinux_crcs, vmlinux_exports):
    rows = []
    counts = collections.Counter()
    expected_by_symbol = {}
    for record in builtin:
        symbol = record["symbol"]
        crc = record["crc"]
        if symbol in expected_by_symbol and expected_by_symbol[symbol] != crc:
            raise InputError(f"module inventory has conflicting built-in CRCs for {symbol}")
        expected_by_symbol[symbol] = crc

    for symbol in sorted(expected_by_symbol):
        expected_crc = expected_by_symbol[symbol]
        actual_entries = entries.get(symbol, [])
        vmlinux_entries = vmlinux_crcs.get(symbol, [])
        vmlinux_export_count = vmlinux_exports.get(symbol, 0)
        problems = []
        if not actual_entries:
            problems.append("missing")
            counts["missing"] += 1
        else:
            if len(actual_entries) != 1:
                problems.append("duplicate")
                counts["duplicate"] += 1
            if any(entry["provider"] != "vmlinux" for entry in actual_entries):
                problems.append("wrong_provider")
                counts["wrong_provider"] += 1
            if any(entry["crc"] != expected_crc for entry in actual_entries):
                problems.append("crc_mismatch")
                counts["crc_mismatch"] += 1

        if vmlinux_export_count == 0:
            problems.append("vmlinux_export_missing")
            counts["vmlinux_export_missing"] += 1
        elif vmlinux_export_count != 1:
            problems.append("vmlinux_export_duplicate")
            counts["vmlinux_export_duplicate"] += 1
        else:
            counts["vmlinux_export_ok"] += 1

        vmlinux_problems = False
        if not vmlinux_entries:
            problems.append("vmlinux_crc_missing")
            counts["vmlinux_crc_missing"] += 1
            vmlinux_problems = True
        else:
            if len(vmlinux_entries) != 1:
                problems.append("vmlinux_crc_duplicate")
                counts["vmlinux_crc_duplicate"] += 1
                vmlinux_problems = True
            if any(entry["crc"] != expected_crc for entry in vmlinux_entries):
                problems.append("vmlinux_crc_mismatch")
                counts["vmlinux_crc_mismatch"] += 1
                vmlinux_problems = True
        if not vmlinux_problems:
            counts["vmlinux_crc_ok"] += 1

        if not problems:
            counts["ok"] += 1
        rendered_symvers = sorted(
            f"{entry['crc']}@{entry['provider']}[line={entry['line']}]"
            for entry in actual_entries
        )
        rendered_vmlinux = sorted(
            f"{entry['crc']}@__crc_{symbol}[line={entry['line']}]"
            for entry in vmlinux_entries
        )
        rendered = (
            "symvers="
            + (",".join(rendered_symvers) if rendered_symvers else "<missing>")
            + ";vmlinux="
            + (",".join(rendered_vmlinux) if rendered_vmlinux else "<missing>")
            + f";ksymtab={vmlinux_export_count}"
        )
        rows.append(
            (
                "candidate-builtin",
                ",".join(problems) if problems else "ok",
                symbol,
                expected_crc,
                "vmlinux+__crc+__ksymtab",
                rendered,
            )
        )
    return counts, rows


def compare_candidate_inter(inter, entries, vmlinux_crcs, vmlinux_exports):
    """Bind source providers, or keep stock providers outside the candidate kernel."""
    rows = []
    counts = collections.Counter()
    for record in sorted(inter, key=lambda item: (item["symbol"], item["crc"])):
        symbol = record["symbol"]
        expected_crc = record["crc"]
        symvers_entries = entries.get(symbol, [])
        vmlinux_entries = vmlinux_crcs.get(symbol, [])
        vmlinux_export_count = vmlinux_exports.get(symbol, 0)
        problems = []
        if MODULE_MODE == "stock":
            if symvers_entries:
                problems.append("candidate_provider_collision")
                counts["symvers_collision"] += 1
        else:
            if not symvers_entries:
                problems.append("module_provider_missing")
                counts["missing"] += 1
            elif len(symvers_entries) != 1:
                problems.append("module_provider_duplicate")
                counts["duplicate"] += 1
            providers = {provider.removesuffix(".ko") for provider in record["providers"]}
            if any(entry["provider"].removesuffix(".ko") not in providers for entry in symvers_entries):
                problems.append("module_provider_wrong")
                counts["wrong_provider"] += 1
            if any(entry["crc"] != expected_crc for entry in symvers_entries):
                problems.append("module_provider_crc_mismatch")
                counts["crc_mismatch"] += 1
        if vmlinux_entries:
            problems.append("candidate_vmlinux_crc_collision")
            counts["vmlinux_crc_collision"] += 1
        if vmlinux_export_count:
            problems.append("candidate_vmlinux_export_collision")
            counts["vmlinux_export_collision"] += 1
        if not problems:
            counts["ok"] += 1

        rendered_symvers = sorted(
            f"{entry['crc']}@{entry['provider']}[line={entry['line']}]"
            for entry in symvers_entries
        )
        rendered_vmlinux = sorted(
            f"{entry['crc']}@__crc_{symbol}[line={entry['line']}]"
            for entry in vmlinux_entries
        )
        rendered = (
            "symvers="
            + (",".join(rendered_symvers) if rendered_symvers else "<absent>")
            + ";vmlinux="
            + (",".join(rendered_vmlinux) if rendered_vmlinux else "<absent>")
            + f";ksymtab={vmlinux_export_count}"
        )
        rows.append(
            (
                "candidate-inter",
                ",".join(problems) if problems else "ok",
                symbol,
                expected_crc,
                "stock-module-only" if MODULE_MODE == "stock" else "source-module+symvers",
                rendered,
            )
        )
    return counts, rows


def module_layout_actual(entries):
    records = entries.get("module_layout", [])
    if not records:
        return "<missing>"
    return ",".join(
        sorted(f"{record['crc']}@{record['provider']}" for record in records)
    )


def module_layout_vmlinux_actual(entries):
    records = entries.get("module_layout", [])
    if not records:
        return "<missing>"
    return ",".join(
        sorted(f"{record['crc']}@__crc_module_layout" for record in records)
    )


def render_report(rows):
    lines = ["scope\tstatus\tsymbol\texpected_crc\texpected_provider\tactual"]
    for row in sorted(rows, key=lambda item: (item[0], item[2], item[3])):
        lines.append("\t".join(row))
    return "\n".join(lines) + "\n"


def write_report(path, text):
    if path == "-":
        print("report_begin")
        sys.stdout.write(text)
        print("report_end")
        return
    target = pathlib.Path(path)
    protected = list(CANDIDATE_INPUTS) + list(MODULE_INPUTS.values())
    target_identity = target.resolve(strict=False)
    if any(
        protected_path is not None
        and target_identity == protected_path.resolve(strict=False)
        for protected_path in protected
    ):
        raise InputError(f"refusing to overwrite an ABI input with the report: {target}")
    parent = target.parent if os.fspath(target.parent) else pathlib.Path(".")
    if not parent.is_dir():
        raise InputError(f"report parent directory is missing: {parent}")
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=parent,
            prefix=f".{target.name}.",
            delete=False,
        ) as handle:
            temporary_name = handle.name
            handle.write(text)
        os.replace(temporary_name, target)
    except OSError as error:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
        raise InputError(f"could not write detailed report {target}: {error}") from error


try:
    if MODE == "contract":
        verify_source_contract(CONTRACT)
        print("contract_status=PASS")
        sys.exit(0)
    (
        pairs, builtin, inter, exports, export_crcs, vermagics, signatures,
        module_sha256,
    ) = (
        collect_module_inventory()
    )
    (
        invariant_errors,
        stock_counts,
        stock_rows,
        stock_vermagic,
        stock_signature,
    ) = verify_inventory(
        pairs, builtin, inter, exports, export_crcs, vermagics, signatures
    )

    source_exports, source_export_errors = (
        collect_source_exports(exports, export_crcs) if MODULE_MODE == "source" else ([], [])
    )
    invariant_errors.extend(source_export_errors)

    if MODE == "inventory":
        print(f"modules={len(MODULES)}")
        print(f"expected_pairs={len(pairs)}")
        print(f"built_in_providers={len(builtin)}")
        print(f"inter_module_providers={len(inter)}")
        layout = sorted(crc for symbol, crc in pairs if symbol == "module_layout")
        print(f"module_layout={','.join(layout) if layout else '<missing>'}")
        print_module_inventory(invariant_errors, stock_vermagic, stock_signature)
        for error in invariant_errors:
            print(f"inventory error: {error}", file=sys.stderr)
        if stock_counts["duplicate"]:
            print(
                f"inventory error: {stock_counts['duplicate']} duplicate inter-module providers",
                file=sys.stderr,
            )
        if stock_counts["missing_crc"]:
            print(
                f"inventory error: {stock_counts['missing_crc']} inter-module provider CRCs missing",
                file=sys.stderr,
            )
        if stock_counts["crc_mismatch"]:
            print(
                f"inventory error: {stock_counts['crc_mismatch']} inter-module CRC mismatches",
                file=sys.stderr,
            )
        sys.exit(
            1
            if invariant_errors
            or stock_counts["duplicate"]
            or stock_counts["missing_crc"]
            or stock_counts["crc_mismatch"]
            else 0
        )

    candidate_paths = require_candidate_output(CANDIDATE_OUTPUT)
    CANDIDATE_INPUTS.extend(candidate_paths.values())
    (
        candidate_config,
        candidate_uts_release,
        candidate_vermagic,
        signature_compatible,
        metadata_errors,
    ) = validate_candidate_metadata(
        candidate_paths, stock_vermagic, stock_signature
    )
    image_metadata = validate_kernel_images(candidate_paths)
    candidate_metadata_files = {}
    for label in (
        "dot_config", "auto_conf", "kernel_release", "autoconf_h",
        "utsrelease_h", "symvers",
    ):
        digest, size = file_sha256_and_size(
            candidate_paths[label], f"candidate {label}", allow_empty=True
        )
        candidate_metadata_files[label] = {"sha256": digest, "bytes": size}
    candidate_entries = parse_module_symvers(candidate_paths["symvers"])
    candidate_vmlinux_nm = run_readonly(
        [NM, "--defined-only", os.fspath(candidate_paths["vmlinux"])],
        "read candidate exports and built-in CRCs from vmlinux",
    )
    candidate_vmlinux_crcs = parse_vmlinux_crcs(
        candidate_vmlinux_nm,
        candidate_paths["vmlinux"],
    )
    candidate_vmlinux_exports, _candidate_vmlinux_simple_crcs = parse_nm(
        candidate_vmlinux_nm, "candidate vmlinux"
    )
    candidate_counts, candidate_rows = compare_builtins(
        builtin, candidate_entries, candidate_vmlinux_crcs,
        candidate_vmlinux_exports,
    )
    candidate_inter_counts, candidate_inter_rows = compare_candidate_inter(
        inter, candidate_entries, candidate_vmlinux_crcs,
        candidate_vmlinux_exports,
    )
    source_export_counts, source_export_rows = compare_candidate_inter(
        source_exports, candidate_entries, candidate_vmlinux_crcs, candidate_vmlinux_exports,
    )
    source_export_rows = [("candidate-module-export", *row[1:]) for row in source_export_rows]
    stock_failed = bool(
        invariant_errors
        or stock_counts["duplicate"]
        or stock_counts["missing_crc"]
        or stock_counts["crc_mismatch"]
    )
    candidate_builtin_failed = any(
        candidate_counts[name]
        for name in (
            "missing", "crc_mismatch", "wrong_provider", "duplicate",
            "vmlinux_export_missing", "vmlinux_export_duplicate",
            "vmlinux_crc_missing", "vmlinux_crc_mismatch", "vmlinux_crc_duplicate",
        )
    )
    candidate_inter_failed = any(
        candidate_inter_counts[name]
        for name in (
            "symvers_collision", "vmlinux_crc_collision", "vmlinux_export_collision",
            "missing", "duplicate", "wrong_provider", "crc_mismatch",
        )
    )
    failed = (
        stock_failed or candidate_builtin_failed or candidate_inter_failed
        or bool(metadata_errors) or source_export_counts["ok"] != len(source_exports)
    )
    for module, path in MODULE_INPUTS.items():
        if file_sha256_and_size(path, f"final {module}") != (
                MODULE_METADATA[module]["sha256"], MODULE_METADATA[module]["bytes"]):
            raise InputError(f"module changed during ABI validation: {module}")

    report_text = render_report(
        stock_rows + candidate_rows + candidate_inter_rows + source_export_rows
    ) if REPORT else ""
    if REPORT and REPORT != "-":
        write_report(REPORT, report_text)

    print(f"status={'FAIL' if failed else 'PASS'}")
    print(f"candidate_output={CANDIDATE_OUTPUT}")
    print(f"modules={len(MODULES)}")
    print(f"expected_pairs={len(pairs)}")
    print(f"built_in_expected={len(builtin)}")
    print(f"inter_module_expected={len(inter)}")
    print_module_inventory(invariant_errors, stock_vermagic, stock_signature)
    print(f"module_exports_expected={len(source_exports)}")
    print(f"candidate_module_exports_ok={source_export_counts['ok']}")
    print(f"candidate_uts_release={candidate_uts_release}")
    print(f"candidate_vermagic={candidate_vermagic}")
    print(f"candidate_config_modules={candidate_config['CONFIG_MODULES']}")
    print(f"candidate_config_modversions={candidate_config['CONFIG_MODVERSIONS']}")
    print(f"candidate_config_module_sig={candidate_config['CONFIG_MODULE_SIG']}")
    print(f"candidate_config_module_sig_force={candidate_config['CONFIG_MODULE_SIG_FORCE']}")
    print(f"candidate_config_module_sig_all={candidate_config['CONFIG_MODULE_SIG_ALL']}")
    print(f"module_signature_compatible={'yes' if signature_compatible else 'no'}")
    print(f"candidate_metadata_errors={len(metadata_errors)}")
    for label in (
        "dot_config", "auto_conf", "kernel_release", "autoconf_h",
        "utsrelease_h", "symvers",
    ):
        print(
            f"candidate_{label}_sha256="
            f"{candidate_metadata_files[label]['sha256']}"
        )
        print(f"candidate_{label}_bytes={candidate_metadata_files[label]['bytes']}")
    print(f"candidate_vmlinux_sha256={image_metadata['vmlinux_sha256']}")
    print(f"candidate_vmlinux_bytes={image_metadata['vmlinux_bytes']}")
    print(f"candidate_image_path=arch/arm64/boot/Image")
    print(f"candidate_image_sha256={image_metadata['image_sha256']}")
    print(f"candidate_image_bytes={image_metadata['image_bytes']}")
    print(f"candidate_image_derived_sha256={image_metadata['derived_image_sha256']}")
    print(f"candidate_image_gz_path=arch/arm64/boot/Image.gz")
    print(f"candidate_image_gz_sha256={image_metadata['image_gz_sha256']}")
    print(f"candidate_image_gz_bytes={image_metadata['image_gz_bytes']}")
    for prefix in (("module", "stock") if MODULE_MODE == "stock" else ("module",)):
        for field in ("ok", "missing_crc", "crc_mismatch", "duplicate"):
            print(f"{prefix}_inter_{field}={stock_counts[field]}")
    print(f"candidate_builtin_ok={candidate_counts['ok']}")
    print(f"candidate_missing={candidate_counts['missing']}")
    print(f"candidate_crc_mismatch={candidate_counts['crc_mismatch']}")
    print(f"candidate_wrong_provider={candidate_counts['wrong_provider']}")
    print(f"candidate_duplicate={candidate_counts['duplicate']}")
    print(f"candidate_vmlinux_crc_ok={candidate_counts['vmlinux_crc_ok']}")
    print(f"candidate_vmlinux_crc_missing={candidate_counts['vmlinux_crc_missing']}")
    print(f"candidate_vmlinux_crc_mismatch={candidate_counts['vmlinux_crc_mismatch']}")
    print(f"candidate_vmlinux_crc_duplicate={candidate_counts['vmlinux_crc_duplicate']}")
    print(f"candidate_vmlinux_export_ok={candidate_counts['vmlinux_export_ok']}")
    print(
        "candidate_vmlinux_export_missing="
        f"{candidate_counts['vmlinux_export_missing']}"
    )
    print(
        "candidate_vmlinux_export_duplicate="
        f"{candidate_counts['vmlinux_export_duplicate']}"
    )
    print(f"candidate_inter_ok={candidate_inter_counts['ok']}")
    for field in ("missing", "duplicate", "wrong_provider", "crc_mismatch"):
        print(f"candidate_inter_{field}={candidate_inter_counts[field]}")
    print(
        "candidate_inter_symvers_collision="
        f"{candidate_inter_counts['symvers_collision']}"
    )
    print(
        "candidate_inter_vmlinux_crc_collision="
        f"{candidate_inter_counts['vmlinux_crc_collision']}"
    )
    print(
        "candidate_inter_vmlinux_export_collision="
        f"{candidate_inter_counts['vmlinux_export_collision']}"
    )
    layout_crcs = sorted(crc for symbol, crc in pairs if symbol == "module_layout")
    print(f"module_layout_expected={','.join(layout_crcs) if layout_crcs else '<missing>'}")
    print(f"module_layout_actual={module_layout_actual(candidate_entries)}")
    print(f"module_layout_vmlinux_actual={module_layout_vmlinux_actual(candidate_vmlinux_crcs)}")

    for error in invariant_errors:
        print(f"{MODULE_MODE} invariant error: {error}", file=sys.stderr)
    for error in metadata_errors:
        print(f"candidate metadata error: {error}", file=sys.stderr)
    if REPORT == "-":
        write_report(REPORT, report_text)
    sys.exit(1 if failed else 0)
except InputError as error:
    print(f"input error: {error}", file=sys.stderr)
    sys.exit(2)
PYTHON_EOF
