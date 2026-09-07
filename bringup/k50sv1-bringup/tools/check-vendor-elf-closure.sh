#!/usr/bin/env bash
#
# Vendor ELF closure gate for k50sv1_64_bsp.
#
# What this checks, in order:
#
#   Pass A  Every DT_NEEDED of every ELF under $PRODUCT_OUT/vendor resolves
#           through the *real* Android Q vendor linker namespace, modelled from
#           the generated system/etc/ld.config.29.txt rather than by indexing
#           partitions wholesale.
#   Pass B  Every GLOBAL undefined symbol of those ELFs is defined somewhere in
#           the transitive DT_NEEDED closure computed under that same model.
#   Pass C  Audited dlopen-by-name contracts, which DT_NEEDED cannot express.
#   Pass D  Config-driven contracts (audio_effects.xml, mtk_omx_core.cfg).
#   Pass E  The MTK MAL / voice-IMS entity contracts.
#
# Passes A and B are implemented in embedded Python: they need a memoised
# transitive closure over ~350 ELFs and a per-namespace resolver, which is not
# something to hand-roll in bash. Everything else stays shell.
#
# History: this file previously indexed system/, product/ and system_ext/
# wholesale and matched only basenames, so it reported a clean closure for
# libraries a vendor process cannot actually reach (anything under /system that
# is not LLNDK, and anything that only exists in a lib*/hw, lib*/egl or
# lib*/soundfx subdirectory). It also had no symbol-level pass, and its symbol
# helper used fixed awk columns, which STT_GNU_IFUNC's "<OS specific>: 10" and
# "name@@VERSION" both break. All four are fixed below.

set -euo pipefail

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TOOL_DIR}/../../.." && pwd)"
PRODUCT_OUT="${1:-${PROJECT_ROOT}/lineage-17.1/out/target/product/k50sv1_64_bsp}"

if [[ ! -d "${PRODUCT_OUT}/vendor" || ! -d "${PRODUCT_OUT}/system" ]]; then
    echo "Product output is incomplete: ${PRODUCT_OUT}" >&2
    exit 2
fi

LD_CONFIG="${PRODUCT_OUT}/system/etc/ld.config.29.txt"
if [[ ! -f "${LD_CONFIG}" ]]; then
    echo "Missing generated linker configuration: ${LD_CONFIG}" >&2
    exit 2
fi

status=0

###############################################################################
# Shared helpers
###############################################################################

# Does this ELF name the given library in a way that could reach dlopen?
#
# The old implementation was `grep -aFq "${library}"`, an unanchored substring
# match over the whole file: searching for libaal_key.so also matched
# libaal_keyring.so, and searching for gps.default.so matched agps.default.so.
# Split the file on NUL instead - ELF string-table entries are NUL-terminated -
# and require each candidate token to be exactly the library name or to end in
# "/" plus that name, so bare sonames and absolute dlopen paths both match but
# longer names never do.
elf_names_library() {
    local elf="$1" library="$2"

    LC_ALL=C tr '\0' '\n' <"${elf}" 2>/dev/null \
        | LC_ALL=C awk -v want="${library}" '
            found { next }
            $0 == want { found = 1; next }
            {
                i = index($0, "/" want)
                if (i > 0 && i + length(want) == length($0)) { found = 1 }
            }
            END { exit !found }
        '
}

# Is this symbol GLOBAL-or-WEAK and defined (not UND) in the ELF's .dynsym?
#
# The old implementation tested $5 == "GLOBAL" && $7 != "UND" && $8 == symbol.
# readelf renders STT_GNU_IFUNC as "<OS specific>: 10", which splits into three
# extra whitespace-separated fields and shifts every index after Type, so every
# ifunc (on this platform: memset, memcpy, strlen, memmove, strcmp, strcpy,
# strcat and the _chk variants) silently vanished from the defined set. It also
# compared against a raw field, so a versioned "name@@LIBC" never matched.
# Locate the Bind field by name instead of by index and strip the @VERSION.
elf_has_global_defined_symbol() {
    local elf="$1" symbol="$2"

    readelf --dyn-syms -W "${elf}" 2>/dev/null \
        | LC_ALL=C awk -v want="${symbol}" '
            found { next }
            {
                n = split($0, f)
                if (n < 7) next
                bind = 0
                for (i = 4; i <= n; i++) {
                    if (f[i] == "GLOBAL" || f[i] == "WEAK" || f[i] == "LOCAL") { bind = i; break }
                }
                if (bind == 0) next
                if (f[bind] == "LOCAL") next
                ndx = f[bind + 2]
                if (ndx == "UND") next
                if (n < bind + 3) next
                name = f[bind + 3]
                sub(/@.*$/, "", name)
                if (name == want) { found = 1 }
            }
            END { exit !found }
        '
}

