#!/usr/bin/env python3
"""Check an Android ARM64 source WMT loader with contained imported-call mocks."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess


SCENARIOS = [
    "already-ready", "cached", "detect", "invalid-property", "open-retry",
    "cleanup-failure", "init-failure", "set-id-failure", "property-failure",
    "detect-failure", "open-failure", "alias-property", "bare-property",
    "uppercase-property", "suffix-property", "overflow-property", "negative-property",
    "other-property", "chip-property-failure", "detect-wrong-chip", "positive-failure",
    "open-permission", "close-failure",
]
NO_CLEANUP = {
    "set-id-failure", "chip-property-failure", "detect-failure",
    "detect-wrong-chip", "open-permission", "open-failure",
}
NO_INIT = NO_CLEANUP | {"cleanup-failure", "positive-failure"}
FAILURES = NO_INIT | {"init-failure", "property-failure"}
DETECT_CASES = {
    "detect", "invalid-property", "suffix-property", "overflow-property",
    "negative-property", "other-property", "chip-property-failure",
    "detect-failure", "detect-wrong-chip",
}
STATE_COMMAND = (
    "getprop persist.vendor.connsys.chipid; getprop vendor.connsys.driver.ready; "
    "cat /proc/sys/kernel/tainted; cat /proc/sys/kernel/random/boot_id"
)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def assess(scenario, result):
    """Check returned behavior and ensure failed prerequisites stop initialization."""
    lines = result.stdout.splitlines()
    summary = next((line for line in lines if line.startswith("FINAL ")), None)
    values = dict(item.split("=", 1) for item in summary.split()[1:]) if summary else {}
    ioctls = [line for line in lines if line.startswith("IOCTL ")]
    props = [line for line in lines if line.startswith("SET ")]
    errors = []
    if result.returncode != (1 if scenario in FAILURES else 0):
        errors.append("exit code")
    if values.get("ready") != ("no" if scenario in FAILURES else "yes"):
        errors.append("readiness")
    if scenario in NO_INIT and values.get("init") != "0":
        errors.append("initialization after failed prerequisite")
    if scenario in NO_CLEANUP and values.get("cleanup") != "0":
        errors.append("cleanup after failed prerequisite")
    if scenario == "already-ready" and (values.get("open") != "0" or ioctls or props):
        errors.append("reinitialization")
    if scenario == "alias-property":
        if [line.split("argument=")[1] for line in ioctls] != ["326", "6755", "6755"]:
            errors.append("alias ABI")
    if scenario == "open-failure":
        if (values.get("open"), values.get("sleep")) != ("200", "199"):
            errors.append("bounded retry count")
    if values.get("detect") != ("1" if scenario in DETECT_CASES else "0"):
        errors.append("live chip query")
    expected_requests = ["80047703"] if scenario in DETECT_CASES else []
    if scenario not in {"already-ready", "open-failure", "open-permission",
                        "detect-failure", "detect-wrong-chip", "chip-property-failure"}:
        expected_requests.append("40047701")
        if scenario != "set-id-failure":
            expected_requests.append("80047705")
            if scenario not in {"cleanup-failure", "positive-failure"}:
                expected_requests.append("80047704")
    actual_requests = [line.split("command=")[1].split()[0] for line in ioctls]
    if actual_requests != expected_requests:
        errors.append("ioctl order")
    if scenario in DETECT_CASES - {"chip-property-failure", "detect-failure",
                                  "detect-wrong-chip"}:
        if values.get("chip") != "0x6755":
            errors.append("replace invalid or absent chip cache")
    ready_write = "SET vendor.connsys.driver.ready yes"
    if scenario not in FAILURES and scenario != "already-ready":
        if ready_write not in lines or lines.index(ready_write) < lines.index(ioctls[-1]):
            errors.append("readiness before initialization")
    return {"case": scenario, "pass": not errors, "exit_code": result.returncode,
            "summary": summary, "ioctls": ioctls, "properties": props, "errors": errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", type=Path, required=True)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--loader", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--mock-library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    for binary in (args.loader, args.mock_library):
        header = binary.read_bytes()[:20]
        if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\xb7\x00":
            parser.error(f"Expected a little-endian ARM64 ELF: {binary}")
    source_digest = sha256(args.source)
    args.output.mkdir(parents=True, exist_ok=False)
    adb = [str(args.adb.resolve()), "-s", args.serial]
    env = dict(os.environ, ADB_LIBUSB="1")
    remote = "/data/local/tmp/k50-wmt-loader-test-" + secrets.token_hex(6)

    def call(*command, check=True):
        return subprocess.run(adb + list(command), env=env, text=True,
                              capture_output=True, check=check, timeout=20)

    before = call("shell", STATE_COMMAND).stdout
    (args.output / "device-state-before.txt").write_text(before)
    fields = before.splitlines()
    if len(fields) != 4 or fields[1:3] != ["yes", "0"]:
        raise RuntimeError("This probe requires an already-ready, untainted device")
    call("shell", shlex.join(["mkdir", "-m", "700", remote]))
    results = []
    complete = False
    after = None
    try:
        for filename, path in [("libloader_mock.so", args.mock_library),
                               ("wmt_loader_source", args.loader)]:
            target = remote + "/" + filename
            call("push", str(path.resolve()), target)
            actual = call("shell", shlex.join(["sha256sum", target])).stdout.split()[0]
            if actual != sha256(path):
                raise RuntimeError("Device copy differs from local input: " + filename)
        call("shell", shlex.join(["chmod", "755", remote + "/wmt_loader_source"]))
        for scenario in SCENARIOS:
            command = shlex.join([
                "env", "LD_PRELOAD=" + remote + "/libloader_mock.so",
                "WMT_FIXTURE_CASE=" + scenario, remote + "/wmt_loader_source",
            ])
            result = call("shell", command, check=False)
            trace = result.stdout + result.stderr
            (args.output / (scenario + ".txt")).write_text(trace)
            # Stop before any further invocation if containment was not established.
            if "SANDBOX_READY case=" + scenario not in result.stdout:
                raise RuntimeError("Mandatory syscall containment failed: " + scenario)
            if any(marker in trace for marker in
                   ("UNEXPECTED_", "SANDBOX_FAILED", "FIXTURE_RETRY_BUDGET_REACHED")):
                raise RuntimeError("Fixture contract failed: " + scenario)
            row = assess(scenario, result)
            results.append(row)
            print("PASS" if row["pass"] else "FAIL", scenario, flush=True)
        complete = True
    finally:
        try:
            after = call("shell", STATE_COMMAND).stdout
            (args.output / "device-state-after.txt").write_text(after)
        finally:
            cleanup = call("shell", shlex.join([
                "rm", "-f", remote + "/libloader_mock.so", remote + "/wmt_loader_source",
            ]) + " && " + shlex.join(["rmdir", remote]), check=False)
            (args.output / "cleanup.txt").write_text(cleanup.stdout + cleanup.stderr)
            report = {
                "complete": complete, "candidate_sha256": sha256(args.loader),
                "source_sha256": source_digest,
                "mock_library_sha256": sha256(args.mock_library),
                "mock_source_sha256": sha256(Path(__file__).with_name("loader_mock.c")),
                "runner_sha256": sha256(Path(__file__)),
                "device_state_unchanged": before == after,
                "remote_files_removed": cleanup.returncode == 0,
                "cases": results, "passed": sum(row["pass"] for row in results),
                "total": len(SCENARIOS),
            }
            (args.output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    if before != after or cleanup.returncode:
        raise RuntimeError("Device state changed or temporary-file cleanup failed")
    return int(any(not row["pass"] for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
