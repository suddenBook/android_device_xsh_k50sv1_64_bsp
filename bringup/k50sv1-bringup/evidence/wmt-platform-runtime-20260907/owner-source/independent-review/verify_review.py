#!/usr/bin/env python3
"""Bind the independent review to the frozen source and retained evidence."""
import collections
import hashlib
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
TRIAL = HERE.parent.parent
KERNEL = TRIAL / "wmt-platform-owner-kernel-work"
COMMIT = "fcd8380a217368b55a06d9913647913a14748267"
BASE = "372a643505f6b0aab0b3adbd150ecb9d9291d8d9"
TEST = "drivers/misc/mediatek/connectivity/source/common/test/"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*args):
    return subprocess.check_output(["git", *args], cwd=KERNEL)


def main():
    assert git("rev-parse", "HEAD").decode().strip() == COMMIT
    assert git("rev-parse", "HEAD^").decode().strip() == BASE
    assert not git("status", "--porcelain")
    callers = json.loads((HERE / "callers.json").read_text())
    resolutions = {
        "drivers/media/platform/sh_veu.c": ("THIS_MODULE", 1235),
        "drivers/media/platform/sh_vou.c": ("THIS_MODULE", 1448),
    }
    for row in callers:
        name = row["file"]
        assert digest((KERNEL / name).read_bytes()) == row["file_sha256"]
        if name in resolutions:
            row["owner_initializer"], row["initializer_line"] = resolutions[name]
            row["storage"] = "static"
            row["resolution"] = "The __refdata qualifier precedes the variable name."
        elif name == "drivers/platform/x86/asus-wmi.c":
            row["owner_initializer"] = "forwarded THIS_MODULE from either in-tree caller"
            row["storage"] = "embedded in caller's static asus_wmi_driver"
            row["owner_assignment_line"] = 1939
            row["resolution"] = [
                {"file": "drivers/platform/x86/asus-nb-wmi.c", "owner_line": 373, "call_line": 384},
                {"file": "drivers/platform/x86/eeepc-wmi.c", "owner_line": 256, "call_line": 269},
            ]
    assert all(row["owner_initializer"] != "UNRESOLVED" for row in callers)
    actual_calls = []
    for name in git("ls-files", "*.c").decode().splitlines():
        if name == "drivers/base/platform.c" or "/common/test/" in name:
            continue
        source = (KERNEL / name).read_text(errors="replace")
        source = re.sub(r"/\*.*?\*/|//[^\n]*", lambda m: "\n" * m[0].count("\n"), source, flags=re.S)
        pattern = r"\b(module_platform_driver_probe|platform_driver_probe|platform_create_bundle)\s*\(\s*&?\s*([a-zA-Z_][a-zA-Z0-9_]*)"
        for match in re.finditer(pattern, source):
            actual_calls.append((name, source.count("\n", 0, match.start()) + 1, match[1], match[2]))
    expected_calls = {(r["file"], r["line"], r["api"], r["driver"]) for r in callers}
    assert set(actual_calls) == expected_calls and len(actual_calls) == len(callers) == 162
    (HERE / "callers.json").write_text(json.dumps(callers, indent=2) + "\n")

    checks = []
    for relative in ["fixed-first", "baseline-first", "arm64-first", "independent-review/host"]:
        directory = HERE.parent / relative
        result = json.loads((directory / "result.json").read_text())
        revision = BASE if relative == "baseline-first" else COMMIT
        assert digest(git("show", revision + ":drivers/base/platform.c")) == result["source_sha256"]
        for artifact, sha256 in result["artifacts"].items():
            assert digest((directory / artifact).read_bytes()) == sha256, (relative, artifact)
        if "cases" in result:
            assert digest((KERNEL / TEST / "platform_probe_owner_host.c").read_bytes()) == result["fixture_sha256"]
            assert digest((KERNEL / TEST / "test_platform_probe_owner.py").read_bytes()) == result["runner_sha256"]
            assert result["compile_exit_code"] == 0 and result["total"] == 8
            assert result["passed"] == (3 if relative == "baseline-first" else 8)
            if relative == "baseline-first":
                assert all(row["exit_code"] == (0 if row["case"].startswith("builtin-") else -6) for row in result["cases"])
        else:
            assert result["status"] == "PASS" and result["exit_code"] == 0
            assert digest((TRIAL / "kernel-obj-build14-snapshot/.config").read_bytes()) == result["config_sha256"]
            assert digest((TRIAL / "kernel-obj-build14-snapshot/drivers/base/.platform.o.cmd").read_bytes()) == result["saved_command_sha256"]
            command = json.loads((directory / "command.json").read_text())
            assert "aarch64-linux-android-4.9" in command[0] and "-Werror" in command
            assert str(KERNEL / "drivers/base/platform.c") in command
            # ELF e_machine is EM_AARCH64 (183); class 2 and data 1 mean ELF64 LE.
            elf = (directory / "platform.o").read_bytes()
            assert elf[:6] == b"\x7fELF\x02\x01" and int.from_bytes(elf[18:20], "little") == 183
        checks.append({"evidence": str(directory / "result.json"), "sha256": digest((directory / "result.json").read_bytes()), "artifacts_verified": len(result["artifacts"]), "status": "PASS"})

    source_names = [
        "Makefile", "drivers/base/Makefile", "drivers/base/platform.c", "drivers/base/module.c", "drivers/base/bus.c",
        "include/linux/platform_device.h", "include/linux/export.h",
        "drivers/misc/mediatek/connectivity/source/common/common_main/platform/mtk_wcn_consys_hw.c",
        "drivers/platform/x86/asus-wmi.c", "drivers/platform/x86/asus-nb-wmi.c", "drivers/platform/x86/eeepc-wmi.c",
        TEST + "README_platform_probe_owner.md", TEST + "platform_probe_owner_host.c", TEST + "test_platform_probe_owner.py",
    ]
    report = {
        "status": "PASS", "conclusion": "No actionable findings in the frozen owner-preservation change.",
        "reviewed_commit": COMMIT, "base_commit": BASE, "kernel_version": "3.18.119", "worktree_clean": True,
        "production_change": "drivers/base/platform.c:642 preserves drv->driver.owner in platform_driver_probe",
        "reviewed_source_sha256": {name: digest((KERNEL / name).read_bytes()) for name in source_names},
        "caller_audit": {"call_sites": len(callers), "api_counts": dict(collections.Counter(r["api"] for r in callers)),
                         "owner_counts": dict(collections.Counter(r["owner_initializer"] for r in callers)),
                         "source_hashes_verified": len(callers), "unresolved": 0},
        "independent_host_rerun": {"passed": 8, "total": 8, "sanitizers": ["AddressSanitizer", "UndefinedBehaviorSanitizer"]},
        "retained_baseline": {"passed": 3, "total": 8, "expected_module_owner_failures": 5},
        "arm64_evidence": "Existing actual GCC 4.9 -Werror platform.o evidence and hashes verified; ELF64 AArch64. Compilation was not rerun by this review.",
        "checks": checks,
        "boundary": "Host tests extract actual core helpers with deterministic bus/list adapters. No phone access, real module unload, full kernel build, or runtime module-link verification in this review.",
        "review_artifacts_sha256": {name: digest((HERE / name).read_bytes()) for name in ["review.md", "callers.json", "verify_review.py"]},
    }
    (HERE / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": report["status"], "commit": COMMIT, "host": "8/8", "callers": len(callers), "evidence_checks": len(checks)}))


if __name__ == "__main__":
    main()
