#!/usr/bin/env python3
"""Extract evidence for this fixed offline MT6755 launcher contract review.

Only writes beside this script. It never executes the vendor ELF or contacts a
device. Semantic conclusions are reviewed separately in contract.json.
"""

import hashlib
import json
import lzma
from pathlib import Path
import re
import struct
import subprocess


OUT = Path(__file__).resolve().parent
CONTRACT = OUT.parent
TRIAL = CONTRACT.parent
PROJECT = TRIAL.parents[2] / "lineage-17.1"
KERNEL = TRIAL / "wmt-callback-lifetime-kernel-work"
KERNEL_REV = "54bdf406ee9963e3b926d8f19fc2bb4c1a3975eb"
REFERENCE = TRIAL / "wmt-launcher-reference-openmttools"
REFERENCE_REV = "ef35f769d211a2942a6783410b58bd824dd363f9"
ELF_SHA = "70b5224af4276eef4a27a405919e5a147b24739569b3a24f5ee1cb8d3cd9a2a7"
BASE = "drivers/misc/mediatek/connectivity/source/common/common_main/"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write(name, data):
    (OUT / name).write_text(data, encoding="utf-8")


def record_file(path):
    data = path.read_bytes()
    return {"path": str(path), "size": len(data), "sha256": sha(data)}


def git_read(repo, rev, name):
    return subprocess.check_output(["git", "show", rev + ":" + name], cwd=repo)


def cstr(data, offset):
    return data[offset:data.index(b"\0", offset)].decode("ascii")


def sections(data):
    assert data[:6] == b"\x7fELF\x02\x01", "expected ELF64 little endian"
    offset = struct.unpack_from("<Q", data, 40)[0]
    stride, count, names_index = struct.unpack_from("<HHH", data, 58)
    headers = [struct.unpack_from("<IIQQQQIIQQ", data, offset + stride * i)
               for i in range(count)]
    strings = headers[names_index]
    names = data[strings[4]:strings[4] + strings[5]]
    return [(cstr(names, h[0]), h) for h in headers]


elf_path = CONTRACT / "wmt_launcher.original"
elf = elf_path.read_bytes()
assert sha(elf) == ELF_SHA
assert struct.unpack_from("<H", elf, 18)[0] == 183, "expected AArch64"
phoff = struct.unpack_from("<Q", elf, 32)[0]
phstride, phcount = struct.unpack_from("<HH", elf, 54)
loads = []
for i in range(phcount):
    header = struct.unpack_from("<IIQQQQQQ", elf, phoff + i * phstride)
    if header[0] == 1:
        loads.append(header)


def at_va(address, size):
    for header in loads:
        if header[3] <= address and address + size <= header[3] + header[5]:
            offset = header[2] + address - header[3]
            return elf[offset:offset + size]
    raise ValueError(f"unmapped file-backed VA {address:#x}")


def string_va(address):
    data = bytearray()
    while True:
        byte = at_va(address + len(data), 1)
        if byte == b"\0":
            return data.decode("ascii")
        data.extend(byte)


debug_header = next(h for name, h in sections(elf) if name == ".gnu_debugdata")
debug = lzma.decompress(elf[debug_header[4]:debug_header[4] + debug_header[5]])
debug_sections = sections(debug)
symbols = []
for _, header in debug_sections:
    if header[1] != 2:
        continue
    strings_header = debug_sections[header[6]][1]
    strings = debug[strings_header[4]:strings_header[4] + strings_header[5]]
    for offset in range(header[4], header[4] + header[5], header[9]):
        name, info, other, section, value, size = struct.unpack_from("<IBBHQQ", debug, offset)
        name = cstr(strings, name)
        if name in {"main", "cmd_hdr_sch_patch", "cmd_hdr_sch_rom_patch",
                    "launcher_get_patch_version", "launcher_set_prop",
                    "launcher_set_prop_thread", "launcher_pwr_on_thread",
                    "g_cmd_hdr_table", "g_chip_mode_info"}:
            symbols.append({"name": name, "va": hex(value), "size": size,
                            "end_exclusive": hex(value + size)})