elf_class_of() {
    readelf -h "$1" 2>/dev/null | awk -F: '/Class:/ { gsub(/ /, "", $2); print $2 }'
}

###############################################################################
# Pass A + Pass B: namespace-accurate basename and symbol closure
###############################################################################

echo "== Pass A/B: DT_NEEDED and symbol closure under the Q vendor namespace =="

if ! PRODUCT_OUT="${PRODUCT_OUT}" python3 - <<'PYTHON_EOF'
import os
import re
import subprocess
import sys
from collections import defaultdict

OUT = os.environ["PRODUCT_OUT"]
LD_CONFIG = os.path.join(OUT, "system/etc/ld.config.29.txt")

# --- parse the [vendor] section of the generated linker configuration --------
#
# This is the whole point of the rewrite. A vendor process gets:
#   namespace.default  - search paths /odm/${LIB} and /vendor/${LIB}, nothing else
#   -> system          - only the sonames in link.system.shared_libs  (LLNDK)
#   -> vndk            - only the sonames in link.vndk.shared_libs    (VNDK)
# Anything else under /system is unreachable no matter that the file exists.

text = open(LD_CONFIG).read()
if "[vendor]" not in text:
    sys.exit("ld.config.29.txt has no [vendor] section")
section = text.split("[vendor]", 1)[1]
end = re.search(r"\n\[[A-Za-z0-9_.:/-]+\]\s*\n", section)
if end:
    section = section[: end.start()]


def prop_list(name):
    """Collect a ':'-separated linker property, honouring '+=' continuation."""
    values = []
    for line in section.splitlines():
        line = line.strip()
        if not line.startswith(name):
            continue
        rest = line[len(name):].lstrip()
        if not rest.startswith("=") and not rest.startswith("+="):
            continue
        rest = rest.lstrip("+").lstrip("=").strip()
        values.extend(v.strip() for v in rest.split(":") if v.strip())
    return values


def search_paths(name, lib):
    return [p.replace("${LIB}", lib) for p in prop_list(name)]


LLNDK = set(prop_list("namespace.default.link.system.shared_libs"))
VNDK = set(prop_list("namespace.default.link.vndk.shared_libs"))
RUNTIME_LINK = set(prop_list("namespace.default.link.runtime.shared_libs"))

if not LLNDK or not VNDK:
    sys.exit("could not parse the vendor namespace link lists from ld.config.29.txt")

APEX_DIRS = ["system/apex/com.android.runtime.release",
             "system/apex/com.android.runtime.debug",
             "system/apex/com.android.runtime"]


def host(path):
    """Map an on-device absolute path to its host location under PRODUCT_OUT."""
    if path.startswith("/apex/com.android.runtime/"):
        tail = path[len("/apex/com.android.runtime/"):]
        for d in APEX_DIRS:
            cand = os.path.join(OUT, d, tail)
            if os.path.exists(cand):
                return cand
        return None
    cand = os.path.join(OUT, path.lstrip("/"))
    return cand if os.path.exists(cand) else None


def dir_index(paths, lib):
    """Basename -> host path, one directory level only (Bug 2).

    The old code used `find -type f`, which recursed, so hw/, egl/ and soundfx/
    contents were folded into the top-level search path and a bare DT_NEEDED
    naming an hw/-only library passed. The linker does not recurse.
    """
    index = {}
    for p in paths:
        hp = host(p)
        if not hp or not os.path.isdir(hp):
            continue
        for name in os.listdir(hp):
            full = os.path.join(hp, name)
            if os.path.islink(full) and not os.path.exists(full):
                # /system/${LIB}/lib{c,dl,m}.so are absolute symlinks into
                # /apex/com.android.runtime, which does not exist on the build
                # host. Follow them to the staged APEX so their symbols are not
                # silently dropped from the closure.
                target = os.readlink(full)
                if target.startswith("/"):
                    mapped = host(target)
                    if mapped:
                        index.setdefault(name, mapped)
                        continue
                continue
            if os.path.isfile(full):
                index.setdefault(name, full)
    return index


