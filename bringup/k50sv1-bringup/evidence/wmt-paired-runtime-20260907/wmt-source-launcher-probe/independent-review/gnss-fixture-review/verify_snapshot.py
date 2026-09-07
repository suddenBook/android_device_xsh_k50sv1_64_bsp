#!/usr/bin/env python3
"""Run frozen GNSS control flow with retained/mock I/O; no process launches."""
import argparse
import ast
import contextlib
import hashlib
import io
import json
from pathlib import Path
import re
import shlex
import sys
import types

HERE = Path(__file__).resolve().parent
SNAPSHOT = HERE / "snapshot"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def no_process(event, _args):
    if event.startswith("subprocess.") or event in {"os.system", "os.exec", "os.posix_spawn"}:
        raise RuntimeError("Process launches are forbidden in this review: " + event)


def assigned(node, name):
    return isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == name for target in node.targets
    )


def source_blocks():
    path = SNAPSHOT / "run-build19-gnss.py"
    tree = ast.parse(path.read_text(), str(path))
    main = next(node for node in tree.body if isinstance(node, ast.Try))
    records = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                   and node.name == "gnss_records")
    prefix = [node for node in tree.body if any(assigned(node, name) for name in
              ("search_restore_required", "search_component", "log_arguments"))]
    compiled = compile(ast.Module(body=prefix + [records, main], type_ignores=[]), str(path), "exec")
    finish_path = SNAPSHOT / "finish-build19-runtime.py"
    finish = ast.parse(finish_path.read_text(), str(finish_path)).body
    first = next(i for i, node in enumerate(finish) if assigned(node, "launcher_pids"))
    last = next(i for i, node in enumerate(finish) if assigned(node, "reference"))
    final_compiled = compile(ast.Module(body=finish[first:last], type_ignores=[]), str(finish_path), "exec")
    return compiled, final_compiled, dict(
        gnss_try_lines=[main.lineno, main.end_lineno],
        finish_source_check_lines=[finish[first].lineno, finish[last - 1].end_lineno],
        source_bodies_modified=False)


GNSS, FINAL, BLOCKS = source_blocks()
CAPTURE = SNAPSHOT / "runtime/build19-gnss"
TEXT = {path.stem: path.read_text(errors="replace") for path in CAPTURE.glob("*.txt")}


