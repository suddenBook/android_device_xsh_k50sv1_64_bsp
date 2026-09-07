#!/usr/bin/env python3
"""Verify retained retry evidence against the exact launcher commit."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
TRIAL = HERE.parent.parent
REPO = TRIAL / "wmt-launcher-device-work"
COMMIT = "2cbfa92e64e2b01461de512e4feb2c5676406125"
BASE = "ceeee481e3470de54c54f3a6dd26756af672e2cd"
OWNED = ["wmt-launcher/README.md", "wmt-launcher/main.c", "wmt-launcher/test_launcher.c", "wmt-launcher/test_launcher.py"]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=REPO)


def main():
    assert git("rev-parse", "HEAD").decode().strip() == COMMIT
    assert git("rev-parse", COMMIT + "^").decode().strip() == BASE
    assert not git("status", "--porcelain")
    assert sorted(git("diff", "--name-only", BASE, COMMIT).decode().splitlines()) == OWNED
    subprocess.run(["git", "diff", "--check", BASE, COMMIT], cwd=REPO, check=True)
    source_hashes = {name: sha256(git("show", COMMIT + ":" + name)) for name in OWNED}
    assert all(sha256((REPO / name).read_bytes()) == digest for name, digest in source_hashes.items())
    (HERE / "commit.patch").write_bytes(git("format-patch", "--stdout", "-1", COMMIT))
    results = {}
    for name, passed, total in [("baseline-address", 2, 10), ("candidate-address", 35, 35), ("candidate-thread", 17, 17)]:
        directory = HERE / name
        data = json.loads((directory / "result.json").read_text())
        assert data["compile_exit_code"] == 0
        assert data["passed"] == passed and data["total"] == total and len(data["cases"]) == total
        for artifact, digest in data["artifacts"].items():
            assert sha256((directory / artifact).read_bytes()) == digest, (name, artifact)
        for source_name, digest in data["source_sha256"].items():
            revision = BASE if name == "baseline-address" and source_name == "main.c" else COMMIT
            assert sha256(git("show", revision + ":wmt-launcher/" + source_name)) == digest, (name, source_name)
        for firmware_name, digest in data["firmware_sha256"].items():
            firmware_path = TRIAL / "wmt-launcher-vendor-work/proprietary/vendor/firmware" / firmware_name
            assert sha256(firmware_path.read_bytes()) == digest
        if name == "baseline-address":
            existing = {"fw-disable-after-failure", "fw-disable-retry"}
            assert all(row["exit_code"] == (0 if row["case"] in existing else -6) for row in data["cases"])
            for row in data["cases"]:
                if not row["passed"]:
                    stderr = (directory / (row["case"] + ".stderr")).read_text()
                    assert "Assertion `state." in stderr and "failed." in stderr
            assert (directory / "baseline-main.c").read_bytes() == git("show", BASE + ":wmt-launcher/main.c")
        else:
            assert data["status"] == "PASS" and all(row["passed"] for row in data["cases"])
        results[name] = {
            "result_path": str(directory / "result.json"), "result_sha256": sha256((directory / "result.json").read_bytes()),
            "status": data["status"], "passed": passed, "total": total, "sanitizer": data["sanitizer"],
            "source_hashes_verified": len(data["source_sha256"]), "artifacts_verified": len(data["artifacts"]),
            "cases": data["cases"],
        }
    report = {
        "status": "PASS", "commit": COMMIT, "parent": BASE, "worktree_clean_at_freeze": True,
        "owned_source_sha256": source_hashes,
        "scope": "Only the four owned launcher files changed; no firmware, protocol, UAPI, module recipe, build-project, canonical, or ADB writes.",
        "behavior": [
            "Only successful dynamic dump ioctls update the applied-value cache; the unchanged desired value retries on a later ordinary poll iteration.",
            "A desired yes with a finished log worker joins that worker before at most one replacement creation in that iteration; a failed join prevents reuse.",
            "Live workers retain their state; stopping still marks stopping, joins the worker, then issues final disable.",
            "A previously created but reaped worker retains a final-disable obligation if its replacement cannot start or a previous disable failed.",
        ],
        "verification": results,
        "candidate_execution_count": 52,
        "candidate_distinct_service_cases": 35,
        "baseline_expected_recovery_failures": 8,
        "baseline_existing_disable_cases_passed": 2,
        "evidence_sha256": {
            "commit.patch": sha256((HERE / "commit.patch").read_bytes()),
            "verify_result.py": sha256(Path(__file__).read_bytes()),
            "baseline-address/baseline-main.c": sha256((HERE / "baseline-address/baseline-main.c").read_bytes()),
        },
        "boundary": "Actual main.c, real pthread create/join, codec and firmware discovery run against bounded host device/property/timing adapters. This task did not compile the final Android target, build/link the kernel, or execute on a handset; those integration checks are separately owned.",
    }
    (HERE / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"status": "PASS", "commit": COMMIT, "address": "35/35", "thread": "17/17", "baseline_expected_failures": 8, "manifest_sha256": sha256((HERE / "result.json").read_bytes())}))


if __name__ == "__main__":
    main()