NS = {}
for bits, lib in ((32, "lib"), (64, "lib64")):
    NS[bits] = {
        "lib": lib,
        "default": dir_index(search_paths("namespace.default.search.paths", lib), lib),
        "vndk": dir_index(search_paths("namespace.vndk.search.paths", lib), lib),
        "system": dir_index(search_paths("namespace.system.search.paths", lib), lib),
    }
    # The runtime APEX is linked implicitly for bionic; libc/libdl/libm are
    # symlinks out of /system/${LIB} into it.
    apex = {}
    for d in APEX_DIRS:
        for sub in ("bionic", ""):
            hp = os.path.join(OUT, d, lib, sub)
            if os.path.isdir(hp):
                for name in os.listdir(hp):
                    apex.setdefault(name, os.path.join(hp, name))
    NS[bits]["apex"] = apex


def resolve(soname, bits, ns):
    """Resolve a soname within one linker namespace.

    Returns (host_path, why) where why is None on success and a human diagnosis
    on failure. `ns` is 'default' (a vendor process), 'system' or 'vndk';
    following a link into another namespace switches the rules, which is what
    keeps libEGL.so's private dependencies (libgraphicsenv, libnativebridge_lazy,
    libnativeloader_lazy) from being reported against the vendor blob that
    merely links libEGL.
    """
    n = NS[bits]

    if ns == "default":
        if soname in n["default"]:
            return n["default"][soname], None
        if soname in LLNDK or soname in RUNTIME_LINK:
            for table in ("system", "apex"):
                if soname in n[table]:
                    return n[table][soname], None
            return None, "listed as LLNDK but not built into system/%s" % n["lib"]
        if soname in VNDK:
            if soname in n["vndk"]:
                return n["vndk"][soname], None
            return None, "listed in the default->vndk link list but absent from the vndk search paths"
        if soname in n["apex"]:
            return n["apex"][soname], None
        return None, None  # caller produces the detailed diagnosis

    if ns == "system":
        for table in ("system", "apex"):
            if soname in n[table]:
                return n[table][soname], None
        return None, "absent from the system namespace"

    # vndk: namespace.vndk.link.default.allow_all_shared_libs = true, plus LLNDK
    for table in ("vndk", "default", "apex"):
        if soname in n[table]:
            return n[table][soname], None
    if soname in LLNDK and soname in n["system"]:
        return n["system"][soname], None
    return None, "absent from the vndk namespace"


def namespace_of(path, bits):
    n = NS[bits]
    rel = os.path.relpath(path, OUT)
    if rel.startswith("vendor/") or rel.startswith("odm/"):
        return "default"
    if "/vndk-29/" in "/" + rel or "/vndk-sp-29/" in "/" + rel:
        return "vndk"
    return "system"


def diagnose(soname, bits):
    """Explain precisely why a soname is unreachable - the two bug classes the
    previous script silently accepted get named explicitly."""
    n = NS[bits]
    lib = n["lib"]
    notes = []
    for sub in ("hw", "egl", "soundfx", "mediadrm", "mediacas"):
        for base in ("vendor", "odm"):
            if os.path.exists(os.path.join(OUT, base, lib, sub, soname)):
                notes.append("present in %s/%s/%s but that directory is NOT on "
                             "namespace.default.search.paths" % (base, lib, sub))
    if soname in n["system"] and soname not in LLNDK:
        notes.append("present in system/%s but NOT in namespace.default.link."
                     "system.shared_libs (LLNDK), so a vendor process cannot "
                     "link it" % lib)
    if soname in n["vndk"] and soname not in VNDK:
        notes.append("present in the vndk-29 tree but NOT in namespace.default."
                     "link.vndk.shared_libs")
    if not notes:
        notes.append("absent from every namespace reachable by a vendor process")
    return "; ".join(notes)


# --- readelf caches ----------------------------------------------------------

_needed = {}
_syms = {}
_unreadable = set()

SYM_BINDS = ("GLOBAL", "WEAK", "LOCAL")


def needed_of(path):
    if path in _needed:
        return _needed[path]
    out = subprocess.run(["readelf", "-d", path], capture_output=True,
                         text=True).stdout
    res = re.findall(r"Shared library: \[([^\]]+)\]", out)
    _needed[path] = res
    return res


