#!/usr/bin/env python3
"""Independent, handset-free verification of the frozen runtime probe.

All imports/tests run with subprocess.run/Popen blocked. The only child
process used by this verifier is `sh -n` over a retained command string.
The final attribution reproducer records a known bad acceptance, separately
from passing behavioral checks, so it cannot be mistaken for runtime PASS.
"""
from __future__ import annotations

import ast
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SNAPSHOT = HERE / "f24e5657-snapshot"
SOURCE_SHA = "f24e5657c3638dd12ef0d599b1928d168dd54df5ed5a93083e4b0da04afa25d2"
sys.dont_write_bytecode = True


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    expected = json.loads((HERE / "input-sha256.json").read_text())
    for name, wanted in expected.items():
        assert sha((SNAPSHOT / name).read_bytes()) == wanted, name
    assert expected["run.py"] == SOURCE_SHA
    raw = (SNAPSHOT / "run.py").read_bytes()
    tree = ast.parse(raw, filename=str(SNAPSHOT / "run.py"))
    lines = raw.splitlines(keepends=True)
    functions = [
        {"name": node.name, "first_line": node.lineno, "last_line": node.end_lineno,
         "sha256": sha(b"".join(lines[node.lineno - 1:node.end_lineno]))}
        for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
    ]
    functions.sort(key=lambda row: row["first_line"])
    write_json(HERE / "source-functions.json", functions)

    blockers = dict(side_effect=AssertionError("Independent offline verification forbids subprocesses"))
    with patch.object(subprocess, "run", **blockers), patch.object(subprocess, "Popen", **blockers):
        author = load_module("author_offline_validation", SNAPSHOT / "offline_validate.py")
        probe = author.probe
        log = io.StringIO()
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(author.OfflineTests)
        author_result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
        (HERE / "author-fixtures-independent.log").write_text(log.getvalue())
        assert author_result.wasSuccessful()
        assert author_result.testsRun == 14

        class IndependentChecks(unittest.TestCase):
            def new_probe(self, mode="capture"):
                directory = tempfile.TemporaryDirectory(prefix="offline-", dir=HERE)
                self.addCleanup(directory.cleanup)
                args = probe.parser().parse_args([
                    mode, "--build", "19", "--phase", "normal-reboot",
                    "--output", str(Path(directory.name) / "result"),
                ])
                return probe.Probe(args)

            def run_silent(self, value):
                with contextlib.redirect_stdout(io.StringIO()):
                    return value.run()

            def make_capture(self, logs):
                value = self.new_probe()
                process = {"pid": 410, "starttime": 20000}
                value.preflight = lambda: process
                value.snapshot = lambda name: dict(process)
                value.early_log = logs
                value.early_continuity = lambda: value.check("early_log_prefix_continuity")
                return value

            def test_missing_capture_log_is_inconclusive(self):
                value = self.make_capture(b"")
                self.assertEqual(self.run_silent(value), 2)
                self.assertEqual(value.result["status"], "INCONCLUSIVE")
                self.assertEqual(value.result["checks"]["startup_attribution"]["status"], "INCONCLUSIVE")
                self.assertEqual(value.result["cleanup"]["status"], "NOT_NEEDED")

            def test_other_pid_capture_log_is_inconclusive(self):
                value = self.make_capture(author.startup(pid=409))
                self.assertEqual(self.run_silent(value), 2)

            def test_capture_identity_change_fails(self):
                value = self.make_capture(author.startup())
                value.snapshot = lambda name: {"pid": 410, "starttime": 20001}
                self.assertEqual(self.run_silent(value), 1)
                self.assertIn("restarted during capture", value.result["failure"]["message"])

            def test_capture_invalid_patch_fails(self):
                value = self.make_capture(author.startup().replace(b"result=0", b"result=-22"))
                self.assertEqual(self.run_silent(value), 1)

            def test_exercise_without_session_makes_no_mutations(self):
                value = self.new_probe("exercise")
                value.preflight = lambda: {"pid": 410, "starttime": 20000}
                value.property_value = lambda name: ""
                value.start_streams = lambda: None
                value.local_kernel_source = lambda: value.check("kernel_log_source_binding")
                value.stream_data = lambda name: b""
                value.early_log = b""
                value.set_fwlog = lambda *args: self.fail("Mutation despite missing session")
                value.restart = lambda *args, **kwargs: self.fail("Signal despite missing session")
                self.assertEqual(self.run_silent(value), 2)
                self.assertFalse(value.mutated)
                self.assertEqual(value.result["cleanup"]["status"], "NOT_NEEDED")

            def test_property_values_are_restored_exactly(self):
                for original in ("", "yes", "no", "quoted ' and spaces"):
                    with self.subTest(original=original):
                        value = self.new_probe("exercise")
                        value.mutated = True
                        value.original = original
                        calls = []
                        value.remote = lambda name, *argv, **kwargs: (calls.append((name, argv)) or (b"", 0))
                        value.property_value = lambda name: original
                        value.state = lambda name: {
                            "init.svc.wmt_launcher": "running",
                            "vendor.connsys.formeta.ready": "yes", "pids": [510],
                        }
                        value.snapshot = lambda name: {"pid": 510, "starttime": 20001}
                        value.cleanup()
                        self.assertEqual(value.result["cleanup"]["status"], "PASS")
                        self.assertEqual(value.result["cleanup"]["restored_property"], original)
                        self.assertIn(("finally-restore-fwlog", ("setprop", probe.FWLOG, original)), calls)

            def test_cleanup_failure_overrides_success(self):
                value = self.make_capture(author.startup())
                def cleanup_failure():
                    raise probe.ProbeFailure("synthetic cleanup failure")
                value.cleanup = cleanup_failure
                self.assertEqual(self.run_silent(value), 1)
                self.assertEqual(value.result["cleanup"]["status"], "FAIL")

            def test_cleanup_failure_retains_evidence_gap(self):
                value = self.new_probe()
                def preflight_gap():
                    raise probe.EvidenceGap("synthetic missing evidence")
                def cleanup_failure():
                    raise probe.ProbeFailure("synthetic cleanup failure")
                value.preflight = preflight_gap
                value.cleanup = cleanup_failure
                self.assertEqual(self.run_silent(value), 1)
                self.assertEqual(value.result["evidence_gap"], "synthetic missing evidence")
                self.assertEqual(value.result["cleanup"]["status"], "FAIL")

            def test_wait_threads_rejects_reused_pid(self):
                value = self.new_probe("exercise")
                process = {"pid": 410, "starttime": 20000}
                value.state = lambda name: {"pids": [410]}
                value.healthy = lambda state: None
                stat = "410 (wmt_launcher) " + " ".join(["S"] + ["0"] * 18 + ["20001"] + ["0"] * 10)
                value.remote = lambda *args, **kwargs: (stat.encode(), 0)
                with self.assertRaisesRegex(probe.ProbeFailure, "PID was reused"):
                    value.wait_threads(process, "synthetic-worker", lambda tids: True)

            def test_signal_guard_rejects_noninteger_starttime(self):
                for starttime in (True, False, 0, -1, "20000", 20000.0):
                    with self.subTest(starttime=starttime):
                        with self.assertRaises(probe.ProbeFailure):
                            probe.guarded_term_command({"pid": 410, "starttime": starttime}, author.NEW_SHA)

        independent_log = io.StringIO()
        independent_suite = unittest.defaultTestLoader.loadTestsFromTestCase(IndependentChecks)
        independent_result = unittest.TextTestRunner(stream=independent_log, verbosity=2).run(independent_suite)
        (HERE / "independent-fixtures.log").write_text(independent_log.getvalue())
        assert independent_result.wasSuccessful()

        reproduction = HERE / "stale-pid-reproducer"
        reproduction.mkdir(exist_ok=False)
        args = probe.parser().parse_args([
            "capture", "--build", "19", "--phase", "normal-reboot", "--output", str(reproduction / "probe-output"),
        ])
        value = probe.Probe(args)
        # The truth fixture assigns two distinct process instances PID 410.
        # Retained logs occurred at 03:10:02; the current process was born at
        # 03:13:20 on the same boot (03:10:00 epoch, HZ=100, starttime=20000).
        process = {"pid": 410, "starttime": 20000}
        logs = author.startup(pid=410, session=12)
        (reproduction / "retained-old-process.log").write_bytes(logs)
        value.preflight = lambda: dict(process)
        value.snapshot = lambda name: dict(process)
        value.early_log = logs
        value.early_continuity = lambda: value.check("early_log_prefix_continuity")
        with contextlib.redirect_stdout(io.StringIO()):
            observed_rc = value.run()
        stale_result = {
            "finding": "Initial capture accepts retained logs from a previous instance of the same PID",
            "source_sha256": SOURCE_SHA,
            "fixture_truth": {
                "same_boot": True, "boot_wall_time": "2026-09-07T03:10:00Z", "clock_ticks_per_second": 100,
                "retained_log_wall_time": "2026-09-07T03:10:02.123Z",
                "retired_process": {"pid": 410, "starttime": 50, "session": 12},
                "current_process": {**process, "session": 13, "birth_wall_time": "2026-09-07T03:13:20Z"},
                "current_process_startup_logs": "not retained",
            },
            "adapters": ["preflight/snapshot return a stable, valid current identity", "early prefix continuity succeeds"],
            "actual_production_functions": ["Probe.run", "Probe.capture", "startup_evidence", "session_evidence", "launcher_records", "Probe.cleanup"],
            "actual_exit_code": observed_rc,
            "actual_status": value.result["status"],
            "actual_attributed_session": value.result["checks"]["startup_attribution"]["session"],
            "expected_status": "INCONCLUSIVE: retained logs predate the current process",
            "reproduced_false_pass": observed_rc == 0 and value.result["status"] == "PASS",
            "adb_executed": False,
        }
        assert stale_result["reproduced_false_pass"]
        write_json(reproduction / "reproduction.json", stale_result)

    syntax_command = ["sh", "-n", str(SNAPSHOT / "offline-signal-command.sh.txt")]
    syntax = subprocess.run(syntax_command, capture_output=True, check=False)
    (HERE / "shell-syntax.stdout").write_bytes(syntax.stdout)
    (HERE / "shell-syntax.stderr").write_bytes(syntax.stderr)
    assert syntax.returncode == 0
    result = {
        "verification_status": "PASS_WITH_REPRODUCED_FINDING", "source_sha256": SOURCE_SHA,
        "verified_inputs": expected, "author_tests_passed": author_result.testsRun,
        "independent_tests_passed": independent_result.testsRun, "subprocesses_blocked_during_tests": True,
        "shell_syntax_argv": syntax_command, "shell_syntax_exit_code": syntax.returncode,
        "ast_status": "PASS", "source_function_records": len(functions),
        "reproduced_false_pass": True, "adb_executed": False,
        "scope": "Offline parser/control/cleanup verification; no handset results are claimed",
    }
    write_json(HERE / "offline-independent-result.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
