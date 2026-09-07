#!/usr/bin/env python3
"""Read the WMT thermal zone at most three times and bind the evidence to a build."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time


FAULT = re.compile(r"BUG:|Oops:|Kernel panic|kernel BUG|Unable to handle kernel|KASAN:|WARNING: at")
CALLBACK = re.compile(r"wmt_dev_tm_temp_query|wmt_thz_get_temp|wmt_plat_thermal_ctrl|"
                      r"mtk_wcn_cmb_stub_query_ctrl|Thermal query not registered|thermal_ctrl_cb null")
DISCOVER = """for zone in /sys/class/thermal/thermal_zone*; do
    if [ -r "$zone/type" ]; then
        printf '%s\\t' "$zone"
        cat "$zone/type"
    fi
done"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def appended_lines(before, after):
    """Find an exact overlapping ring-buffer suffix; report a gap if none survives."""
    previous, current = before.splitlines(), after.splitlines()
    if not previous:
        return current, False
    for end in range(len(current) - 1, -1, -1):
        if current[end] != previous[-1]:
            continue
        overlap = min(end + 1, len(previous))
        if current[end + 1 - overlap:end + 1] == previous[-overlap:]:
            return current[end + 1:], True
    return [], False


def save_source_context(repo, revision, output):
    common = "drivers/misc/mediatek/"
    sections = [
        ("drivers/thermal/thermal_core.c", "int thermal_zone_get_temp(", None),
        ("drivers/thermal/thermal_core.c", "temp_show(", None),
        (common + "thermal/mtk_thermal_monitor.c", "static int mtk_thermal_wrapper_get_temp", None),
        (common + "thermal/common/thermal_zones/mtk_ts_wmt.c", "#define NR_TS_SENSORS", 5),
        (common + "thermal/common/thermal_zones/mtk_ts_wmt.c", "static int sensor_select", 1),
        (common + "thermal/common/thermal_zones/mtk_ts_wmt.c", "static int wmt_thz_get_temp(", None),
        (common + "thermal/common/thermal_zones/mtk_ts_wmt.c", "#define DEFAULT_POLL_TIME", 1),
        (common + "connectivity/common/wmt_build_in_adapter.c", "int mtk_wcn_cmb_stub_query_ctrl(", None),
        (common + "connectivity/source/common/common_detect/mtk_wcn_stub_alps.c", "int mtk_wcn_cmb_stub_reg(", None),
        (common + "connectivity/source/common/common_detect/mtk_wcn_stub_alps.c", "static int _mtk_wcn_cmb_stub_query_ctrl(", None),
        (common + "connectivity/source/common/common_main/platform/wmt_plat_alps.c", "static long wmt_plat_thermal_ctrl(", None),
        (common + "connectivity/source/common/common_main/linux/wmt_dev.c", "LONG wmt_dev_tm_temp_query(", None),
    ]
    sources, rows, excerpts = {}, [], []
    for path, marker, count in sections:
        if path not in sources:
            sources[path] = subprocess.check_output(["git", "show", revision + ":" + path], cwd=repo)
        text = sources[path].decode()
        start = text.index(marker)
        if count is None:
            # A function marker may first occur in a forward declaration.
            while ";" in text[start:text.index("{", start)]:
                start = text.index(marker, start + len(marker))
        end = text.index("\n}", start) + 2 if count is None else start + len("\n".join(text[start:].splitlines()[:count]))
        first_line = text.count("\n", 0, start) + 1
        excerpt = text[start:end]
        rows.append(dict(path=path, first_line=first_line, marker=marker,
                         excerpt_sha256=digest(excerpt.encode())))
        excerpts.append(f"{revision}:{path}:{first_line}\n{excerpt}\n")
    (output / "source-excerpts.txt").write_text("\n".join(excerpts))
    return dict(revision=revision, source_sha256={path: digest(data) for path, data in sources.items()}, sections=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True, help="Evidence label, for example 16 or 17")
    parser.add_argument("--expected-manifest", required=True, type=Path)
    parser.add_argument("--kernel-repo", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-boot-id")
    parser.add_argument("--adb", default="/home/desmond/Android/Sdk/platform-tools/adb")
    parser.add_argument("--serial", default="0123456789ABCDEF")
    parser.add_argument("--zone-type", default="mtktswmt")
    parser.add_argument("--reads", type=int, choices=[1, 2, 3], default=3)
    args = parser.parse_args()
    manifest_data = args.expected_manifest.read_bytes()
    expected = json.loads(manifest_data)
    if expected.get("status") != "PASS":
        parser.error("Expected manifest must have PASS status")
    modules = [row for row in expected["rows"] if Path(row["path"]).name == "wmt_drv.ko"]
    if len(modules) != 1 or not re.fullmatch(r"[0-9a-f]{64}", modules[0]["sha256"]):
        parser.error("Expected manifest must identify exactly one hashed wmt_drv.ko")
    module = modules[0]
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "expected-manifest.json").write_bytes(manifest_data)
    result = dict(status="RUNNING", started_utc=utc(), build=args.build, serial=args.serial,
                  expected_manifest=str(args.expected_manifest.resolve()),
                  expected_manifest_sha256=digest(manifest_data),
                  expected_incremental=expected["incremental"],
                  expected_receipt_sha256=expected.get("receipt_sha256"),
                  script_sha256=digest(Path(__file__).read_bytes()),
                  requested_reads=args.reads, reads=[], commands=[], errors=[])
    env = dict(os.environ, ADB_LIBUSB="1")
    adb = [args.adb, "-s", args.serial, "shell"]

    def remote(name, command):
        started = time.monotonic()
        record = dict(name=name, remote_command=command, started_utc=utc())
        try:
            run = subprocess.run(adb + [command], env=env, capture_output=True, timeout=30)
            stdout, stderr, code = run.stdout, run.stderr, run.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr, code = error.stdout or b"", error.stderr or b"", 124
        record.update(exit_code=code, elapsed_seconds=time.monotonic() - started,
                      stdout_sha256=digest(stdout), stderr_sha256=digest(stderr))
        result["commands"].append(record)
        (args.output / (name + ".txt")).write_bytes(stdout)
        (args.output / (name + ".stderr.txt")).write_bytes(stderr)
        if code:
            raise RuntimeError(f"{name} failed with exit {code}; see saved output")
        return stdout.decode(errors="replace")

    def shell(name, *arguments):
        return remote(name, shlex.join(arguments))

    def boot_state(name):
        lines = shell(name, "cat", "/proc/sys/kernel/random/boot_id", "/proc/sys/kernel/tainted",
                      "/proc/uptime").splitlines()
        if len(lines) != 3:
            raise RuntimeError("Unexpected boot-state output")
        return dict(boot_id=lines[0], taint=int(lines[1]), uptime_seconds=float(lines[2].split()[0]))

    def check_state(state, boot):
        if state["boot_id"] != boot or state["taint"] != 0:
            raise RuntimeError("Boot ID changed or kernel is tainted")

    def module_state(name):
        hashed = shell(name + "-hash", "sha256sum", module["path"]).split()
        if len(hashed) != 2 or hashed[0] != module["sha256"] or hashed[1] != module["path"]:
            raise RuntimeError("Installed WMT module differs from expected manifest")
        loaded = [line for line in shell(name + "-modules", "cat", "/proc/modules").splitlines()
                  if line.split()[0] == "wmt_drv"]
        if len(loaded) != 1 or " Live " not in loaded[0]:
            raise RuntimeError("Expected a live wmt_drv module")
        return dict(path=module["path"], sha256=hashed[0], loaded_module=loaded[0])

    try:
        result["source_context"] = save_source_context(args.kernel_repo, expected["kernel_revision"], args.output)
        before = boot_state("identity-before")
        result["identity_before"] = before
        check_state(before, args.expected_boot_id or before["boot_id"])
        incremental = shell("incremental-before", "getprop", "ro.build.version.incremental").strip()
        if incremental != expected["incremental"]:
            raise RuntimeError("Handset incremental differs from expected manifest")
        result["module_before"] = module_state("wmt-before")
        discovered = []
        for line in remote("thermal-zone-types", DISCOVER).splitlines():
            path, kind = line.split("\t", 1)
            if not re.fullmatch(r"/sys/class/thermal/thermal_zone[0-9]+", path):
                raise RuntimeError("Unexpected thermal-zone path")
            discovered.append(dict(path=path, type=kind))
        result["thermal_zones"] = discovered
        matches = [zone for zone in discovered if zone["type"] == args.zone_type]
        if len(matches) != 1:
            raise RuntimeError(f"Expected exactly one thermal zone of type {args.zone_type}; found {len(matches)}")
        zone = matches[0]
        result["selected_zone"] = dict(zone, temperature_path=zone["path"] + "/temp")
        for index in range(1, args.reads + 1):
            label = f"read-{index}"
            sample = dict(index=index)
            result["reads"].append(sample)
            sample["before"] = boot_state(label + "-identity-before")
            check_state(sample["before"], before["boot_id"])
            kernel_before = shell(label + "-kernel-before", "dmesg")
            # exec preserves this shell PID in cat, allowing printk caller attribution.
            command = "printf '%s\\n' \"$$\"\nexec cat " + shlex.quote(zone["path"] + "/temp")
            read_output = remote(label + "-temperature", command).splitlines()
            if len(read_output) != 2 or not re.fullmatch(r"[0-9]+", read_output[0]) or not re.fullmatch(r"-?[0-9]+", read_output[1]):
                raise RuntimeError("Unexpected PID/temperature output")
            sample.update(caller_pid=int(read_output[0]), temperature_millidegrees=int(read_output[1]))
            sample["after"] = boot_state(label + "-identity-after")
            check_state(sample["after"], before["boot_id"])
            kernel_after = shell(label + "-kernel-after", "dmesg")
            interval, continuous = appended_lines(kernel_before, kernel_after)
            sample["kernel_overlap_preserved"] = continuous
            (args.output / (label + "-kernel-interval.txt")).write_text("\n".join(interval) + "\n")
            sample["callback_lines"] = [line for line in interval if CALLBACK.search(line)]
            pid_pattern = re.compile(r"\[\s*" + str(sample["caller_pid"]) + r":[^\]]+\]")
            sample["same_pid_callback_lines"] = [line for line in sample["callback_lines"]
                                                 if pid_pattern.search(line) and "wmt_dev_tm_temp_query" in line]
            sample["fresh_wmt_read_branch_lines"] = [line for line in sample["same_pid_callback_lines"]
                                                    if "[Thermal] current_temp" in line]
            sample["recognized_fault_signatures"] = [line for line in interval if FAULT.search(line)]
            print(f"read {index}: {sample['temperature_millidegrees']} mC; caller {sample['caller_pid']}; "
                  f"matching WMT callback logs {len(sample['same_pid_callback_lines'])}", flush=True)
            if sample["recognized_fault_signatures"]:
                break
            if index < args.reads:
                time.sleep(1)
        result["identity_after"] = boot_state("identity-after")
        check_state(result["identity_after"], before["boot_id"])
        result["incremental_after"] = shell("incremental-after", "getprop", "ro.build.version.incremental").strip()
        if result["incremental_after"] != expected["incremental"]:
            raise RuntimeError("Handset incremental changed")
        result["module_after"] = module_state("wmt-after")
        result["zone_type_after"] = shell("thermal-zone-type-after", "cat", zone["path"] + "/type").strip()
        if result["zone_type_after"] != zone["type"]:
            raise RuntimeError("Selected thermal zone type changed")
        result["attributed_callback_reads"] = sum(bool(row.get("same_pid_callback_lines")) for row in result["reads"])
        result["callback_execution_evidence"] = "OBSERVED_SAME_PID" if result["attributed_callback_reads"] else "INCONCLUSIVE"
        result["status"] = "PASS" if (len(result["reads"]) == args.reads and all(
            row["kernel_overlap_preserved"] and not row["recognized_fault_signatures"] for row in result["reads"])) else "INCOMPLETE"
    except Exception as error:
        result["status"] = "ERROR"
        result["errors"].append(f"{type(error).__name__}: {error}")
    result["finished_utc"] = utc()
    result["limitations"] = [
        "PASS describes bounded sysfs reads and identity checks, not callback teardown or unload safety.",
        "Only matching cat PID log records directly attribute WMT callback execution to a sample; absence is inconclusive.",
        "The WMT zone invokes four sensor wrappers and returns a selected sensor; its output need not equal the WMT sensor value.",
        "Caching, external thermal control, logging level, or callback closure can prevent direct execution evidence.",
        "No trip, polling, debug control, radio, or module state was changed by this script.",
    ]
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    hashes = {str(path.relative_to(args.output)): digest(path.read_bytes()) for path in sorted(args.output.rglob("*")) if path.is_file()}
    (args.output / "artifact-sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    print(f"{result['status']}: {args.output / 'result.json'}", flush=True)
    if result["errors"]:
        print("\n".join(result["errors"]), file=sys.stderr)
    return result["status"] != "PASS"


if __name__ == "__main__":
    raise SystemExit(main())