def symbols_of(path):
    """(defined, undefined) GLOBAL/WEAK dynamic symbols.

    Parsed the same way as elf_has_global_defined_symbol in the shell above:
    locate the Bind column by name so STT_GNU_IFUNC's '<OS specific>: 10' cannot
    shift it, and strip @VERSION before comparing.
    """
    if path in _syms:
        return _syms[path]
    proc = subprocess.run(["readelf", "--dyn-syms", "-W", path],
                          capture_output=True, text=True)
    out = proc.stdout
    if proc.returncode != 0 or not out.strip():
        # A resolved dependency we cannot read would contribute an empty symbol
        # set and turn Pass B into a source of false failures (or, for a target
        # with no undefined symbols, false confidence). Surface it.
        _unreadable.add(path)
    defined, undef = set(), set()
    for line in out.splitlines():
        f = line.split()
        if len(f) < 7:
            continue
        bind = None
        for i in range(3, len(f)):
            if f[i] in SYM_BINDS:
                bind = i
                break
        if bind is None or f[bind] == "LOCAL":
            continue
        if len(f) < bind + 4:
            continue
        ndx = f[bind + 2]
        name = f[bind + 3].split("@")[0]
        if not name:
            continue
        if ndx == "UND":
            if f[bind] == "GLOBAL":
                undef.add(name)
        else:
            defined.add(name)
    _syms[path] = (defined, undef)
    return _syms[path]


# --- walk every ELF actually installed on the vendor partition ---------------

targets = []
for dirpath, _dirs, files in os.walk(os.path.join(OUT, "vendor")):
    for name in sorted(files):
        path = os.path.join(dirpath, name)
        if os.path.islink(path):
            continue
        try:
            with open(path, "rb") as fh:
                if fh.read(4) != b"\x7fELF":
                    continue
        except OSError:
            continue
        if name.endswith(".ko"):
            continue  # relocatable kernel objects have no dynamic section
        cls = subprocess.run(["readelf", "-h", path], capture_output=True,
                             text=True).stdout
        if "Class:" not in cls:
            continue
        bits = 64 if "ELF64" in cls.split("Class:")[1].split("\n")[0] else 32
        targets.append((os.path.relpath(path, OUT), path, bits))

unresolved = defaultdict(list)
sym_failures = []
closure_paths = {}   # root rel -> set of host paths pulled into its closure
closure_defs = {}    # root rel -> union of defined symbols over that closure
root_bits = {}

for rel, path, bits in targets:
    # ---- Pass A + transitive closure for Pass B ----
    provided = set(symbols_of(path)[0])
    undef = set(symbols_of(path)[1])
    reached = set()
    seen = set()
    stack = [(s, "default") for s in needed_of(path)]
    while stack:
        soname, ns = stack.pop()
        key = (soname, ns)
        if key in seen:
            continue
        seen.add(key)
        target, why = resolve(soname, bits, ns)
        if target is None:
            if ns == "default":
                unresolved[(soname, bits)].append((rel, why or diagnose(soname, bits)))
            continue
        reached.add(target)
        provided |= symbols_of(target)[0]
        nxt_ns = namespace_of(target, bits)
        for dep in needed_of(target):
            if (dep, nxt_ns) not in seen:
                stack.append((dep, nxt_ns))

    closure_paths[rel] = reached
    closure_defs[rel] = provided
    root_bits[rel] = bits

    missing = sorted(undef - provided)
    if missing:
        sym_failures.append((rel, bits, missing))

# A shared library is never loaded alone: the dynamic linker resolves its
# undefined symbols against the global scope of whatever loaded it, which is the
# executable plus that executable's whole DT_NEEDED closure. Checking a library
# in isolation therefore over-reports. Before failing one, look for a shipped
# ELF that pulls it in and can satisfy the remainder, and demote to a note if so
# - naming the provider, so the note still breaks if the provider goes away.
by_path = {rel: path for rel, path, _ in targets}
resolved_failures = []
real_failures = []
for rel, bits, missing in sym_failures:
    own_path = by_path[rel]
    provider = None
    for root, reached in closure_paths.items():
        if root == rel or root_bits[root] != bits or own_path not in reached:
            continue
        if not set(missing) - closure_defs[root]:
            provider = root
            break
    if provider:
        resolved_failures.append((rel, bits, missing, provider))
    else:
        real_failures.append((rel, bits, missing))
sym_failures = real_failures

print("   scanned %d vendor ELFs (%d LLNDK sonames, %d VNDK sonames linkable)"
      % (len(targets), len(LLNDK), len(VNDK)))

for rel, bits, missing, provider in sorted(resolved_failures):
    print("   note: %d-bit %s leaves %d symbol(s) to its loader's global scope; "
          "satisfied by %s (%s)"
          % (bits, rel, len(missing), provider, ", ".join(missing[:4])
             + ("..." if len(missing) > 4 else "")))

failed = False

if _unreadable:
    failed = True
    print("\n   RESOLVED BUT UNREADABLE (closure would be computed from an empty"
          " symbol set):")
    for path in sorted(_unreadable):
        print("     %s" % os.path.relpath(path, OUT))

