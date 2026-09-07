#!/usr/bin/env python3
"""Offline fixtures only: any attempt to launch a subprocess fails the suite."""
import ast
import copy
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wmt_source_probe", HERE / "run.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
BOOT = "11111111-2222-3333-4444-555555555555"
NEW_SHA = "1" * 64
KERNEL_SHA = "2" * 64
REVISION = "3" * 40


def manifest():
    rows = [{"path": f"/vendor/bin/offline_fixture_{n}", "sha256": "4" * 64,
             "kind": "native_source"} for n in range(28)]
    rows += [{"path": probe.LAUNCHER, "sha256": NEW_SHA, "kind": "native_source"},
             {"path": probe.MODULE, "sha256": KERNEL_SHA, "kind": "source_kernel_module"}]
    return {"status": "PASS", "kernel_revision": REVISION, "receipt_sha256": "5" * 64,
            "incremental": "offline.build19", "factory_launcher_sha256": probe.FACTORY_SHA,
            "new_native_source_paths": [probe.LAUNCHER],
            "previous_native_files_identical_to_build17": True, "rows": rows}


def inputs():
    return {"inputs": [{"repository": f"lineage-17.1/{kind}/xsh/k50sv1_64_bsp",
                        "revision": REVISION, "clean": True}
                       for kind in ("kernel", "device", "vendor")]}


def log(message, pid=410, tid=None, ns=200_123_000_000):
    """Synthetic native v4 fixture; not converted from the historical walltime case."""
    payload = b"\x04wmt_launcher\0" + message.encode() + b"\0"
    seconds, nanoseconds = divmod(ns, probe.NSEC_PER_SEC)
    return probe.LOG_HEADER.pack(len(payload), 28, pid, tid or pid, seconds, nanoseconds, 0, 1000) + payload


def startup(pid=410, session=12, result=0, records=2, ns=200_123_000_000):
    # Thread scheduling permits both power and patch-acceptance before ready.
    return (log("Power initialization completed on attempt 1", pid, pid + 1, ns)
            + log(f"Accepted srh_patch session={session} transaction=22 result={result} records={records}", pid, ns=ns)
            + log(f"Source launcher ready on session={session}", pid, ns=ns))


def clock_binding(pid=410, starttime=20000, clk_tck=100, upper_ns=210_000_000_000):
    clock = {"persist_value": "m", "ro_value": "", "clk_tck": clk_tck,
             "boot_id": BOOT, "boottime_upper_ns": upper_ns}
    return {"origin": "guarded-new-process-after-native-tail1-drain", "pid": pid, "starttime": starttime,
            "old_pid": 310, "clock_before": dict(clock), "clock_after": dict(clock),
            "discarded_history_bytes": len(log("discarded historical fixture"))}


def observed_startup(raw, pid=410, require_patch=True, **binding_args):
    return probe.startup_evidence(raw, pid, require_patch, clock_binding(pid=pid, **binding_args))


