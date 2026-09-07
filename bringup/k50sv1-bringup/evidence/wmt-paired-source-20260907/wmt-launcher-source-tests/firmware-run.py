#!/usr/bin/env python3
"""Host-only checks of firmware discovery with retained normal/synthetic ROM data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "sources").mkdir()
    (output / "temporary").mkdir()
    names = ["firmware.h", "firmware.c", "test_firmware.c", "patch.h", "patch.c"]
    inputs = []
    for name in names:
        original = source / name
        snapshot = output / "sources" / name
        shutil.copyfile(original, snapshot)
        inputs.append({"path": str(original), "sha256": sha256(snapshot)})
    reference = json.loads(args.reference.read_text())
    firmware = reference["patches"]
    firmware_paths = []
    firmware_inputs = []
    for record in firmware:
        path = Path(record["path"])
        digest = sha256(path)
        assert digest == record["sha256"], (str(path), "retained firmware hash mismatch")
        firmware_paths.append(str(path))
        firmware_inputs.append({"path": str(path), "sha256": digest,
                                "header_hex": path.read_bytes()[:28].hex()})
    compiler = shutil.which(args.cc)
    assert compiler, args.cc
    wrappers = ["openat", "fstat", "read", "readdir", "close", "closedir", "malloc", "lseek"]
    binary = output / "test_firmware"
    command = [compiler, "-std=gnu11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
               "-fno-omit-frame-pointer", "-fsanitize=address,undefined",
               "-fno-sanitize-recover=all", "-I", str(output / "sources")]
    command += [str(output / "sources" / name) for name in
                ["patch.c", "firmware.c", "test_firmware.c"]]
    command += ["-Wl,--wrap=" + name for name in wrappers]
    command += ["-o", str(binary)]
    compile_result = subprocess.run(command, text=True, capture_output=True, timeout=60)
    (output / "compile.stdout").write_text(compile_result.stdout)
    (output / "compile.stderr").write_text(compile_result.stderr)
    report = {"source_inputs": inputs, "firmware_inputs": firmware_inputs,
              "reference_path": str(args.reference.resolve()), "reference_sha256": sha256(args.reference),
              "runner_path": str(Path(__file__).resolve()), "runner_sha256": sha256(Path(__file__)),
              "compiler": subprocess.check_output([compiler, "--version"], text=True),
              "compile_command": command, "compile_returncode": compile_result.returncode,
              "rom_fixtures": "synthetic; no retained ROM firmware is present"}
    if compile_result.returncode == 0:
        environment = os.environ.copy()
        options = {"ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1:abort_on_error=1",
                   "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=1"}
        environment.update(options)
        run_command = [str(binary), *firmware_paths, str(output / "temporary")]
        result = subprocess.run(run_command, env=environment, text=True,
                                capture_output=True, timeout=60)
        (output / "test.stdout").write_text(result.stdout)
        (output / "test.stderr").write_text(result.stderr)
        report.update({"run_command": run_command, "sanitizer_options": options,
                       "test_returncode": result.returncode, "binary_sha256": sha256(binary)})
        if result.returncode == 0:
            report["cases"] = [json.loads(line) for line in result.stdout.splitlines()]
    report["source_stable"] = all(sha256(Path(item["path"])) == item["sha256"] for item in inputs)
    report["passed"] = (report["compile_returncode"] == 0 and
                        report.get("test_returncode") == 0 and report["source_stable"])
    (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"output": str(output), "passed": report["passed"],
                      "compile_returncode": compile_result.returncode,
                      "test_returncode": report.get("test_returncode"),
                      "results_sha256": sha256(output / "results.json")}))
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
