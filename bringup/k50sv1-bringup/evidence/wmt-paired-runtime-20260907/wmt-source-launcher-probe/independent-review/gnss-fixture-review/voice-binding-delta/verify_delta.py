#!/usr/bin/env python3
"""Verify the unmodified voice-binding fixture with retained/synthetic I/O."""
import argparse
import ast
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import re
import shlex
import sys
import traceback
import types

HERE = Path(__file__).resolve().parent
REVIEW = HERE.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    out = (HERE / args.output).resolve()
    assert out.parent == HERE
    out.mkdir(exist_ok=False)

    def no_process(event, _args):
        if event.startswith("subprocess.") or event in {"os.system", "os.exec", "os.posix_spawn"}:
            raise RuntimeError("No process launches in offline delta review")
    sys.addaudithook(no_process)
    spec = importlib.util.spec_from_file_location("original_review", REVIEW / "verify_snapshot.py")
    original = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(original)
    text = (HERE / "run-build19-gnss.py").read_text()
    tree = ast.parse(text, str(HERE / "run-build19-gnss.py"))
    body = next(node for node in tree.body if isinstance(node, ast.Try))
    prefix = [node for node in tree.body if any(original.assigned(node, name) for name in
              ("search_restore_required", "search_component", "voice_settings", "voice_restore_required", "log_arguments"))]
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "gnss_records")
    compiled = compile(ast.Module(body=prefix + [function, body], type_ignores=[]), str(HERE / "run-build19-gnss.py"), "exec")
    retained = {path.stem: path.read_text(errors="replace") for path in (HERE / "observed-preparation").glob("*.txt")}
    voice = json.loads((HERE / "observed-preparation/voice-settings.json").read_text())["original"]
    trial = REVIEW / "validation-initial-final/retained-fixture"
    cases = []

    def check(name, action):
        try:
            detail = action()
            cases.append(dict(name=name, status="PASS", detail=detail))
        except BaseException as error:
            cases.append(dict(name=name, status="FAIL", error=repr(error)))

    def replay(name, overrides=None, failed=(), expected_success=False, expected_fixture="PASS", expect_launch=False):
        target = out / name
        target.mkdir()
        values = dict(original.TEXT)
        values.update(retained)
        values.update(overrides or {})
        calls, steps = [], []

        def run(label, args):
            calls.append(dict(step=label, args=args))
            steps.append(dict(step=label, exit_code=1 if label in failed else 0))
            if label in failed:
                raise RuntimeError("Injected failure at " + label)
            key = label
            if key not in values and key.startswith("voice-service-state-"):
                key = "voice-service-state-0"
            if key not in values and key.startswith("gps-idle-observation-"):
                key = "gps-idle-observation-0"
            assert key in values, "No response for " + label
            return values[key]

        ns = dict(trial=trial, out=target, hashlib=hashlib, json=json, re=re, shlex=shlex,
                  traceback=traceback, time=types.SimpleNamespace(sleep=lambda _seconds: None),
                  steps=steps, run=run, sh=lambda label, command: run(label, ["shell", command]))
        error = None
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                exec(compiled, ns)
        except BaseException as caught:
            error = dict(type=type(caught).__name__, message=str(caught))
        fixture = json.loads((target / "fixture-restoration.json").read_text())
        detail = dict(error=error, fixture=fixture, calls=calls)
        (target / "replay.json").write_text(json.dumps(detail, indent=2) + "\n")
        assert (error is None) == expected_success
        assert fixture["status"] == expected_fixture
        assert ("launch" in [row["step"] for row in calls]) == expect_launch
        return detail

    def actual_guard():
        result = replay("actual-binding-reappeared")
        assert result["error"]["type"] == "AssertionError"
        assert result["fixture"] == json.loads((HERE / "observed-preparation/fixture-restoration.json").read_text())
        assert not (out / "actual-binding-reappeared/result.json").exists()
        return dict(prelaunch_rejected=True, exact_restoration_reproduced=True)
    check("actual_reappeared_binding_rejected_before_launch", actual_guard)

    new_pid = "9614"
    full = "\n".join(line.replace("summary started=false", "summary started=true")
                      if re.match(r"^\s*\d+\.\d+\s+9614\s", line) else line
                      for line in original.TEXT["log"].splitlines()) + "\n"
    request = next(line for line in full.splitlines() if "9614" in line and "request provider_enabled" in line)
    full = full.replace(request, request + "\n   762.700000  9614  9614 I K50GnssProbe: elapsed_ms=88 gnss_started", 1)
    synthetic = {key: original.TEXT[key] for key in (
        "identity", "final-identity", "prior-gnss-history", "new-probe-pid")}
    synthetic.update(log=full)
    synthetic["voice-binding-before-launch"] = "\n"

    def synthetic_case(name, extra=None, failed=(), expected_success=False,
                       expected_fixture="PASS", expect_launch=True, all_cleanup=False):
        values = dict(synthetic); values.update(extra or {})
        result = replay(name, values, failed, expected_success, expected_fixture, expect_launch)
        steps = [row["step"] for row in result["calls"]]
        assert "restore-home-after-gnss" in steps
        if all_cleanup:
            for label in ("restore-voice_recognition_service", "restore-voice_interaction_service",
                          "restore-search-availability", "restore-home-after-gnss"):
                assert label in steps, label
        return dict(error=result["error"], fixture=result["fixture"], steps=steps)

    check("synthetic_complete_callbacks_and_restoration", lambda: synthetic_case("complete", expected_success=True, all_cleanup=True))
    check("gps_became_active_before_launch", lambda: synthetic_case("gps-restarted", {"gps-idle-immediately-before-launch": original.TEXT["location-active"]}, expect_launch=False, all_cleanup=True))
    check("voice_implementation_did_not_stop", lambda: synthetic_case("voice-never-stopped", {"voice-service-state-0": "Active implementation\n"}, expect_launch=False))
    check("voice_clear_command_failure_restores_settings", lambda: synthetic_case("voice-clear-failed", failed=("pause-system-voice-binding",), expect_launch=False))
    check("original_binding_missing_is_rejected_before_mutation", lambda: synthetic_case("missing-original-binding", {"original-voice_interaction_service": "null\n"}, expect_launch=False))

    for name, failed in {
        "recognizer_restore_failure": ("restore-voice_recognition_service",),
        "interactor_restore_failure": ("restore-voice_interaction_service",),
        "search_restore_failure": ("restore-search-availability",),
        "home_failure": ("restore-home-after-gnss",),
        "two_restore_failures": ("restore-voice_recognition_service", "restore-search-availability"),
    }.items():
        check(name, lambda name=name, failed=failed: synthetic_case(name, failed=failed, expected_fixture="FAIL", all_cleanup=True))
    check("voice_readback_mismatch_is_visible", lambda: synthetic_case("voice-readback-mismatch", {"restored-voice_interaction_service": "different\n"}, expected_fixture="FAIL", all_cleanup=True))

    for name, value, expected_command in (
        ("absent_recognizer", "null", "settings delete secure voice_recognition_service"),
        ("empty_recognizer", "", "settings put secure voice_recognition_service ''"),
    ):
        def value_case(name=name, value=value, expected_command=expected_command):
            extra = {"original-voice_recognition_service": value + "\n", "restored-voice_recognition_service": value + "\n"}
            synthetic_case(name, extra, expected_success=True, all_cleanup=True)
            detail = json.loads((out / name / "replay.json").read_text())
            call = next(row for row in detail["calls"] if row["step"] == "restore-voice_recognition_service")
            assert call["args"] == ["shell", expected_command]
            return dict(restored_value=value, restore_command=expected_command)
        check(name, value_case)

    check("missing_started_still_rejected", lambda: synthetic_case("missing-started", {"log": original.TEXT["log"]}, all_cleanup=True))
    report = dict(status="PASS" if all(row["status"] == "PASS" for row in cases) else "FAIL",
                  passed=sum(row["status"] == "PASS" for row in cases), total=len(cases), cases=cases,
                  candidate_sha256=hashlib.sha256(text.encode()).hexdigest(),
                  try_lines=[body.lineno, body.end_lineno], source_body_modified=False,
                  process_launches=0, adb_calls=0, fixture_success_is_synthetic=True)
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("status", "passed", "total", "adb_calls")}))
    for row in cases:
        if row["status"] == "FAIL":
            print(json.dumps(row))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