class OfflineTests(unittest.TestCase):
    def setUp(self):
        self.block_run = patch.object(probe.subprocess, "run", side_effect=AssertionError("No subprocess allowed offline"))
        self.block_popen = patch.object(probe.subprocess, "Popen", side_effect=AssertionError("No subprocess allowed offline"))
        self.block_run.start()
        self.block_popen.start()
        self.addCleanup(self.block_run.stop)
        self.addCleanup(self.block_popen.stop)

    def test_ast_and_build19_paths_without_execution(self):
        ast.parse((HERE / "run.py").read_text())
        with patch.object(probe, "Probe") as fake:
            fake.return_value.run.return_value = 0
            self.assertEqual(probe.main(["capture", "--build", "19", "--phase", "normal-reboot",
                                         "--output", "/offline/not-created"]), 0)
            args = fake.call_args.args[0]
            self.assertEqual(args.expected_manifest.name, "build19-expected-installed.json")
            self.assertEqual(args.early_dir.name, "build19-normal-reboot-early")
            self.assertEqual(args.build_inputs.name, "build19-input-update.json")
            self.assertEqual(args.readback_result.parent.name, "build19-normal-reboot-readback")

    def test_manifest_accepts_latest_clean_revision(self):
        expected = manifest()
        self.assertEqual(len(probe.validate_manifest(expected)), 30)
        self.assertEqual(len(probe.validate_build_inputs(inputs(), expected)), 3)

    def test_factory_launcher_and_duplicate_paths_rejected(self):
        expected = manifest()
        expected["rows"][-2]["sha256"] = probe.FACTORY_SHA
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_manifest(expected)
        expected = manifest()
        expected["rows"][0] = copy.deepcopy(expected["rows"][1])
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_manifest(expected)

    def test_dirty_or_different_build_inputs_rejected(self):
        value = inputs()
        value["inputs"][1]["clean"] = False
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_build_inputs(value, manifest())
        value = inputs()
        value["inputs"][0]["revision"] = "a" * 40
        with self.assertRaises(probe.ProbeFailure):
            probe.validate_build_inputs(value, manifest())

    def test_readback_binds_all_thirty_raw_hashes_and_boot(self):
        expected = manifest()
        raw = "".join(f"{r['sha256']}  {r['path']}\n" for r in expected["rows"]).encode()
        value = {"status": "PASS", "boot_id": BOOT, "receipt_sha256": expected["receipt_sha256"],
                 "rows": [{**r, "readback_sha256": r["sha256"], "matches": True} for r in expected["rows"]]}
        identity = f"{BOOT}\n{expected['incremental']}\n0\n".encode()
        probe.validate_readback(expected, value, raw, identity, BOOT)
        for bad_raw, bad_boot in ((raw.replace(NEW_SHA.encode(), b"9" * 64), BOOT),
                                  (raw, "aaaaaaaa-2222-3333-4444-555555555555"),
                                  (raw + raw.splitlines(keepends=True)[0], BOOT)):
            with self.assertRaises(probe.ProbeFailure):
                probe.validate_readback(expected, value, bad_raw, identity, bad_boot)

    def test_stat_handles_parentheses_spaces_and_starttime(self):
        tail = ["S"] + ["0"] * 18 + ["456789"] + ["0"] * 10
        value = probe.parse_stat("410 (odd (task) name) " + " ".join(tail))
        self.assertEqual(value, {"pid": 410, "starttime": 456789, "state": "S"})
        with self.assertRaises(probe.ProbeFailure):
            probe.parse_stat("1 (init) " + " ".join(tail))

    def test_startup_accepts_power_before_ready_and_patch(self):
        value = observed_startup(startup(), 410, require_patch=True)
        self.assertEqual(value["session"], 12)
        self.assertEqual(value["accepted_srh_patch"][0]["transaction"], 22)

    def test_missing_retained_startup_is_gap_not_functional_failure(self):
        with self.assertRaises(probe.EvidenceGap):
            observed_startup(b"", 410, require_patch=True)
        with self.assertRaises(probe.EvidenceGap):
            observed_startup(startup(pid=411), 410, require_patch=True)
        warm = log("Source launcher ready on session=13") + log("Power initialization completed on attempt 1")
        self.assertEqual(observed_startup(warm, 410, False)["session"], 13)
        with self.assertRaises(probe.EvidenceGap):
            observed_startup(warm, 410, True)

    def test_bound_session_parser_does_not_require_power_log(self):
        ready = log("Source launcher ready on session=14")
        self.assertEqual(probe.session_evidence(ready, 410, clock_binding())["session"], 14)
        with self.assertRaises(probe.EvidenceGap):
            observed_startup(ready, 410, False)

    def test_wrong_session_records_and_acceptance_are_not_pass(self):
        for records in (1, 0):
            with self.assertRaises(probe.ProbeFailure):
                observed_startup(startup(records=records), 410, True)
        with self.assertRaises(probe.ProbeFailure):
            observed_startup(startup(result=-22), 410, True)
        mixed = startup() + log("Source launcher ready on session=14")
        with self.assertRaises(probe.ProbeFailure):
            observed_startup(mixed, 410, True)
        with self.assertRaises(probe.EvidenceGap):
            observed_startup(startup().replace(b"srh_patch session=12", b"srh_patch session=11"), 410, True)

    def test_unchanged_stale_walltime_fixture_is_inconclusive_in_real_capture(self):
        with tempfile.TemporaryDirectory(prefix="offline-fixture-", dir=HERE) as directory:
            args = probe.parser().parse_args(["capture", "--build", "19", "--phase", "normal-reboot",
                                              "--output", str(Path(directory) / "result")])
            value = probe.Probe(args)
            current = {"pid": 410, "starttime": 20000, "tids": [410]}
            value.preflight = lambda: current
            value.early_log = (HERE / "fixtures/retained-old-process.log").read_bytes()
            value.snapshot = lambda name: current
            value.early_continuity = lambda: None
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(value.run(), 2)
            self.assertEqual(value.result["status"], "INCONCLUSIVE")
            self.assertEqual(value.result["checks"]["capture_runtime"]["status"], "PASS")
            self.assertNotIn("session", value.result["checks"]["startup_attribution"])

    def test_native_birth_bound_and_tick_units_are_conservative(self):
        for hz, ticks in ((100, 20000), (250, 50000)):
            edge = (ticks + 1) * probe.NSEC_PER_SEC // hz
            for before in (200_000_000_000, edge - 1):
                with self.assertRaises(probe.EvidenceGap):
                    observed_startup(startup(ns=before), starttime=ticks, clk_tck=hz)
            self.assertEqual(observed_startup(startup(ns=edge), starttime=ticks, clk_tck=hz)["session"], 12)
        # Suspend makes this safe bound stricter, never earlier than birth.
        with self.assertRaises(probe.EvidenceGap):
            observed_startup(startup(ns=190_100_000_000), starttime=20000)

    def test_native_clock_provenance_cannot_be_inferred_from_current_m(self):
        for data in (startup(), startup(ns=2_000_000_000), startup(ns=1_788_000_000_000_000_000)):
            with self.assertRaises(probe.EvidenceGap):
                probe.startup_evidence(data, 410, True)
            with self.assertRaises(probe.EvidenceGap):
                probe.startup_evidence(data, 410, True, {**clock_binding(), "origin": "current-properties-only"})
        for bad_clock in ({"persist_value": "realtime"}, {"clk_tck": 250}, {"boot_id": "wrong-boot"}):
            binding = clock_binding()
            binding["clock_after"].update(bad_clock)
            with self.assertRaises(probe.EvidenceGap):
                probe.startup_evidence(startup(), 410, True, binding)
        for bad_time in (2_000_000_000, 210_000_000_000, 1_788_000_000_000_000_000):
            with self.assertRaises(probe.EvidenceGap):
                observed_startup(startup(ns=bad_time))

    def test_binary_header_payload_boundaries_and_invalid_time(self):
        first = log("retained historical entry")
        second = startup()
        for length in range(len(first)):
            rows, end = probe.binary_log_records(first[:length])
            self.assertEqual((rows, end), ([], 0))
        rows, end = probe.binary_log_records(first + second[:33])
        self.assertEqual(len(rows), 1)
        self.assertEqual(end, len(first))
        self.assertEqual(len(probe.binary_log_records(first + second)[0]), 4)
        header = list(probe.LOG_HEADER.unpack(first[:28]))
        for position, invalid in ((1, 24), (5, 1_000_000_000), (6, 1)):
            changed = list(header)
            changed[position] = invalid
            with self.assertRaises(probe.EvidenceGap):
                probe.binary_log_records(probe.LOG_HEADER.pack(*changed) + first[28:])

    def test_device_clock_sample_preserves_tick_units_and_uptime_upper_edge(self):
        value = probe.Probe.__new__(probe.Probe)
        value.boot_id = BOOT
        value.result = {"commands": [{"label": "offline-clock-read"}]}
        sample = (f"persist.logd.timestamp=m\nro.logd.timestamp=\nclk_tck=100\n"
                  f"boot_id={BOOT}\nuptime=200.12 400.00\n").encode()
        value.shell = lambda *args, **kwargs: (sample, 0)
        clock = value.log_clock("offline-clock")
        self.assertTrue(probe.native_clock(clock))
        self.assertEqual(clock["clk_tck"], 100)
        self.assertEqual(clock["boottime_upper_ns"], 200_130_000_000)
        value.shell = lambda *args, **kwargs: (sample.replace(b"clk_tck=100", b"clk_tck=0"), 0)
        with self.assertRaises(probe.EvidenceGap):
            value.log_clock("offline-clock-bad-hz")

    def test_unbound_initial_session_needs_explicit_establish_without_mutations(self):
        with tempfile.TemporaryDirectory(prefix="offline-fixture-", dir=HERE) as directory:
            args = probe.parser().parse_args(["exercise", "--build", "19", "--phase", "normal-reboot",
                                              "--output", str(Path(directory) / "result")])
            value = probe.Probe(args)
            value.preflight = lambda: {"pid": 410, "starttime": 20000}
            value.property_value = lambda name: ""
            value.start_streams = lambda: self.fail("No flag must not establish a controlled boundary")
            value.restart = lambda *args, **kwargs: self.fail("No flag must not signal")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(value.run(), 2)
            self.assertFalse(value.mutated)
            self.assertEqual(value.result["cleanup"]["status"], "NOT_NEEDED")

    def test_explicit_establish_session_records_new_baseline_before_fwlog(self):
        with tempfile.TemporaryDirectory(prefix="offline-fixture-", dir=HERE) as directory:
            args = probe.parser().parse_args(["exercise", "--build", "19", "--phase", "normal-reboot",
                                              "--establish-session", "--output", str(Path(directory) / "result")])
            value = probe.Probe(args)
            value.preflight = lambda: {"pid": 410, "starttime": 20000}
            value.property_value = lambda name: ""
            calls = []
            value.start_streams = lambda: calls.append("native-boundary")
            value.local_kernel_source = lambda: None
            value.restart = lambda *args, **kwargs: (calls.append("guarded-establish") or ({"pid": 510, "starttime": 21000}, 13))
            def stop_before_fwlog(*args):
                calls.append("fwlog-after-baseline")
                raise probe.EvidenceGap("Offline fixture stops after verified branch selection")
            value.set_fwlog = stop_before_fwlog
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(value.run(), 2)
            self.assertEqual(calls, ["native-boundary", "guarded-establish", "fwlog-after-baseline"])
            self.assertEqual(value.result["checks"]["initial_observable_session"]["established_session"], 13)

    def test_final_disable_requires_old_main_tid_time_and_function(self):
        rows = [
            "6,1,12000000,-;-(0)[410:wmt_launcher][WMT-PLAT][I]wmt_plat_set_dbg_mode: fw dbg mode register value(0x00000000)",
            "6,2,12100000,-;-(0)[420:wmt_launcher][WMT-PLAT][I]wmt_plat_set_dbg_mode: fw dbg mode register value(0x00000000)",
            "6,3,12200000,-;-(0)[410:wmt_launcher][WMT-PLAT][I]other_function: fw dbg mode register value(0x00000000)",
            "6,4,12300000,-;-(0)[410:wmt_launcher][WMT-PLAT][I]wmt_plat_set_dbg_mode: fw dbg mode register value(0x00000001)",
            "6,5,14000000,-;-(0)[410:wmt_launcher][WMT-PLAT][I]wmt_plat_set_dbg_mode: fw dbg mode register value(0x00000000)",
        ]
        found = probe.kernel_mode_evidence("\n".join(rows).encode(), {410}, 11.9, 12.5, 0)
        self.assertEqual([r["sequence"] for r in found], [1])
        self.assertEqual(probe.kernel_mode_evidence(b"log unavailable", {410}, 0, 100, 0), [])

    def test_signal_guard_only_positive_verified_source_pid(self):
        command = probe.guarded_term_command({"pid": 410, "starttime": 456789}, NEW_SHA)
        self.assertIn("kill -TERM 410", command)
        self.assertIn("[ \"$1\" = 456789 ]", command)
        self.assertIn("sha256sum /proc/410/exe", command)
        self.assertNotIn("ctl.stop", command)
        self.assertNotIn("-9", command)
        for pid in (0, -410, 1, "410; false", True):
            with self.assertRaises(probe.ProbeFailure):
                probe.guarded_term_command({"pid": pid, "starttime": 456789}, NEW_SHA)
        with self.assertRaises(probe.ProbeFailure):
            probe.guarded_term_command({"pid": 410, "starttime": 456789}, probe.FACTORY_SHA)

    def test_failure_survives_finally_and_empty_property_restored(self):
        with tempfile.TemporaryDirectory(prefix="offline-fixture-", dir=HERE) as directory:
            args = probe.parser().parse_args(["exercise", "--build", "19", "--phase", "normal-reboot",
                                              "--output", str(Path(directory) / "result")])
            value = probe.Probe(args)
            calls = []
            value.preflight = lambda: {"pid": 410}
            def fail(_process):
                value.original = ""
                value.mutated = True
                raise probe.ProbeFailure("offline simulated worker timeout")
            value.exercise = fail
            value.remote = lambda name, *argv, **kwargs: (calls.append((name, argv)) or (b"\n", 0))
            value.state = lambda name: {"init.svc.wmt_launcher": "running",
                                        "vendor.connsys.formeta.ready": "yes", "pids": [510]}
            value.snapshot = lambda name: {"pid": 510, "starttime": 123456}
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(value.run(), 1)
            result = json.loads((value.out / "result.json").read_text())
            self.assertEqual(result["status"], "FAIL")
            self.assertIn("offline simulated", result["failure"]["message"])
            self.assertEqual(result["cleanup"]["status"], "PASS")
            self.assertEqual(result["cleanup"]["restored_property"], "")
            self.assertIn(("finally-restore-fwlog", ("setprop", probe.FWLOG, "")), calls)

    def test_cleanup_failure_keeps_primary_failure(self):
        with tempfile.TemporaryDirectory(prefix="offline-fixture-", dir=HERE) as directory:
            args = probe.parser().parse_args(["exercise", "--build", "19", "--phase", "normal-reboot",
                                              "--output", str(Path(directory) / "result")])
            value = probe.Probe(args)
            value.preflight = lambda: {"pid": 410}
            def fail(_process):
                value.original = "yes"
                value.mutated = True
                raise probe.ProbeFailure("primary failure")
            value.exercise = fail
            def remote_failure(*args, **kwargs):
                raise probe.ProbeFailure("offline restore failure")
            value.remote = remote_failure
            value.state = lambda name: {"init.svc.wmt_launcher": "running",
                                        "vendor.connsys.formeta.ready": "yes", "pids": [510]}
            value.snapshot = lambda name: {"pid": 510}
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(value.run(), 1)
            self.assertEqual(value.result["failure"]["message"], "primary failure")
            self.assertEqual(value.result["cleanup"]["status"], "FAIL")


if __name__ == "__main__":
    unittest.main(verbosity=2)