strings = {hex(address): string_va(address) for address in
           [0x165b, 0x16d9, 0x1984, 0x1b44, 0x1d31, 0x1ea3, 0x1eb7,
            0x1faf, 0x20c8, 0x2201, 0x23f2, 0x2450, 0x2627, 0x2698, 0x26b5]}
switch_offset = struct.unpack("<H", at_va(0x13e0 + 2 * (0x6755 - 0x6735), 2))[0]
patch_target = 0x31d8 + 4 * switch_offset
assert patch_target == 0x329c
getopt_targets = {chr(i + 0x62): hex(0x4624 + 4 * struct.unpack("<H", at_va(0x14b8 + 2 * i, 2))[0])
                  for i in range(15)}
mode_defaults = struct.unpack("<II", at_va(0x14b0, 8))
assert mode_defaults == (3, 2)

firmware_dir = PROJECT / "vendor/xsh/k50sv1_64_bsp/proprietary/vendor/firmware"
patches = []
for name in ["ROMv2_lm_patch_1_0_hdr.bin", "ROMv2_lm_patch_1_1_hdr.bin"]:
    path = firmware_dir / name
    data = path.read_bytes()
    metadata = data[24:28]
    patches.append({**record_file(path), "basename": name,
                    "first_32_bytes_hex": data[:32].hex(),
                    "build_time_16": data[:16].decode("ascii"),
                    "published_version": data[:15].decode("ascii"),
                    "platform": data[16:20].decode("ascii"),
                    "hardware_be16": hex(int.from_bytes(data[20:22], "big")),
                    "firmware_be16": hex(int.from_bytes(data[22:24], "big")),
                    "metadata_hex": metadata.hex(), "patch_count": metadata[0] >> 4,
                    "sequence": metadata[0] & 15,
                    "ioctl_address_hex": (b"\0" + metadata[1:]).hex(),
                    "body_offset": 28, "body_bytes_mt6755": len(data) - 28})

source_ranges = {
    "linux/wmt_dev.c": [(90, 119), (145, 153), (600, 613), (639, 738),
                         (1090, 1189), (1361, 1416), (1429, 1442), (1530, 1541), (1573, 1632)],
    "core/include/wmt_core.h": [(427, 443)],
    "core/include/wmt_lib.h": [(166, 176)],
    "core/wmt_ctrl.c": [(530, 628), (829, 880)],
    "core/wmt_lib.c": [(337, 370), (764, 810), (3442, 3578)],
    "core/wmt_ic_soc.c": [(1216, 1298), (2881, 2892), (3270, 3336), (3551, 3599)],
    "platform/mt6755.c": [(151, 214)],
}
source_records = []
source_text = []
for short_name, ranges in source_ranges.items():
    name = BASE + short_name
    data = git_read(KERNEL, KERNEL_REV, name)
    source_records.append({"path": name, "git_revision": KERNEL_REV, "sha256": sha(data),
                           "excerpt_line_ranges_inclusive": ranges})
    source_text.append(f"\n{KERNEL_REV}:{name}\n")
    for number, line in enumerate(data.decode().splitlines(), 1):
        if any(start <= number <= end for start, end in ranges):
            source_text.append(f"{number}: {line}\n")

reference_records = []
for name in ["mtdaemon.c", "LICENSE", "README.md"]:
    data = git_read(REFERENCE, REFERENCE_REV, name)
    reference_records.append({"path": name, "git_revision": REFERENCE_REV, "sha256": sha(data)})
    if name == "mtdaemon.c":
        source_text.append(f"\n{REFERENCE_REV}:{name}\n")
        for number, line in enumerate(data.decode().splitlines(), 1):
            if number <= 448:
                source_text.append(f"{number}: {line}\n")
write("E-source-excerpts.txt", "".join(source_text))

