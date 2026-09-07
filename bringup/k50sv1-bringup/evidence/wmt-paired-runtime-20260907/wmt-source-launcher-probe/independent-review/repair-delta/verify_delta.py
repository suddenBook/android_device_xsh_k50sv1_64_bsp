#!/usr/bin/env python3
"""Offline delta review; all device/process effects are blocked or explicit mocks."""
from __future__ import annotations

import argparse
import ast
import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
SNAPSHOT = HERE / "c60e1cf9-snapshot"
ORIGINAL = HERE.parent / "f24e5657-snapshot"
BOOT = "11111111-2222-3333-4444-555555555555"
SHA = "1" * 64
NS = 1_000_000_000
sys.dont_write_bytecode = True


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def save(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def frame(message, pid=510, tid=510, ns=200_123_000_000, priority=4, tag="wmt_launcher"):
    # Independently encode the primary-source v4 ABI, without using candidate constants.
    payload = bytes([priority]) + tag.encode() + b"\0" + message.encode() + b"\0"
    seconds, nanoseconds = divmod(ns, NS)
    return struct.pack("<HHiIIIII", len(payload), 28, pid, tid, seconds, nanoseconds, 0, 1000) + payload


def fresh_startup(ns=200_123_000_000):
    return (frame("Power initialization completed on attempt 1", tid=511, ns=ns)
            + frame("Accepted srh_patch session=13 transaction=31 result=0 records=2", ns=ns)
            + frame("Source launcher ready on session=13", ns=ns))


def clock(ticks=100, upper=201_000_000_000):
    return {"persist_value": "m", "ro_value": "", "clk_tck": ticks,
            "boot_id": BOOT, "boottime_upper_ns": upper, "command_label": "mocked-clock-read"}


def binding(ticks=100, starttime=20000, upper=201_000_000_000):
    return {"origin": "guarded-new-process-after-native-tail1-drain", "pid": 510,
            "old_pid": 410, "starttime": starttime, "clock_before": clock(ticks, upper),
            "clock_after": clock(ticks, upper), "discarded_history_bytes": len(frame("history"))}


def function_records(raw):
    lines = raw.splitlines(keepends=True)
    tree = ast.parse(raw)
    return {node.name: {"first_line": node.lineno, "last_line": node.end_lineno,
                        "sha256": digest(b"".join(lines[node.lineno - 1:node.end_lineno]))}
            for node in ast.walk(tree) if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="New child directory name under this verifier")
    args = parser.parse_args()
    if not args.output or Path(args.output).name != args.output or args.output in (".", ".."):
        parser.error("--output must be one new child directory name")
    out = HERE / args.output
    out.mkdir(exist_ok=False)

    inputs = json.loads((HERE / "candidate-input-sha256.json").read_text())
    for name, wanted in inputs["source_sha256"].items():
        assert digest((SNAPSHOT / name).read_bytes()) == wanted, name
    old_functions = function_records((ORIGINAL / "run.py").read_bytes())
    new_functions = function_records((SNAPSHOT / "run.py").read_bytes())
    delta = {
        "original": old_functions, "candidate": new_functions,
        "added": sorted(set(new_functions) - set(old_functions)),
        "removed": sorted(set(old_functions) - set(new_functions)),
        "changed": sorted(name for name in old_functions.keys() & new_functions.keys()
                          if old_functions[name]["sha256"] != new_functions[name]["sha256"]),
        "unchanged": sorted(name for name in old_functions.keys() & new_functions.keys()
                            if old_functions[name]["sha256"] == new_functions[name]["sha256"]),
    }
    save(out / "function-delta.json", delta)
    blockers = dict(side_effect=AssertionError("No real process launch is allowed in review fixtures"))
    with patch.object(subprocess, "run", **blockers), patch.object(subprocess, "Popen", **blockers):
        author = load("candidate_author_fixtures", SNAPSHOT / "offline_validate.py")
        candidate = author.probe
        original = load("original_frozen_probe", ORIGINAL / "run.py")
        author_log = io.StringIO()
        author_result = unittest.TextTestRunner(stream=author_log, verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(author.OfflineTests))
        (out / "author-fixtures.log").write_text(author_log.getvalue())
        assert author_result.wasSuccessful() and author_result.testsRun == 21

        # Re-run the exact original input through both unchanged production capture flows.
        stale = (HERE.parent / "stale-pid-reproducer/retained-old-process.log").read_bytes()
        assert stale == (SNAPSHOT / "fixtures/retained-old-process.log").read_bytes()
        (out / "original-stale-input.log").write_bytes(stale)
        reproductions = []
        for label, module in (("original", original), ("candidate", candidate)):
            parsed = module.parser().parse_args([
                "capture", "--build", "19", "--phase", "normal-reboot", "--output", str(out / (label + "-capture")),
            ])
            value = module.Probe(parsed)
            current = {"pid": 410, "starttime": 20000}
            value.preflight = lambda: dict(current)
            value.snapshot = lambda name: dict(current)
            value.early_log = stale
            value.early_continuity = lambda: value.check("early_log_prefix_continuity")
            with contextlib.redirect_stdout(io.StringIO()):
                code = value.run()
            reproductions.append({"version": label, "source_sha256": value.result["probe_script_sha256"],
                                  "exit_code": code, "status": value.result["status"],
                                  "startup": value.result["checks"]["startup_attribution"],
                                  "runtime": value.result["checks"]["capture_runtime"]})
        assert reproductions[0]["exit_code"] == 0 and reproductions[0]["startup"]["session"] == 12
        assert reproductions[1]["exit_code"] == 2 and reproductions[1]["status"] == "INCONCLUSIVE"
        assert "session" not in reproductions[1]["startup"]
        assert reproductions[1]["runtime"]["status"] == "PASS"
        save(out / "original-finding-closure.json", {
            "finding": "RTP-1", "status": "CLOSED", "fixture_sha256": digest(stale),
            "fixture_unchanged": True, "adapters": ["stable valid preflight/snapshot", "same log-prefix continuity success"],
            "results": reproductions, "adb_executed": False,
        })

        class DeltaChecks(unittest.TestCase):
            def new_probe(self, name):
                parsed = candidate.parser().parse_args([
                    "exercise", "--build", "19", "--phase", "normal-reboot", "--establish-session",
                    "--timeout", "5", "--output", str(out / name),
                ])
                value = candidate.Probe(parsed)
                value.boot_id = BOOT
                return value

            def test_complete_frame_boundaries_at_every_byte(self):
                chunks = [frame("history"), frame("Source launcher ready on session=13"),
                          frame("Power initialization completed on attempt 1", tid=511)]
                raw = b"".join(chunks)
                ends = [sum(map(len, chunks[:count])) for count in range(1, len(chunks) + 1)]
                for length in range(len(raw) + 1):
                    rows, end = candidate.binary_log_records(raw[:length])
                    complete = [edge for edge in ends if edge <= length]
                    self.assertEqual(len(rows), len(complete), length)
                    self.assertEqual(end, max(complete, default=0), length)
                self.assertEqual(candidate.binary_log_records(raw)[0][1]["message"],
                                 "Source launcher ready on session=13")

            def test_malformed_native_records_are_not_evidence(self):
                valid = frame("Source launcher ready on session=13")
                header = list(struct.unpack("<HHiIIIII", valid[:28]))
                for index, invalid in ((0, 2), (0, 4069), (1, 24), (5, NS), (6, 1)):
                    changed = list(header)
                    changed[index] = invalid
                    with self.subTest(index=index, invalid=invalid):
                        with self.assertRaises(candidate.EvidenceGap):
                            candidate.binary_log_records(struct.pack("<HHiIIIII", *changed) + valid[28:])
                for malformed in (valid[:-1] + b"x", valid[:28] + b"\x01" + valid[29:]):
                    with self.assertRaises(candidate.EvidenceGap):
                        candidate.binary_log_records(malformed)

            def test_effective_clock_uses_persist_precedence(self):
                for values, expected in (({"persist_value": "", "ro_value": "M"}, True),
                                         ({"persist_value": "r", "ro_value": "m"}, False),
                                         ({"persist_value": "m", "ro_value": "r"}, True),
                                         ({"persist_value": True, "ro_value": "m"}, False),
                                         ({}, False)):
                    self.assertEqual(candidate.native_clock(values), expected)

            def test_integer_birth_and_upper_edges(self):
                for hz in (100, 125, 250, 1000):
                    ticks = 200 * hz
                    edge = (ticks + 1) * NS // hz
                    source = binding(ticks=hz, starttime=ticks)
                    with self.assertRaises(candidate.EvidenceGap):
                        candidate.startup_evidence(fresh_startup(edge - 1), 510, True, source)
                    self.assertEqual(candidate.startup_evidence(fresh_startup(edge), 510, True, source)["session"], 13)
                    upper = source["clock_after"]["boottime_upper_ns"]
                    self.assertEqual(candidate.startup_evidence(fresh_startup(upper - 1), 510, True, source)["session"], 13)
                    with self.assertRaises(candidate.EvidenceGap):
                        candidate.startup_evidence(fresh_startup(upper), 510, True, source)

            def test_stale_and_epoch_records_do_not_poison_fresh_session(self):
                raw = (frame("Source launcher ready on session=12", ns=190 * NS)
                       + frame("Accepted srh_patch session=13 transaction=21 result=-22 records=0", ns=190 * NS)
                       + frame("Source launcher ready on session=99", ns=1_788_000_000 * NS)
                       + fresh_startup())
                value = candidate.startup_evidence(raw, 510, True, binding())
                self.assertEqual(value["session"], 13)
                self.assertEqual([item["transaction"] for item in value["accepted_srh_patch"]], [31])
                self.assertTrue(all(item["monotonic_ns"] == 200_123_000_000
                                    for item in value["power"] + value["accepted_srh_patch"] + [value["ready"]]))

            def test_clock_and_boundary_provenance_are_required(self):
                invalid = [None, {**binding(), "origin": "current-properties-only"},
                           {**binding(), "old_pid": 510}, {**binding(), "discarded_history_bytes": 27}]
                for field, replacement in (("persist_value", "r"), ("clk_tck", 250), ("boot_id", "another-boot")):
                    value = binding()
                    value["clock_after"][field] = replacement
                    invalid.append(value)
                for source in invalid:
                    with self.assertRaises(candidate.EvidenceGap):
                        candidate.startup_evidence(fresh_startup(), 510, True, source)

            def test_multiline_payload_cannot_create_multiple_startup_records(self):
                raw = frame("Source launcher ready on session=13\nPower initialization completed on attempt 1")
                with self.assertRaises(candidate.EvidenceGap):
                    candidate.startup_evidence(raw, 510, False, binding())

            def test_native_reader_waits_for_full_history_and_cleans_both_handles(self):
                value = self.new_probe("native-reader-mocked")
                history = frame("discarded historical entry", pid=410, tid=410, ns=1_788_000_000 * NS)
                pieces = [history[:27], history[27:28], history[28:-1], history[-1:] + b"\x01\x00\x1c"]
                launched = []
                handles = {}
                sleep_calls = []

                class FakeProcess:
                    def __init__(self, pid):
                        self.pid = pid
                        self.code = None
                    def poll(self):
                        return self.code
                    def terminate(self):
                        self.code = -15
                    def wait(self, timeout):
                        return self.code

                def fake_popen(argv, env, stdout, stderr):
                    launched.append(argv)
                    self.assertIsNot(stdout, stderr)
                    if "logcat" in argv:
                        self.assertEqual(argv[-6:], ["logcat", "-B", "-b", "main", "-T", "1"])
                        stdout.write(pieces.pop(0))
                        stdout.flush()
                        handles["logcat"] = stdout
                    return FakeProcess(900000 + len(launched))

                def advance(_seconds):
                    sleep_calls.append(_seconds)
                    self.assertTrue(pieces, "Unexpected extra poll")
                    handles["logcat"].write(pieces.pop(0))
                    handles["logcat"].flush()

                value.log_clock = lambda name: clock()
                with patch.object(candidate.subprocess, "Popen", side_effect=fake_popen), \
                        patch.object(candidate.time, "sleep", side_effect=advance):
                    value.start_streams()
                    self.assertEqual(len(sleep_calls), 3)
                    self.assertEqual(value.logcat_drained_prefix, history)
                    self.assertEqual(value.discarded_history_bytes, len(history))
                    self.assertFalse(value.mutated)
                    value.cleanup()
                self.assertEqual(len(launched), 2)
                self.assertEqual(value.result["cleanup"]["status"], "NOT_NEEDED")
                self.assertEqual(len(value.result["cleanup"]["streams"]), 2)
                self.assertTrue(all(handle.closed and error.closed for _, _, handle, error in value.streams))

            def test_non_native_clock_stops_before_readers_or_mutations(self):
                value = self.new_probe("non-native-clock-mocked")
                value.log_clock = lambda name: {**clock(), "persist_value": "r"}
                with self.assertRaises(candidate.EvidenceGap):
                    value.start_streams()
                self.assertEqual(value.streams, [])
                self.assertFalse(value.mutated)
                value.cleanup()

            def test_actual_restart_builds_binding_at_complete_frame_boundary(self):
                value = self.new_probe("restart-flow-mocked")
                old = {"pid": 410, "starttime": 18000, "sha256": SHA}
                new = {"pid": 510, "starttime": 20000, "sha256": SHA}
                history = frame("history", pid=410, tid=410, ns=180 * NS)
                partial_record = frame("Source launcher ready on session=12", ns=190 * NS)
                before = history + partial_record[:29]
                after = history + partial_record + fresh_startup()
                signalled = []
                value.logcat_drained_prefix = history
                value.discarded_history_bytes = len(history)
                value.preflight = lambda: dict(old)
                value.snapshot = lambda name: dict(old if name.endswith("-before") else new)
                value.log_clock = lambda name: clock()
                value.stream_data = lambda name: after if signalled else before
                value.state = lambda name: {
                    "pids": [510], "uptime_seconds": 200.13,
                    "init.svc.wmt_launcher": "running", "vendor.connsys.formeta.ready": "yes",
                }
                value.property_value = lambda name: ""
                def shell(name, command, **kwargs):
                    self.assertIn("kill -TERM 410", command)
                    self.assertIn('"$1" = 18000', command)
                    signalled.append(command)
                    return b"", 0
                value.shell = shell
                def remote(name, *argv, **kwargs):
                    if name.endswith("-old-stat"):
                        return b"", 1
                    self.assertEqual(argv, ("setprop", candidate.FWLOG, ""))
                    return b"", 0
                value.remote = remote
                def exercise(process):
                    value.original = ""
                    replacement, session = value.restart(process, 12, "mocked-restart", False)
                    self.assertEqual((replacement, session), (new, 13))
                value.exercise = exercise
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(value.run(), 0)
                proof = value.result["checks"]["mocked-restart"]["startup"]["clock_binding"]
                self.assertEqual(proof["pid"], 510)
                self.assertEqual(proof["starttime"], 20000)
                self.assertEqual(proof["old_pid"], 410)
                self.assertEqual(proof["controlled_prefix_bytes"], len(history))
                self.assertEqual((value.out / "mocked-restart-new-process-logcat.bin").read_bytes(),
                                 partial_record + fresh_startup())
                self.assertEqual(value.result["cleanup"]["restored_property"], "")
                self.assertEqual(value.result["cleanup"]["status"], "PASS")

        delta_log = io.StringIO()
        delta_result = unittest.TextTestRunner(stream=delta_log, verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromTestCase(DeltaChecks))
        (out / "independent-delta-fixtures.log").write_text(delta_log.getvalue())
        assert delta_result.wasSuccessful()

    syntax_argv = ["sh", "-n", str(SNAPSHOT / "offline-signal-command.sh.txt")]
    syntax = subprocess.run(syntax_argv, capture_output=True, check=False)
    (out / "shell-syntax.stdout").write_bytes(syntax.stdout)
    (out / "shell-syntax.stderr").write_bytes(syntax.stderr)
    assert syntax.returncode == 0
    result = {
        "status": "PASS", "finding_RTP1": "CLOSED", "candidate_inputs": inputs,
        "author_fixtures_passed": author_result.testsRun, "independent_delta_fixtures_passed": delta_result.testsRun,
        "original_input_replayed_byte_identically": True, "original_exit_code": 0, "candidate_exit_code": 2,
        "source_functions_original": len(old_functions), "source_functions_candidate": len(new_functions),
        "changed_functions": delta["changed"], "added_functions": delta["added"],
        "unchanged_functions_count": len(delta["unchanged"]), "ast_status": "PASS",
        "real_process_launches_blocked_in_fixtures": True, "explicit_popen_mock_for_native_reader_only": True,
        "shell_syntax_argv": syntax_argv, "shell_syntax_exit_code": syntax.returncode,
        "adb_executed": False, "runtime_claims": False,
        "limits": ["Synthetic host verification and explicit device adapters only; no handset outcome is established.",
                   "The conservative clock rule deliberately leaves initial capture attribution and uncertain births INCONCLUSIVE."],
    }
    save(out / "result.json", result)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
