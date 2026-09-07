#!/usr/bin/env python3
"""Run four new cursor histories without changing the reviewed source or fixture."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
TRIAL = HERE.parent.parent
KERNEL = TRIAL / "wmt-fwlog-kernel-work"
COMMIT = "75f4664c480ccbf64b764406776e8a3d88a3325b"
CASES = ["signal-in-wrap-tail-resumes", "disable-between-wrap-segments-resumes",
         "invalid-index-preserves-progress", "manual-read-preserves-progress"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    retained = HERE.parent / "first-small-address"
    original = json.loads((retained / "results.json").read_text())
    fixture = (retained / "fixture.h").read_bytes()
    assert digest(fixture) == original["fixture_sha256"]
    for unit in original["source_units"]:
        source = subprocess.check_output(["git", "show", COMMIT + ":" + unit["path"]], cwd=KERNEL)
        assert unit["text"].encode() in source and fixture.count(unit["text"].encode()) == 1
        assert digest(unit["text"].encode()) == unit["sha256"]
    host = (KERNEL / "tools/testing/wmt-fwlog/test_host.c").read_bytes()
    assert digest(host) == original["host_sha256"]
    (HERE / "fixture.h").write_bytes(fixture)
    (HERE / "test_host.c").write_bytes(host)
    command = ["clang", "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
               "-Wno-unused-function", "-Wno-unused-parameter", "-pthread", "-fno-omit-frame-pointer",
               "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-no-pie",
               "-DCONFIG_MTK_GMO_RAM_OPTIMIZE=1", "-I", str(HERE), str(HERE / "extra_cases.c"),
               "-o", str(HERE / "extra_cases")]
    build = subprocess.run(command, capture_output=True)
    (HERE / "extra-compile.stdout").write_bytes(build.stdout)
    (HERE / "extra-compile.stderr").write_bytes(build.stderr)
    assert build.returncode == 0, build.stderr.decode()
    result = {"commit": COMMIT, "source_units": [{key: unit[key] for key in ["path", "name", "sha256"]} for unit in original["source_units"]],
              "fixture_sha256": digest(fixture), "host_sha256": digest(host), "command": command,
              "compile_returncode": build.returncode, "cases": []}
    environment = dict(os.environ, ASAN_OPTIONS="detect_leaks=1:abort_on_error=1", UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    for case in CASES:
        run = subprocess.run([str(HERE / "extra_cases"), case], capture_output=True, env=environment, timeout=8)
        (HERE / (case + ".stdout")).write_bytes(run.stdout)
        (HERE / (case + ".stderr")).write_bytes(run.stderr)
        result["cases"].append({"case": case, "exit_code": run.returncode})
        print(case + ": " + ("PASS" if not run.returncode else "FAIL"))
    result["passed"] = sum(row["exit_code"] == 0 for row in result["cases"])
    result["total"] = len(CASES)
    result["status"] = "PASS" if result["passed"] == result["total"] else "FAIL"
    paths = ["run_extra.py", "extra_cases.c", "fixture.h", "test_host.c", "extra_cases", "extra-compile.stdout", "extra-compile.stderr"]
    paths += [case + suffix for case in CASES for suffix in [".stdout", ".stderr"]]
    result["artifacts_sha256"] = {name: digest((HERE / name).read_bytes()) for name in paths}
    (HERE / "extra-results.json").write_text(json.dumps(result, indent=2) + "\n")
    return result["status"] != "PASS"


if __name__ == "__main__":
    raise SystemExit(main())