def replay(out, trial, overrides=None, fail_step=None):
    out.mkdir()
    values = dict(TEXT)
    values.update(overrides or {})
    calls, steps = [], []

    def run(name, args):
        calls.append(dict(step=name, args=args))
        steps.append(dict(step=name, exit_code=1 if name == fail_step else 0))
        if name == fail_step:
            raise RuntimeError("Injected command failure at " + name)
        key = name if name in values else "gps-idle-observation-0" if name.startswith("gps-idle-observation-") else name
        assert key in values, "No retained response for " + name
        return values[key]

    namespace = dict(trial=trial, out=out, hashlib=hashlib, json=json, re=re,
                     shlex=shlex, time=types.SimpleNamespace(sleep=lambda _duration: None),
                     steps=steps, run=run, sh=lambda name, command: run(name, ["shell", command]))
    error = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(GNSS, namespace)
    except BaseException as caught:
        error = dict(type=type(caught).__name__, message=str(caught))
    fixture = json.loads((out / "fixture-restoration.json").read_text())
    detail = dict(error=error, fixture=fixture, calls=calls)
    (out / "replay.json").write_text(json.dumps(detail, indent=2) + "\n")
    return detail


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    out = (HERE / args.output).resolve()
    assert out.parent == HERE
    out.mkdir(exist_ok=False)
    sys.addaudithook(no_process)
    trial = out / "retained-fixture"
    for relative, data in {
        "gnss-probe/gnss-probe.apk": (SNAPSHOT / "gnss-probe/gnss-probe.apk").read_bytes(),
        "runtime/build19-normal-reboot-early/continuous-kmsg.txt": (CAPTURE / "kernel-interval.txt").read_bytes(),
    }.items():
        path = trial / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    cases = []

    def check(name, function):
        try:
            detail = function()
            cases.append(dict(name=name, status="PASS", detail=detail))
        except BaseException as error:
            cases.append(dict(name=name, status="FAIL", error=repr(error)))

    def integrity():
        manifest = json.loads((HERE / "snapshot-sha256.json").read_text())
        for row in manifest["rows"]:
            data = (SNAPSHOT / row["snapshot"]).read_bytes()
            assert len(data) == row["bytes"] and digest(data) == row["sha256"]
        return dict(files=manifest["files"])
    check("snapshot_integrity", integrity)

    def actual_capture():
        target = out / "actual-capture"
        result = replay(target, trial)
        assert result["error"] == dict(type="AssertionError", message="")
        assert result["fixture"] == dict(status="PASS", search_restore_required=True)
        assert [row["step"] for row in result["calls"]][-3:] == [
            "restore-search-availability", "search-package-restored", "restore-home-after-gnss"]
        for name in ("result.json", "log-history-boundary.json", "new-run-log.txt", "kernel-interval.txt"):
            assert (target / name).read_bytes() == (CAPTURE / name).read_bytes(), name
        return dict(rejected=True, restoration_passed=True, reproduced_files=4)
    check("actual_missing_started_capture_rejected_and_restored", actual_capture)

    # Synthetic complete callbacks test control flow; they are not device evidence.
    full = "\n".join(
        line.replace("summary started=false", "summary started=true")
        if re.match(r"^\s*\d+\.\d+\s+9614\s", line) else line
        for line in TEXT["log"].splitlines()
    ) + "\n"
    request = next(line for line in full.splitlines() if "9614" in line and "request provider_enabled" in line)
    full = full.replace(request, request + "\n   762.700000  9614  9614 I K50GnssProbe: elapsed_ms=88 gnss_started", 1)

    def expected_case(name, overrides=None, fail_step=None, expect_success=False,
                      expect_restore=True, expect_fixture="PASS", no_launch=False):
        values = dict(log=full)
        values.update(overrides or {})
        result = replay(out / name, trial, values, fail_step)
        assert (result["error"] is None) == expect_success
        assert result["fixture"]["status"] == expect_fixture
        steps = [row["step"] for row in result["calls"]]
        assert ("restore-search-availability" in steps) == expect_restore
        if no_launch:
            assert "launch" not in steps
        if expect_fixture == "PASS":
            assert "restore-home-after-gnss" in steps
        return dict(rejected=result["error"] is not None,
                    restoration_status=result["fixture"]["status"],
                    home_attempted="restore-home-after-gnss" in steps)

    check("synthetic_complete_callbacks", lambda: expected_case("complete", expect_success=True))
    check("history_prefix_changed", lambda: expected_case("prefix-change", dict(log=full.replace("elapsed_ms=", "elapsed_changed=", 1))))
    check("old_history_only", lambda: expected_case("old-history-only", dict(log=TEXT["prior-gnss-history"])))
    check("wrong_new_pid", lambda: expected_case("wrong-pid", {"new-probe-pid": "9999\n"}))
    check("multiple_new_pids", lambda: expected_case("multiple-pids", {"new-probe-pid": "9614 9999\n"}))
    check("old_process_still_present", lambda: expected_case("old-present", {"old-probe-process-absent": "4567\n"}, no_launch=True))
    check("ambiguous_component_before_pause", lambda: expected_case("resolver", {"search-launcher-component": "android/com.android.internal.app.ResolverActivity\n"}, expect_restore=False, no_launch=True))
    check("preflight_failure_before_pause", lambda: expected_case("preflight-failure", fail_step="search-package-before", expect_restore=False, no_launch=True))
    check("failure_after_force_stop", lambda: expected_case("after-stop-failure", fail_step="reset-old-probe-process", no_launch=True))
    check("idle_timeout", lambda: expected_case("idle-timeout", {"gps-idle-observation-0": TEXT["gps-idle-observation-0"].replace("mStarted=false", "mStarted=true")}, no_launch=True))
    check("original_search_stopped_true", lambda: expected_case("original-stopped", {"search-package-before": TEXT["search-package-before"].replace("stopped=false", "stopped=true")}, expect_success=True, expect_restore=False))
    check("search_restore_command_failure_visible", lambda: expected_case("search-restore-failure", fail_step="restore-search-availability", expect_fixture="FAIL"))
    check("search_restore_readback_failure_visible", lambda: expected_case("search-readback-failure", {"search-package-restored": TEXT["search-package-restored"].replace("stopped=false", "stopped=true")}, expect_fixture="FAIL"))
    check("home_failure_visible", lambda: expected_case("home-failure", fail_step="restore-home-after-gnss", expect_fixture="FAIL"))

    final_values = {
        "final-source-launcher-pids": "500\n", "final-source-launcher-ready": "running\nyes\nyes\n",
        "final-source-launcher-exe": "/vendor/bin/wmt_launcher\n", "final-source-launcher-tids": "500\n",
        "final-fwlog-property": "\n", "final-source-launcher-stable-pid": "500\n",
    }

    def final_case(overrides=None, success=False):
        values = dict(final_values); values.update(overrides or {})
        ns = dict(shell=lambda name, _command: values[name], launcher_exercise=dict(original_fwlog_property=""))
        error = None
        try:
            exec(FINAL, ns)
        except BaseException as caught:
            error = repr(caught)
        assert (error is None) == success
        return dict(accepted=error is None)
    check("final_source_checks_accept_valid_snapshot", lambda: final_case(success=True))
    for name, values in {
        "missing_pid": {"final-source-launcher-pids": ""},
        "multiple_pids": {"final-source-launcher-pids": "500 501\n"},
        "reserved_pid": {"final-source-launcher-pids": "1\n"},
        "not_ready": {"final-source-launcher-ready": "running\nno\nyes\n"},
        "wrong_executable": {"final-source-launcher-exe": "/system/bin/wmt_launcher\n"},
        "remaining_worker": {"final-source-launcher-tids": "500 501\n"},
        "fwlog_not_restored": {"final-fwlog-property": "yes\n"},
        "pid_changed": {"final-source-launcher-stable-pid": "501\n"},
    }.items():
        check("final_source_checks_reject_" + name, lambda values=values: final_case(values))

    report = dict(status="PASS" if all(row["status"] == "PASS" for row in cases) else "FAIL",
                  passed=sum(row["status"] == "PASS" for row in cases), total=len(cases),
                  cases=cases, blocks=BLOCKS, adb_calls=0, process_launches=0,
                  limitation="The successful GNSS fixture is explicitly synthetic; the retained real run is expected to fail its missing-start assertion. Full live collection and final-runtime mutations are not executed.")
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("status", "passed", "total", "adb_calls")}))
    for row in cases:
        if row["status"] == "FAIL":
            print(json.dumps(row))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
