#!/usr/bin/env python3
"""Verify the frozen firmware-log source, retained runs, and independent review."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
TRIAL = HERE.parent.parent
KERNEL = TRIAL / "wmt-fwlog-kernel-work"
COMMIT = "75f4664c480ccbf64b764406776e8a3d88a3325b"
BASE = "372a643505f6b0aab0b3adbd150ecb9d9291d8d9"
COMMON = "drivers/misc/mediatek/connectivity/source/common/common_main/"
FROZEN_MANIFEST_SHA = "46098609ce4c4bf8d24cbf7c84985cbf09b58bed1f0148ccb9deb3493c3fdc23"
ARTIFACT_MANIFEST_SHA = "71cbbe12a7f96340e5fc9d5fb0ab4af95ef1ac5c73d3ed388f3b7dd07f0957be"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=KERNEL)


def main():
    assert git("rev-parse", "HEAD").decode().strip() == COMMIT
    assert git("rev-parse", "HEAD^").decode().strip() == BASE
    assert not git("status", "--porcelain")
    subprocess.run(["git", "diff", "--check", BASE, COMMIT], cwd=KERNEL, check=True)
    assert digest((HERE.parent / "final-validation.json").read_bytes()) == FROZEN_MANIFEST_SHA
    assert digest((HERE.parent / "artifact-sha256.json").read_bytes()) == ARTIFACT_MANIFEST_SHA
    frozen = json.loads((HERE.parent / "final-validation.json").read_text())
    artifacts = json.loads((HERE.parent / "artifact-sha256.json").read_text())
    for item in artifacts["files"]:
        assert digest((HERE.parent / item["path"]).read_bytes()) == item["sha256"], item["path"]
    for item in frozen["changed_files"]:
        assert digest(git("show", COMMIT + ":" + item["path"])) == item["sha256"]
        assert digest((KERNEL / item["path"]).read_bytes()) == item["sha256"]
    for run in frozen["host_runs"]:
        run_path = Path(run["path"])
        assert digest(run_path.read_bytes()) == run["sha256"]
        data = json.loads(run_path.read_text())
        revision = BASE if data["baseline_control"] else COMMIT
        fixture = (run_path.parent / "fixture.h").read_bytes()
        assert digest(fixture) == data["fixture_sha256"]
        for source in data["source_files"]:
            assert digest(git("show", revision + ":" + source["path"])) == source["sha256"]
        for unit in data["source_units"]:
            text = unit["text"].encode()
            assert digest(text) == unit["sha256"] and fixture.count(text) == 1
            assert text in git("show", revision + ":" + unit["path"])
        assert digest((KERNEL / "tools/testing/wmt-fwlog/test_host.c").read_bytes()) == data["host_sha256"]
        assert digest((KERNEL / "tools/testing/wmt-fwlog/run.py").read_bytes()) == data["runner_sha256"]
        assert data["compile_returncode"] == 0 and data["expected_behavior_verified"]
        if data["baseline_control"]:
            assert data["passed_cases"] == 0 and data["completed_cases"] == 6
            assert all(row["returncode"] not in [0, 124] for row in data["cases"])
        else:
            assert data["passed_cases"] == data["completed_cases"] == (3 if data["thread_sanitizer"] else 26)

    arm = frozen["arm64_compile"]
    assert digest(Path(arm["retained_command"]).read_bytes()) == arm["retained_command_sha256"]
    assert digest((TRIAL / "kernel-obj-build14-snapshot/.config").read_bytes()) == arm["snapshot_config_sha256"]
    command_path = HERE.parent / "arm64-first/command.json"
    assert digest(command_path.read_bytes()) == arm["command_sha256"]
    command = json.loads(command_path.read_text())
    assert "-Werror" in command and "aarch64" in command[0] and arm["returncode"] == 0
    elf = (HERE.parent / "arm64-first/wmt_dbg.o").read_bytes()
    assert digest(elf) == arm["object_sha256"]
    assert elf[:6] == b"\x7fELF\x02\x01" and int.from_bytes(elf[18:20], "little") == 183

    extra = json.loads((HERE / "extra-results.json").read_text())
    assert extra["commit"] == COMMIT and extra["status"] == "PASS" and extra["passed"] == extra["total"] == 4
    for name, sha256 in extra["artifacts_sha256"].items():
        assert digest((HERE / name).read_bytes()) == sha256
    reviewed = [COMMON + suffix for suffix in [
        "linux/wmt_dbg.c", "linux/wmt_dev.c", "linux/osal.c", "core/wmt_lib.c",
        "platform/wmt_plat_alps.c", "platform/mtk_wcn_consys_hw.c", "platform/mt6755.c",
        "platform/include/mt6755.h", "platform/include/mtk_wcn_consys_hw.h",
    ]]
    paired_revision = "857d2d0b238231ad931e342c6950c458dae99063"
    paired_dev = subprocess.check_output(["git", "show", paired_revision + ":" + COMMON + "linux/wmt_dev.c"], cwd=TRIAL / "wmt-command-v2-kernel-work")
    assert b"iRet = wmt_dbg_fwinfor_from_emi(0, 1, 0);" in paired_dev
    result = {
        "status": "PASS", "findings": [], "reviewed_commit": COMMIT, "base_commit": BASE,
        "worktree_clean": True,
        "source_sha256": digest((KERNEL / COMMON / "linux/wmt_dbg.c").read_bytes()),
        "source_files_sha256": {name: digest(git("show", COMMIT + ":" + name)) for name in reviewed},
        "frozen_manifest": {"path": str(HERE.parent / "final-validation.json"), "sha256": FROZEN_MANIFEST_SHA},
        "artifact_manifest": {"path": str(HERE.parent / "artifact-sha256.json"), "sha256": ARTIFACT_MANIFEST_SHA, "files_verified": len(artifacts["files"])},
        "reviewed_retained_runs": [{key: run[key] for key in ["path", "sha256", "passed_cases", "completed_cases", "baseline_control"]} for run in frozen["host_runs"]],
        "extra_tests": {"path": str(HERE / "extra-results.json"), "sha256": digest((HERE / "extra-results.json").read_bytes()), "passed": 4, "total": 4, "sanitizers": ["AddressSanitizer", "UndefinedBehaviorSanitizer"], "cases": extra["cases"]},
        "arm64_compile": {"source_sha256": arm["source_sha256"], "object_sha256": arm["object_sha256"], "retained_evidence_verified": True, "rerun": False},
        "paired_ioctl_error_propagation": {"revision": paired_revision, "wmt_dev_sha256": digest(paired_dev), "verified": True},
        "review_artifacts_sha256": {name: digest((HERE / name).read_bytes()) for name in ["review.md", "verify_review.py", "extra-results.json"]},
        "boundary": "Read-only source review and four additional source-derived host cases. Retained 26+26 ASan/UBSan and 3 TSan runs were hash-verified, not rerun. No full kernel build, actual firmware execution, ADB, or device access in this review.",
    }
    (HERE / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": "PASS", "findings": 0, "extra_tests": "4/4", "artifacts_verified": len(artifacts["files"]), "result_sha256": digest((HERE / "result.json").read_bytes())}))


if __name__ == "__main__":
    main()