if unresolved:
    failed = True
    print("\n   UNRESOLVED DT_NEEDED (%d sonames):" % len(unresolved))
    for (soname, bits), consumers in sorted(unresolved.items()):
        print("     %d-bit %s" % (bits, soname))
        print("       reason: %s" % consumers[0][1])
        for rel, _ in consumers[:12]:
            print("         <- %s" % rel)
        if len(consumers) > 12:
            print("         ... and %d more" % (len(consumers) - 12))

if sym_failures:
    failed = True
    print("\n   UNRESOLVED SYMBOLS (%d ELFs):" % len(sym_failures))
    for rel, bits, missing in sym_failures:
        print("     %d-bit %s (%d)" % (bits, rel, len(missing)))
        for s in missing[:20]:
            print("         %s" % s)
        if len(missing) > 20:
            print("         ... and %d more" % (len(missing) - 20))

if not failed:
    print("   Pass A/B clean.")
sys.exit(1 if failed else 0)
PYTHON_EOF
then
    status=1
fi

###############################################################################
# Pass C: audited dlopen-by-name contracts
###############################################################################
#
# DT_NEEDED does not describe libraries opened by filename at runtime. Keep a
# narrow list of audited, active MTK dlopen contracts so extraction regressions
# cannot silently remove them while the ordinary ELF closure still passes.
#
# Format: bits|consumer path relative to PRODUCT_OUT|library. A library
# containing '/' is a path relative to PRODUCT_OUT; otherwise it is resolved as
# vendor/lib{,64}/<library>.

echo
echo "== Pass C: audited dlopen-by-name contracts =="

runtime_loaded_libraries=(
    "32|vendor/lib/libcam_utils.so|libcam_platform.so"
    "32|vendor/lib/hw/vendor.mediatek.hardware.camera.ccap@1.0-impl.so|libccap.so"
    "32|vendor/lib/libccap.so|libacdk.so"
    "32|vendor/lib/libvcodecdrv.so|libpowerhalwrap_vendor.so"
    "32|vendor/lib/libpq_prot.so|libpq_cust.so"
    "32|vendor/lib/libvcodecdrv.so|libvp9dec_sa.ca7.so"
    "32|vendor/bin/volte_imcb|libaedv.so"
    "64|vendor/lib64/libaal_mtk.so|libaal_key.so"
    "64|vendor/lib64/hw/hwcomposer.mt6755.so|libmtkperf_client_vendor.so"
    "64|vendor/lib64/mtk-ril.so|libmal.so"

    # The device's own sensors filter shim dlopens the renamed Stock backend by
    # absolute path; nothing in DT_NEEDED or hw_get_module names it, so an
    # extraction regression here would silently disable every sensor.
    #
    # The filter is sensors.mt6755, not sensors.k50sv1_64_bsp. hw_get_module()
    # tries variant_keys in order -- ro.hardware, ro.product.board,
    # ro.board.platform, ro.arch (hardware/libhardware/hardware.c:59-65) -- and
    # ro.hardware is mt6755, so under the old name the filter was reached only
    # by the ro.product.board fallback, and only because extraction renames the
    # stock blob to sensors.mt6755.stock.so. Restoring that blob under its
    # original name would have silently bypassed the phantom-sensor filter;
    # under the new name it is a duplicate-install build failure instead.
    "64|vendor/lib64/hw/sensors.mt6755.so|vendor/lib64/hw/sensors.mt6755.stock.so"

    # audio.primary.mt6755.so resolves its tuning/codec back ends by name. It
    # also carries dead /system/lib/... paths for the first two; the _vendor
    # copies are the reachable ones under Treble.
    "32|vendor/lib/hw/audio.primary.mt6755.so|libaudiocompensationfilter_vendor.so"
    "32|vendor/lib/hw/audio.primary.mt6755.so|libaudiocomponentengine_vendor.so"
    "32|vendor/lib/hw/audio.primary.mt6755.so|libspeech_enh_lib.so"
    "32|vendor/lib/hw/audio.primary.mt6755.so|libbluetooth_mtk_pure.so"

    # The camera provider picks its device back end by name. Only the HAL1
    # library exists for 32-bit; libmtkcam_device3.so is 64-bit-only in Stock
    # and unreachable from the 32-bit camerahalserver.
    "32|vendor/lib/hw/android.hardware.camera.provider@2.4-impl-mediatek.so|libmtkcam_device1.so"

    "64|vendor/lib64/libpowerhal.so|libmtcloader.so"
    "64|vendor/lib64/libpq_prot.so|libpq_cust.so"
)