disassembly_path = CONTRACT / "disassembly.txt"
address_ranges = [(0x3050, 0x384c), (0x38cc, 0x3b90), (0x4218, 0x47a0),
                  (0x4cf0, 0x4f54), (0x5154, 0x53e0), (0x5544, 0x5600),
                  (0x5738, 0x57d0), (0x5878, 0x5a70), (0x5ba8, 0x5d48)]
disassembly_lines = []
for line in disassembly_path.read_text().splitlines():
    match = re.match(r"\s*([0-9a-f]+):", line)
    if match and any(start <= int(match[1], 16) < end for start, end in address_ranges):
        disassembly_lines.append(line)
write("E-disassembly-excerpts.txt", "\n".join(disassembly_lines) + "\n")

log_path = TRIAL / "runtime/build16-first-boot-early/logcat.txt"
log_lines = []
for number, line in enumerate(log_path.read_text(errors="replace").splitlines(), 1):
    if "wmt_launcher:" in line and any(word in line for word in
            ["driver.ready", "chipid", "patch", "firmware", "formeta", "fwlog",
             "dynamic", "power", "pwr_on", "open device"]):
        log_lines.append({"source_line": number, "text": line})
write("E-build16-log-excerpts.txt", "\n".join(f"{row['source_line']}: {row['text']}" for row in log_lines) + "\n")

init_path = PROJECT / "device/xsh/k50sv1_64_bsp/rootdir/etc/init/init.wmt.rc"
config_path = TRIAL / "kernel-obj-build14-snapshot/.config"
init_lines = [{"line": n, "text": line} for n, line in enumerate(init_path.read_text().splitlines(), 1)
              if "service wmt_launcher " in line]
config_lines = [{"line": n, "text": line} for n, line in enumerate(config_path.read_text().splitlines(), 1)
                if any(name in line for name in ["CONFIG_MTK_PLATFORM=", "CONFIG_MTK_COMBO_CHIP_CONSYS_6755=",
                                                "CONFIG_MTK_CONNECTIVITY_SOURCE=", "CONFIG_MTK_COMBO_COMM_APO"]) ]
result = {
    "schema_version": 1, "scope": "fixed MT6755/BTIF offline contract evidence; no ELF/device execution",
    "elf": record_file(elf_path), "mini_debug_uncompressed_sha256": sha(debug),
    "mini_debug_symbols": symbols, "strings_by_va": strings,
    "mt6755_patch_switch": {"index": 0x6755 - 0x6735, "table_va": "0x13e0",
                              "halfword": switch_offset, "base_va": "0x31d8", "target": hex(patch_target)},
    "getopt_targets": getopt_targets, "default_stp_mode": mode_defaults[0], "default_fm_mode": mode_defaults[1],
    "default_packed_hif": "0x23", "patches": patches,
    "local_soc1_0_ram_files": sorted(p.name for p in firmware_dir.glob("soc1_0_ram*")),
    "kernel_repo": str(KERNEL), "kernel_revision": KERNEL_REV, "kernel_sources": source_records,
    "reference_repo": str(REFERENCE), "reference_revision": REFERENCE_REV, "reference_sources": reference_records,
    "existing_disassembly": record_file(disassembly_path),
    "disassembly_ranges_end_exclusive": [[hex(a), hex(b)] for a, b in address_ranges],
    "existing_build16_log": record_file(log_path), "selected_log_lines": log_lines,
    "local_init_rc": {**record_file(init_path), "launcher_lines": init_lines},
    "frozen_build14_config": {**record_file(config_path), "selected_lines": config_lines},
    "extraction_script": record_file(Path(__file__).resolve()),
    "generated_evidence": [record_file(OUT / name) for name in
                           ["E-source-excerpts.txt", "E-disassembly-excerpts.txt", "E-build16-log-excerpts.txt"]],
}
write("extracted.json", json.dumps(result, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({"output": str(OUT / "extracted.json"), "sha256": sha((OUT / "extracted.json").read_bytes()),
                  "patches": len(patches), "symbols": len(symbols), "log_lines": len(log_lines)}))