for contract in "${runtime_loaded_libraries[@]}"; do
    IFS='|' read -r bits consumer library <<<"${contract}"
    if [[ "${bits}" == 32 ]]; then
        libdir=lib
        elf_class=ELF32
    else
        libdir=lib64
        elf_class=ELF64
    fi

    consumer_path="${PRODUCT_OUT}/${consumer}"
    if [[ "${library}" == */* ]]; then
        library_path="${PRODUCT_OUT}/${library}"
        library_name="$(basename "${library}")"
    else
        library_path="${PRODUCT_OUT}/vendor/${libdir}/${library}"
        library_name="${library}"
    fi

    if [[ ! -f "${consumer_path}" ]]; then
        printf '   %s-bit runtime-load consumer missing: %s\n' "${bits}" "${consumer}"
        status=1
        continue
    fi
    if [[ "$(elf_class_of "${consumer_path}")" != "${elf_class}" ]]; then
        printf '   %s-bit runtime-load consumer has wrong ELF class: %s\n' \
            "${bits}" "${consumer}"
        status=1
    fi
    if ! elf_names_library "${consumer_path}" "${library_name}"; then
        printf '   %s-bit audited runtime-load contract no longer appears in %s: %s\n' \
            "${bits}" "${consumer}" "${library_name}"
        status=1
    fi
    if [[ ! -f "${library_path}" ]]; then
        printf '   %s-bit runtime-loaded library missing: %s <- %s\n' \
            "${bits}" "${library_path#${PRODUCT_OUT}/}" "${consumer}"
        status=1
        continue
    fi
    if [[ "$(elf_class_of "${library_path}")" != "${elf_class}" ]]; then
        printf '   %s-bit runtime-loaded library has wrong ELF class: %s\n' \
            "${bits}" "${library_path#${PRODUCT_OUT}/}"
        status=1
    fi
done

###############################################################################
# Pass D: config-driven load contracts
###############################################################################
#
# Two config files name libraries that the ELF graph never mentions. Neither is
# validated by the build, and a missing entry only shows up as a runtime log
# line, so assert them here.

echo
echo "== Pass D: config-driven load contracts =="

effects_xml="${PRODUCT_OUT}/vendor/etc/audio_effects.xml"
if [[ ! -f "${effects_xml}" ]]; then
    echo "   Audio effects configuration is missing: vendor/etc/audio_effects.xml"
    status=1
else
    # Strip XML comments first. The Stock file documents libeffectproxy.so,
    # lib_some_fx_sw.so and lib_some_fx_hw.so inside a comment block; a naive
    # grep demands three libraries that are deliberately not shipped.
    # `while ... done < <(python3 ...)` cannot fail. A process substitution's
    # exit status is invisible to the loop, and an empty stream is simply zero
    # iterations with ${status} untouched -- so a parser that threw, or a
    # <library> spelling this regex stopped matching, reported a clean pass on
    # zero libraries checked. Take the parser's status, then assert a floor.
    effect_library_list=""
    if ! effect_library_list="$(python3 - "${effects_xml}" <<'PYTHON_EOF'
import re
import sys

text = open(sys.argv[1]).read()
text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
for path in re.findall(r'<library\b[^>]*\bpath="([^"]+)"', text):
    print(path)
PYTHON_EOF
    )"; then
        echo "   audio_effects.xml <library> parser failed"
        status=1
    fi
    effect_libraries=()
    while IFS= read -r effect_library; do
        [[ -n "${effect_library}" ]] || continue
        effect_libraries+=("${effect_library}")
    done <<<"${effect_library_list}"
    # Seven, counted in both the shipped vendor copy and the factory image:
    # bundlewrapper, reverbwrapper, visualizer, downmix, ldnhncr, dynproc,
    # audiopreprocessing. A number below this is a parser or config regression,
    # not a shorter effect list -- raise it deliberately if one is removed.
    if [[ "${#effect_libraries[@]}" -lt 7 ]]; then
        printf '   audio_effects.xml yielded only %s effect libraries, expected at least 7\n' \
            "${#effect_libraries[@]}"
        status=1
    fi
    for effect_library in "${effect_libraries[@]}"; do
        for libdir in lib lib64; do
            if [[ ! -f "${PRODUCT_OUT}/vendor/${libdir}/soundfx/${effect_library}" ]]; then
                printf '   audio_effects.xml names a missing effect library: vendor/%s/soundfx/%s\n' \
                    "${libdir}" "${effect_library}"
                status=1
            fi
        done
    done
fi

omx_cfg="${PRODUCT_OUT}/vendor/etc/mtk_omx_core.cfg"
if [[ ! -f "${omx_cfg}" ]]; then
    echo "   MTK OMX core configuration is missing: vendor/etc/mtk_omx_core.cfg"
    status=1
else
    # The active codec service is 32-bit, so every component library named in
    # the third column must exist in vendor/lib.
    # Same invisible-status hole as the effects loop above.
    mapfile -t omx_libraries < <(
        awk '!/^[[:space:]]*(#|$)/ { print $3 }' "${omx_cfg}" | sort -u
    )
    # Three, counted in both the device configs/ copy and the factory image:
    # libMtkOmxMp3Dec.so, libMtkOmxVdecEx.so, libMtkOmxVenc.so.
    if [[ "${#omx_libraries[@]}" -lt 3 ]]; then
        printf '   mtk_omx_core.cfg yielded only %s component libraries, expected at least 3\n' \
            "${#omx_libraries[@]}"
        status=1
    fi
    for omx_library in "${omx_libraries[@]}"; do
        [[ -n "${omx_library}" ]] || continue
        if [[ ! -f "${PRODUCT_OUT}/vendor/lib/${omx_library}" ]]; then
            printf '   mtk_omx_core.cfg names a missing component library: vendor/lib/%s\n' \
                "${omx_library}"
            status=1
        fi
    done
fi

###############################################################################
# Pass E: MTK MAL, voice-IMS and ePDG entity contracts
###############################################################################

echo
echo "== Pass E: MAL / voice-IMS / ePDG contracts =="

# The 32-bit MAL launcher derives libmal_<entity>.so names at runtime instead
# of embedding every full filename in DT_NEEDED. The selected voice IMS stack
# needs the base seven entities below; the shipped VoWiFi path adds epdga.
# Four satisfy direct volte_imsm symbols, while mdmngr/rilproxy/rds preserve
# modem lifecycle, RIL transport and radio policy.
ims_mal_entities=(
    libmal_datamngr.so
    libmal_epdga.so
    libmal_imsmngr.so
    libmal_mdmngr.so
    libmal_nwmngr.so
    libmal_rds.so
    libmal_rilproxy.so
    libmal_simmngr.so
)

mtkmal_path="${PRODUCT_OUT}/vendor/bin/mtkmal"
if [[ ! -f "${mtkmal_path}" ]] || \
   [[ "$(elf_class_of "${mtkmal_path}")" != "ELF32" ]]; then
    echo "   32-bit IMS MAL launcher missing or has the wrong ELF class: vendor/bin/mtkmal"
    status=1
elif ! grep -aFq 'libmal_' "${mtkmal_path}" || \
     ! grep -aFq '%s_entity_init' "${mtkmal_path}"; then
    echo "   IMS MAL launcher's audited dynamic-entity contract is missing"
    status=1
fi

for library in "${ims_mal_entities[@]}"; do
    library_path="${PRODUCT_OUT}/vendor/lib/${library}"
    if [[ ! -f "${library_path}" ]]; then
        echo "   32-bit IMS MAL entity missing: vendor/lib/${library}"
        status=1
    elif [[ "$(elf_class_of "${library_path}")" != "ELF32" ]]; then
        echo "   IMS MAL entity has the wrong ELF class: vendor/lib/${library}"
        status=1
    else
        entity="${library#libmal_}"
        entity="${entity%.so}"
        for suffix in init exit; do
            if ! elf_has_global_defined_symbol \
                "${library_path}" "${entity}_entity_${suffix}"; then
                echo "   IMS MAL entity lacks ${entity}_entity_${suffix}: vendor/lib/${library}"
                status=1
            fi
        done
        if [[ "${entity}" != rds && "${entity}" != epdga ]] && \
           ! elf_has_global_defined_symbol \
                "${library_path}" "${entity}_entity_version"; then
            echo "   IMS MAL entity lacks ${entity}_entity_version: vendor/lib/${library}"
            status=1
        fi
    fi
done

imsmngr_path="${PRODUCT_OUT}/vendor/lib/libmal_imsmngr.so"
if [[ -f "${imsmngr_path}" ]] && \
   ! elf_names_library "${imsmngr_path}" volte_imsm.so; then
    echo "   MAL IMS manager no longer names the audited volte_imsm implementation"
    status=1
fi

# volte_imsm.so is what actually brings the three VoLTE services up, over
# ctl.start; no rc file in Stock or in this tree ever starts them directly.
volte_imsm_path="${PRODUCT_OUT}/vendor/lib/volte_imsm.so"
for symbol in \
    volte_imsm_main \
    volte_imsm_put_message \
    volte_imsm_set_callback; do
    if [[ ! -f "${volte_imsm_path}" ]] || \
       ! elf_has_global_defined_symbol "${volte_imsm_path}" "${symbol}"; then
        echo "   Voice IMS implementation lacks ${symbol}: vendor/lib/volte_imsm.so"
        status=1
    fi
done

if [[ -f "${volte_imsm_path}" ]]; then
    for svc in vendor.volte_imcb vendor.volte_stack; do
        if ! grep -aFq "${svc}" "${volte_imsm_path}"; then
            echo "   Voice IMS implementation no longer names the ${svc} ctl.start target"
            status=1
        fi
    done
fi

volte_stack_path="${PRODUCT_OUT}/vendor/bin/volte_stack"
android_net_path="${PRODUCT_OUT}/system/lib/libandroid_net.so"
if [[ ! -f "${volte_stack_path}" ]] || \
   ! elf_names_library "${volte_stack_path}" libandroid_net.so || \
   ! grep -aFq 'android_setsocknetwork' "${volte_stack_path}"; then
    echo "   VoLTE stack no longer contains its audited libandroid_net dlopen contract"
    status=1
elif grep -aFq '/system/lib/libandroid_net.so' "${volte_stack_path}" || \
     grep -aFq '/system/lib/libandroid.so' "${volte_stack_path}"; then
    echo "   VoLTE stack still uses a full-Treble-inaccessible absolute system dlopen path"
    status=1
elif [[ ! -f "${android_net_path}" ]] || \
     ! elf_has_global_defined_symbol \
        "${android_net_path}" android_setsocknetwork; then
    echo "   32-bit libandroid_net does not export android_setsocknetwork"
    status=1
# Not `grep producer | grep -q`. That is HANDOFF trap 6, and this was its last
# surviving instance in tools/: under `set -o pipefail` the consumer exits at
# the first match, the producer takes SIGPIPE, and its status leaks out as the
# pipeline's -- so a SUCCESSFUL match reads as a FAILURE, racily, depending on
# whether the producer had already drained into the pipe buffer. Reproduced on
# a file whose first line matches both patterns:
#
#   $ grep -F 'namespace.default.link.system.shared_libs' big.txt \
#         | grep -Fq 'libandroid_net.so'
#   $ echo "${PIPESTATUS[*]}"
#   1 0
#
# i.e. the consumer said "found" and the pipeline said 1. (Trap 6 records 141;
# the grep on this host is ugrep, which converts SIGPIPE to exit 1. Same bug,
# different number -- do not pattern-match on the 141.)
elif ! grep -Fq 'libandroid_net.so' \
        <<<"$(grep -F 'namespace.default.link.system.shared_libs' "${LD_CONFIG}" || true)"; then
    echo "   Vendor default namespace does not link the libandroid_net LLNDK SONAME"
    status=1
fi

# The ePDG data plane is intentional. Check its mixed-bitness contract rather
# than treating the payload as forbidden: mtkmal/wfca/MAL are 32-bit, while
# epdg_wod and strongSwan are 64-bit; libwo is required in both namespaces.
while read -r expected_class relative_path; do
    [[ -n "${relative_path}" ]] || continue
    output_path="${PRODUCT_OUT}/${relative_path}"
    if [[ ! -f "${output_path}" ]]; then
        echo "   ePDG payload missing: ${relative_path}"
        status=1
    elif [[ "$(elf_class_of "${output_path}")" != "${expected_class}" ]]; then
        echo "   ePDG payload has the wrong ELF class (expected ${expected_class}): ${relative_path}"
        status=1
    fi
done <<'EOF'
ELF64 vendor/bin/epdg_wod
ELF32 vendor/bin/wfca
ELF64 vendor/bin/starter
ELF64 vendor/bin/charon
ELF64 vendor/bin/stroke
ELF32 vendor/lib/libwo.so
ELF64 vendor/lib64/libwo.so
EOF

for relative_path in \
    vendor/etc/ipsec/ipsec.conf \
    vendor/etc/ipsec/strongswan.conf \
    vendor/etc/ipsec/wod_cust.conf \
    vendor/etc/ipsec/wod_optr.conf; do
    if [[ ! -s "${PRODUCT_OUT}/${relative_path}" ]]; then
        echo "   ePDG configuration missing or empty: ${relative_path}"
        status=1
    fi
done

echo
if [[ "${status}" -eq 0 ]]; then
    echo "Vendor ELF closure is complete: DT_NEEDED and symbols resolve inside the"
    echo "Q vendor linker namespace, and every audited dlopen and config contract holds."
else
    echo "Vendor ELF closure FAILED - see the findings above."
fi

exit "${status}"
