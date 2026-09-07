#!/usr/bin/env python3
"""Evidence collector for a frozen source-launcher build (build18 schema, build19+).

Importing this module performs no I/O. Only main() may contact the handset.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import struct
import subprocess
import time
import traceback


TRIAL = Path(__file__).resolve().parent.parent
LAUNCHER = "/vendor/bin/wmt_launcher"
MODULE = "/vendor/lib/modules/wmt_drv.ko"
FWLOG = "persist.vendor.connsys.fwlog.status"
FACTORY_SHA = "70b5224af4276eef4a27a405919e5a147b24739569b3a24f5ee1cb8d3cd9a2a7"
PROPERTIES = (
    "ro.build.version.incremental", "sys.boot_completed",
    "vendor.connsys.driver.ready", "vendor.connsys.formeta.ready",
    "init.svc.wmt_loader", "init.svc.wmt_launcher",
)
SHA_RE = re.compile(r"[0-9a-f]{64}\Z")
BOOT_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")
NSEC_PER_SEC = 1_000_000_000
LOG_HEADER = struct.Struct("<HHiIIIII")  # Android Q logger_entry_v4, 28 bytes.
READY_RE = re.compile(r"Source launcher ready on session=(\d+)\Z")
PATCH_RE = re.compile(
    r"Accepted srh_patch session=(\d+) transaction=(\d+) result=(-?\d+) records=(\d+)\Z"
)
POWER_RE = re.compile(r"Power initialization completed on attempt (\d+)\Z")
KMSG_RE = re.compile(r"^\d+,(?P<seq>\d+),(?P<us>\d+),[^;]*;(?P<message>.*)$")
TASK_RE = re.compile(r"\[(\d+):([^]]+)\]")
MODE_RE = re.compile(r"fw dbg mode register value\(0x([0-9a-fA-F]{8})\)")


class ProbeFailure(RuntimeError):
    pass


class EvidenceGap(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise ProbeFailure(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def parse_stat(raw):
    text = raw.decode() if isinstance(raw, bytes) else raw
    head, sep, tail = text.rpartition(") ")
    require(bool(sep) and " (" in head, "Malformed /proc stat")
    fields = tail.split()
    require(len(fields) >= 20, "Short /proc stat")
    pid = int(head.split(" (", 1)[0])
    starttime = int(fields[19])
    require(pid > 1 and starttime > 0, "Invalid process identity")
    return {"pid": pid, "starttime": starttime, "state": fields[0]}


def parse_hashes(raw):
    result = {}
    for line in raw.decode().splitlines():
        fields = line.split()
        require(len(fields) == 2 and SHA_RE.fullmatch(fields[0]), "Malformed sha256sum")
        require(fields[1] not in result, "Duplicate sha256sum path")
        result[fields[1]] = fields[0]
    return result


def validate_manifest(data):
    require(data.get("status") == "PASS", "Expected manifest is not PASS")
    require(re.fullmatch(r"[0-9a-f]{40}", str(data.get("kernel_revision", ""))),
            "Missing frozen kernel revision")
    require(SHA_RE.fullmatch(str(data.get("receipt_sha256", ""))), "Invalid receipt SHA")
    require(data.get("incremental"), "Missing build incremental")
    require(data.get("factory_launcher_sha256") == FACTORY_SHA, "Factory identity differs")
    require(data.get("new_native_source_paths") == [LAUNCHER], "Missing source launcher provenance")
    require(data.get("previous_native_files_identical_to_build17") is True,
            "Unexpected pre-existing native replacement")
    rows = data.get("rows", [])
    require(len(rows) == 30, "The source-launcher build requires exactly 30 expected files")
    paths = {}
    for row in rows:
        path = row.get("path", "")
        require(re.fullmatch(r"/[A-Za-z0-9_./@+-]+", path), "Invalid manifest path")
        require(".." not in Path(path).parts and path not in paths, "Duplicate/unsafe path")
        require(SHA_RE.fullmatch(str(row.get("sha256", ""))), "Invalid expected file SHA")
        paths[path] = row
    require(LAUNCHER in paths and MODULE in paths, "Launcher/module absent from manifest")
    require(paths[LAUNCHER]["kind"] == "native_source", "Launcher is not from source")
    require(paths[MODULE]["kind"] == "source_kernel_module", "Module is not from source")
    require(paths[LAUNCHER]["sha256"] != FACTORY_SHA, "Factory launcher is prohibited")
    return paths


def validate_build_inputs(data, expected):
    rows = data.get("inputs", [])
    require(rows and len(rows) == len({row["repository"] for row in rows}),
            "Missing/duplicate frozen build inputs")
    inputs = {row["repository"]: row for row in rows}
    for path in ("lineage-17.1/kernel/xsh/k50sv1_64_bsp",
                 "lineage-17.1/device/xsh/k50sv1_64_bsp",
                 "lineage-17.1/vendor/xsh/k50sv1_64_bsp"):
        row = inputs.get(path, {})
        require(row.get("clean") is True and re.fullmatch(r"[0-9a-f]{40}", row.get("revision", "")),
                "Required build input is absent, dirty, or not pinned: " + path)
    require(inputs["lineage-17.1/kernel/xsh/k50sv1_64_bsp"]["revision"] == expected["kernel_revision"],
            "Manifest and frozen build input kernel differ")
    return inputs


def validate_readback(expected, result, raw_hashes, raw_identity, boot_id):
    require(result.get("status") == "PASS", "Independent readback did not pass")
    require(result.get("boot_id") == boot_id, "Readback belongs to another boot")
    require(result.get("receipt_sha256") == expected["receipt_sha256"], "Readback receipt differs")
    require(raw_identity.decode().splitlines() == [boot_id, expected["incremental"], "0"],
            "Readback raw identity differs")
    paths = validate_manifest(expected)
    rows = result.get("rows", [])
    require(len(rows) == len({r["path"] for r in rows}) == 30, "Readback row count differs")
    require({r["path"] for r in rows} == set(paths), "Readback paths differ")
    hashes = parse_hashes(raw_hashes)
    require(hashes == {p: r["sha256"] for p, r in paths.items()}, "Raw readback hash mismatch")
    for row in rows:
        ref = paths[row["path"]]
        require(row.get("sha256") == row.get("readback_sha256") == ref["sha256"]
                and row.get("matches") is True and row.get("kind") == ref["kind"],
                "Readback row mismatch")


def binary_log_records(raw):
    """Decode complete native main-buffer entries; leave an incomplete tail pending."""
    records = []
    offset = 0
    while len(raw) - offset >= LOG_HEADER.size:
        length, header, pid, tid, seconds, nsec, lid, uid = LOG_HEADER.unpack_from(raw, offset)
        if header != LOG_HEADER.size or not 3 <= length <= 4068 or lid != 0 or nsec >= NSEC_PER_SEC:
            raise EvidenceGap("Log stream is not a valid native Q main-buffer v4 entry")
        end = offset + header + length
        if end > len(raw):
            break
        payload = raw[offset + header:end]
        fields = payload[1:].split(b"\0", 1)
        if len(fields) != 2 or not fields[1].endswith(b"\0") or not 2 <= payload[0] <= 8:
            raise EvidenceGap("Malformed native main-buffer log payload")
        records.append({"offset": offset, "end": end, "pid": pid, "tid": tid, "uid": uid,
                        "priority": payload[0], "monotonic_ns": seconds * NSEC_PER_SEC + nsec,
                        "tag": fields[0].decode("utf-8", "replace"),
                        "message": fields[1][:-1].decode("utf-8", "replace")})
        offset = end
    return records, offset


def native_clock(properties):
    if not isinstance(properties, dict) or not all(isinstance(properties.get(key, ""), str)
                                                 for key in ("persist_value", "ro_value")):
        return False
    value = properties.get("persist_value") or properties.get("ro_value") or ""
    return value[:1].lower() == "m"


def check_clock_binding(pid, binding):
    if not isinstance(binding, dict) or binding.get("origin") != "guarded-new-process-after-native-tail1-drain":
        raise EvidenceGap("Retained initial logs lack a proven native clock and process-lifetime boundary")
    before, after = binding.get("clock_before", {}), binding.get("clock_after", {})
    if (binding.get("pid") != pid or binding.get("old_pid") == pid or
            not native_clock(before) or not native_clock(after) or
            not before.get("boot_id") or before.get("boot_id") != after.get("boot_id") or
            before.get("clk_tck") != after.get("clk_tck") or
            type(binding.get("starttime")) is not int or binding["starttime"] <= 0 or
            type(after.get("clk_tck")) is not int or after["clk_tck"] <= 0 or
            NSEC_PER_SEC % after["clk_tck"] != 0 or
            type(after.get("boottime_upper_ns")) is not int or after["boottime_upper_ns"] <= 0 or
            type(binding.get("discarded_history_bytes")) is not int or binding["discarded_history_bytes"] < LOG_HEADER.size):
        raise EvidenceGap("Incomplete native clock or controlled-process provenance")
    return binding["starttime"], after["clk_tck"], after["boottime_upper_ns"]


def launcher_records(raw, pid, clock_binding=None):
    starttime, clk_tck, upper_ns = check_clock_binding(pid, clock_binding)
    records, _ = binary_log_records(raw)
    # proc stat truncates BOOTTIME birth to CLK_TCK ticks. MONOTONIC birth
    # is no later than BOOTTIME birth, even after suspend. Requiring the
    # upper edge of the next tick is conservative; do not equate the clocks.
    return [record for record in records if record["pid"] == pid and record["tag"] == "wmt_launcher"
            and record["monotonic_ns"] * clk_tck >= (starttime + 1) * NSEC_PER_SEC
            and record["monotonic_ns"] < upper_ns]


def session_evidence(raw, pid, clock_binding=None):
    records = launcher_records(raw, pid, clock_binding)
    ready = [(r, READY_RE.fullmatch(r["message"])) for r in records]
    ready = [(r, m) for r, m in ready if m]
    if not ready:
        raise EvidenceGap(f"No retained source ready/session log for PID {pid}")
    sessions = {int(m[1]) for _, m in ready}
    require(len(sessions) == 1 and next(iter(sessions)) > 0,
            "Ambiguous source session for the current PID")
    session = next(iter(sessions))
    return {"status": "PASS", "pid": pid, "session": session, "ready": ready[-1][0],
            "clock_binding": clock_binding}


def startup_evidence(raw, pid, require_patch, clock_binding=None):
    current = session_evidence(raw, pid, clock_binding)
    records = launcher_records(raw, pid, clock_binding)
    session = current["session"]
    power = [r for r in records if POWER_RE.fullmatch(r["message"])]
    patches = []
    for record in records:
        patch = PATCH_RE.fullmatch(record["message"])
        if patch and int(patch[1]) == session:
            require(int(patch[3]) == 0 and int(patch[4]) == 2 and int(patch[2]) > 0,
                    "Observed srh_patch was not an accepted two-record success")
            patches.append({**record, "transaction": int(patch[2]), "records": int(patch[4])})
    if not power:
        raise EvidenceGap(f"No retained power-completion log for source PID {pid}")
    if require_patch and not patches:
        raise EvidenceGap(f"No retained accepted two-record srh_patch log for session {session}")
    # Power's thread can log before the ready line or accepted reply line.
    return {**current,
            "power": power, "accepted_srh_patch": patches, "patch_required": require_patch}


def kernel_mode_evidence(raw, tids, begin, end, mode):
    found = []
    for line in raw.decode("utf-8", "replace").splitlines():
        match = KMSG_RE.match(line)
        if not match:
            continue
        seconds = int(match["us"]) / 1_000_000
        if not begin <= seconds <= end:
            continue
        message = match["message"]
        task, value = TASK_RE.search(message), MODE_RE.search(message)
        if (task and value and int(task[1]) in tids and int(value[1], 16) == mode
                and "wmt_plat_set_dbg_mode" in message):
            found.append({"sequence": int(match["seq"]), "uptime": seconds,
                          "tid": int(task[1]), "mode": mode, "raw": line})
    return found


def guarded_term_command(process, sha):
    pid, starttime = process["pid"], process["starttime"]
    require(type(pid) is int and pid > 1 and type(starttime) is int and starttime > 0,
            "Invalid signal target")
    require(SHA_RE.fullmatch(sha) and sha != FACTORY_SHA, "Unsafe signal ELF identity")
    # /proc stat field 22 is field 20 after removing everything through the last ') '.
    return (
        f"probe_stat=$(cat /proc/{pid}/stat) || exit 71; "
        "probe_tail=${probe_stat##*) }; set -- $probe_tail; "
        "shift 19; "
        f"[ \"$1\" = {starttime} ] || exit 72; "
        f"[ \"$(readlink /proc/{pid}/exe)\" = {shlex.quote(LAUNCHER)} ] || exit 73; "
        f"probe_hash=$(sha256sum /proc/{pid}/exe) || exit 74; "
        f"[ \"${{probe_hash%% *}}\" = {sha} ] || exit 75; "
        f"kill -TERM {pid}"
    )


class Probe:
    def __init__(self, args):
        self.args = args
        self.out = args.output.resolve()
        self.out.mkdir(parents=True, exist_ok=False)
        self.adb = [args.adb, "-s", args.serial]
        self.env = dict(os.environ, ADB_LIBUSB="1")
        self.sequence = 0
        self.streams = []
        self.original = None
        self.mutated = False
        self.boot_id = None
        self.paths = {}
        self.result = {"status": "RUNNING", "mode": args.mode, "phase": args.phase, "build": args.build,
                       "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
                       "probe_script_sha256": digest(Path(__file__).read_bytes()),
                       "commands": [], "checks": {}, "cleanup": {"status": "NOT_NEEDED"}}
        self.save()

    def save(self):
        temp = self.out / "result.json.tmp"
        temp.write_bytes(json_bytes(self.result))
        temp.replace(self.out / "result.json")

    def check(self, name, status="PASS", **details):
        self.result["checks"][name] = {"status": status, **details}
        self.save()

    def file(self, name, data):
        path = self.out / name
        path.write_bytes(data)
        return {"path": name, "bytes": len(data), "sha256": digest(data)}

    def command(self, name, argv, check=True, timeout=20):
        self.sequence += 1
        label = f"{self.sequence:04d}-{name}"
        start = time.monotonic()
        item = {"label": label, "argv": argv, "host_start_epoch": time.time()}
        try:
            done = subprocess.run(argv, env=self.env, capture_output=True, timeout=timeout)
            stdout, stderr, code = done.stdout, done.stderr, done.returncode
        except subprocess.TimeoutExpired as error:
            stdout, stderr, code = error.stdout or b"", error.stderr or b"", None
            item["timeout"] = timeout
        except OSError as error:
            stdout, stderr, code = b"", str(error).encode(), None
        item.update(exit_code=code, elapsed_seconds=time.monotonic() - start,
                    stdout=self.file(label + ".stdout", stdout),
                    stderr=self.file(label + ".stderr", stderr))
        self.result["commands"].append(item)
        self.save()
        if check:
            require(code == 0, f"Command {label} failed (exit {code})")
        return stdout, code

    def shell(self, name, command, **kwargs):
        return self.command(name, self.adb + ["shell", "-T", command], **kwargs)

    def remote(self, name, *argv, **kwargs):
        return self.shell(name, shlex.join(map(str, argv)), **kwargs)

    def state(self, name):
        command = (
            "for probe_key in " + shlex.join(PROPERTIES) + "; do "
            "printf '%s=' \"$probe_key\"; getprop \"$probe_key\"; done; "
            "printf 'boot_id='; cat /proc/sys/kernel/random/boot_id; "
            "printf 'tainted='; cat /proc/sys/kernel/tainted; "
            "printf 'uptime='; cat /proc/uptime; "
            "printf 'pids='; pidof wmt_launcher; :"
        )
        raw, _ = self.shell(name, command)
        rows = [line.split("=", 1) for line in raw.decode().splitlines()]
        require(all(len(r) == 2 for r in rows), "Malformed device state")
        result = dict(rows)
        require(len(rows) == len(result) and set(result) == set(PROPERTIES) |
                {"boot_id", "tainted", "uptime", "pids"}, "Incomplete device state")
        require(BOOT_RE.fullmatch(result["boot_id"]), "Invalid boot ID")
        if self.boot_id:
            require(result["boot_id"] == self.boot_id, "Handset rebooted during the probe")
        if self.paths:
            require(result["ro.build.version.incremental"] == self.expected["incremental"],
                    "Build incremental changed")
        result["uptime_seconds"] = float(result["uptime"].split()[0])
        result["pids"] = [int(p) for p in result["pids"].split()]
        return result

    def healthy(self, state):
        require(state["sys.boot_completed"] == "1" and state["tainted"] == "0",
                "Boot incomplete or kernel tainted")
        for prop, value in (("init.svc.wmt_launcher", "running"),
                            ("vendor.connsys.driver.ready", "yes"),
                            ("vendor.connsys.formeta.ready", "yes")):
            require(state[prop] == value, f"{prop} is {state[prop]!r}, expected {value}")
        require(len(state["pids"]) == 1 and state["pids"][0] > 1,
                "Expected one live launcher PID")

    def snapshot(self, name):
        state = self.state(name + "-state")
        self.healthy(state)
        pid = state["pids"][0]
        before = parse_stat(self.remote(name + "-stat-before", "cat", f"/proc/{pid}/stat")[0])
        raw_cmd = self.remote(name + "-cmdline", "cat", f"/proc/{pid}/cmdline")[0]
        expected_cmd = b"\0".join((LAUNCHER.encode(), b"-p", b"/vendor/firmware/", b"-o", b"1")) + b"\0"
        require(raw_cmd == expected_cmd,
                "Launcher command line differs from the service definition")
        exe = self.remote(name + "-exe", "readlink", f"/proc/{pid}/exe")[0].decode().rstrip("\n")
        require(exe == LAUNCHER, "Launcher /proc executable path differs")
        hashes = parse_hashes(self.remote(name + "-hashes", "sha256sum", MODULE,
                                          LAUNCHER, f"/proc/{pid}/exe")[0])
        require(hashes == {MODULE: self.paths[MODULE]["sha256"],
                           LAUNCHER: self.paths[LAUNCHER]["sha256"],
                           f"/proc/{pid}/exe": self.paths[LAUNCHER]["sha256"]},
                "Live source module/launcher/proc-exe hash mismatch")
        fds = self.shell(name + "-fds", f"for probe_fd in /proc/{pid}/fd/*; do "
                         "printf '%s ' \"${probe_fd##*/}\"; readlink \"$probe_fd\" || exit; done")[0]
        require(sum(line.split(maxsplit=1)[-1] == b"/dev/stpwmt" for line in fds.splitlines()) == 1,
                "Expected one open /dev/stpwmt descriptor")
        tids = self.tids(pid, name + "-tids")
        after = parse_stat(self.remote(name + "-stat-after", "cat", f"/proc/{pid}/stat")[0])
        require((before["pid"], before["starttime"]) == (after["pid"], after["starttime"]),
                "Process changed while collecting its identity")
        last_state = self.state(name + "-state-after")
        self.healthy(last_state)
        require(last_state["pids"] == [pid], "Launcher changed at the end of its identity snapshot")
        return {**before, "exe": exe, "sha256": hashes[LAUNCHER], "tids": sorted(tids),
                "state": state, "cmdline": raw_cmd.decode().split("\0")[:-1],
                "fd_links": fds.decode().splitlines()}

    def tids(self, pid, name):
        raw = self.remote(name, "ls", f"/proc/{pid}/task")[0]
        tids = {int(t) for t in raw.split()}
        require(pid in tids and all(t > 1 for t in tids), "Invalid process TID set")
        return tids

    def property_value(self, name):
        raw = self.remote(name, "getprop", FWLOG)[0]
        require(raw.endswith(b"\n") and b"\x00" not in raw, "Malformed property output")
        return raw[:-1].decode("utf-8")

    def log_clock(self, name):
        command = (
            "for probe_key in persist.logd.timestamp ro.logd.timestamp; do "
            "printf '%s=' \"$probe_key\"; getprop \"$probe_key\"; done; "
            "printf 'clk_tck='; getconf CLK_TCK || exit; "
            "printf 'boot_id='; cat /proc/sys/kernel/random/boot_id; "
            "printf 'uptime='; cat /proc/uptime"
        )
        raw, code = self.shell(name, command, check=False)
        rows = [line.split("=", 1) for line in raw.decode().splitlines()]
        if code != 0 or len(rows) != 5 or any(len(row) != 2 for row in rows):
            raise EvidenceGap("Cannot read native log clock and device CLK_TCK")
        values = dict(rows)
        if set(values) != {"persist.logd.timestamp", "ro.logd.timestamp", "clk_tck", "boot_id", "uptime"}:
            raise EvidenceGap("Incomplete native log clock observation")
        require(values["boot_id"] == self.boot_id, "Boot changed while reading log clock")
        uptime = values["uptime"].split()[0]
        if not values["clk_tck"].isdigit() or int(values["clk_tck"]) <= 0 or not re.fullmatch(r"\d+\.\d{2}", uptime):
            raise EvidenceGap("Invalid device clock-tick or BOOTTIME sample")
        seconds, hundredths = uptime.split(".")
        # /proc/uptime truncates to centiseconds; take the strict upper edge.
        upper = int(seconds) * NSEC_PER_SEC + (int(hundredths) + 1) * 10_000_000
        return {"persist_value": values["persist.logd.timestamp"], "ro_value": values["ro.logd.timestamp"],
                "clk_tck": int(values["clk_tck"]), "boot_id": self.boot_id, "boottime_upper_ns": upper,
                "command_label": self.result["commands"][-1]["label"]}

    def set_fwlog(self, name, value):
        self.mutated = True
        self.result["mutations_started"] = True
        self.save()
        self.remote(name, "setprop", FWLOG, value)
        require(self.property_value(name + "-readback") == value, "Property write did not persist")

    def copy_input(self, path, name):
        raw = Path(path).read_bytes()
        return raw, self.file(name, raw)

    def preflight(self):
        raw, evidence = self.copy_input(self.args.expected_manifest, "expected-manifest.json")
        self.expected = json.loads(raw)
        self.paths = validate_manifest(self.expected)
        inputs_raw, inputs_evidence = self.copy_input(self.args.build_inputs, "build-inputs.json")
        self.build_inputs = validate_build_inputs(json.loads(inputs_raw), self.expected)
        self.result["manifest"] = evidence
        self.result["build_inputs"] = inputs_evidence
        require(self.remote("root-user", "id", "-u")[0].strip() == b"0", "ADB must already be root")
        state = self.state("preflight-state")
        self.boot_id = state["boot_id"]
        self.result["boot_id"] = self.boot_id
        self.healthy(state)
        early_raw, early_evidence = self.copy_input(self.args.early_dir / "early-complete.json",
                                                    "early-complete.json")
        early = json.loads(early_raw)
        require(early.get("status") == "PASS", "Early collector did not complete")
        early_identity = early.get("identity", "").splitlines()
        require(len(early_identity) >= 5 and early_identity[0] == self.boot_id
                and early_identity[2:4] == [self.expected["incremental"], "0"],
                "Early collector identity differs")
        readback_dir = self.args.readback_result.parent
        result_raw, rb_evidence = self.copy_input(self.args.readback_result, "readback-result.json")
        hash_raw, _ = self.copy_input(readback_dir / "sha256sum.txt", "readback-sha256sum.txt")
        identity_raw, _ = self.copy_input(readback_dir / "identity.txt", "readback-identity.txt")
        validate_readback(self.expected, json.loads(result_raw), hash_raw, identity_raw, self.boot_id)
        modules = self.remote("loaded-modules", "cat", "/proc/modules")[0]
        require(sum(line.split()[0] == b"wmt_drv" for line in modules.splitlines()) == 1,
                "wmt_drv is not uniquely loaded")
        current = self.snapshot("initial")
        self.check("identity", boot_id=self.boot_id, process=current,
                   readback_count=30, early=early_evidence, readback=rb_evidence)
        self.early_log, log_evidence = self.copy_input(self.args.early_dir / "continuous-logcat.txt",
                                                       "early-continuous-logcat.txt")
        self.result["early_log"] = log_evidence
        self.save()
        return current

    def early_continuity(self):
        path = self.args.early_dir / "continuous-logcat.txt"
        with path.open("rb") as source:
            prefix = source.read(len(self.early_log))
        require(prefix == self.early_log, "Early continuous log was replaced or truncated")
        self.check("early_log_prefix_continuity", captured_bytes=len(prefix), sha256=digest(prefix),
                   source_bytes_now=path.stat().st_size,
                   meaning="Retained same-boot log prefix; does not prove missing startup lines existed")

    def start_streams(self):
        clock_before = self.log_clock("stream-clock-before")
        if not native_clock(clock_before):
            raise EvidenceGap("Root must prepare persist.logd.timestamp=m before the normal reboot; probe only reads it")
        for name, argv in (("exercise-logcat", self.adb + ["logcat", "-B", "-b", "main", "-T", "1"]),
                           ("exercise-kmsg", self.adb + ["shell", "-T", "cat /dev/kmsg"])):
            handle = self.stream_path(name).open("wb")
            errors = (self.out / (name + ".stderr")).open("wb")
            try:
                process = subprocess.Popen(argv, env=self.env, stdout=handle, stderr=errors)
            except BaseException:
                handle.close()
                errors.close()
                raise
            self.streams.append((name, process, handle, errors))
        deadline = time.monotonic() + self.args.timeout
        while time.monotonic() < deadline:
            raw = self.stream_data("exercise-logcat")
            entries, complete = binary_log_records(raw)
            if entries:
                # Q's single-main tail=1 reader sends exactly one retained
                # entry, then turns tail off. Discard its complete binary
                # frame before allowing any controlled launcher restart.
                self.logcat_drained_prefix = raw[:complete]
                self.discarded_history_bytes = entries[0]["end"]
                clock_after = self.log_clock("stream-clock-after-drain")
                if not native_clock(clock_after) or clock_after["clk_tck"] != clock_before["clk_tck"]:
                    raise EvidenceGap("Native log clock changed while draining the retained entry")
                self.check("native_history_boundary", clock_before=clock_before, clock_after=clock_after,
                           reader="logcat -B -b main -T 1", discarded_history_bytes=self.discarded_history_bytes,
                           discarded_complete_prefix_bytes=complete, prefix_sha256=digest(self.logcat_drained_prefix),
                           discarded_first_entry=entries[0], meaning="Historical entry discarded without timestamp attribution")
                return
            time.sleep(0.05)
        raise EvidenceGap("No complete native historical entry; reader boundary is not established")

    def stream_path(self, name):
        return self.out / (name + (".bin" if name == "exercise-logcat" else ".txt"))

    def stream_health(self):
        for name, process, _, _ in self.streams:
            require(process.poll() is None, f"Continuous collector {name} exited")

    def stream_data(self, name):
        self.stream_health()
        return self.stream_path(name).read_bytes()

    def local_kernel_source(self):
        """Bind mode-log interpretation to the exact compiled kernel source revision."""
        root = self.args.kernel_tree
        prefix = "drivers/misc/mediatek/connectivity/source/common/common_main/"
        relative = prefix + "platform/wmt_plat_alps.c"
        try:
            head = self.command("kernel-source-head", ["git", "-C", str(root), "rev-parse", "HEAD"])[0]
            require(head.decode().strip() == self.expected["kernel_revision"], "Kernel source HEAD differs")
            changed = self.command("kernel-source-status", ["git", "-C", str(root), "status",
                                   "--porcelain", "--", relative, prefix + "linux/wmt_dev.c"])[0]
            require(not changed.strip(), "Kernel source interpretation files are dirty")
            raw, item = self.copy_input(root / relative, "source-wmt_plat_alps.c")
            source = raw.decode()
            begin = source.index("INT32 wmt_plat_set_dbg_mode(UINT32 flag)")
            end = source.index("\nINT32 ", begin + 1)
            function = source[begin:end]
            require("CONSYS_REG_WRITE(vir_addr, 0x0)" in function and
                    "CONSYS_REG_WRITE(vir_addr, 0x1)" in function and
                    'fw dbg mode register value(0x%08x)' in function,
                    "Unexpected debug-mode implementation")
            dev_raw, dev_item = self.copy_input(root / (prefix + "linux/wmt_dev.c"), "source-wmt_dev.c")
            require("wmt_plat_set_dbg_mode(arg)" in dev_raw.decode(), "No matching ioctl callsite")
            self.check("kernel_log_source_binding", revision=self.expected["kernel_revision"],
                       function=function, source=item, ioctl_source=dev_item)
            return True
        except (OSError, ValueError, ProbeFailure) as error:
            self.check("kernel_log_source_binding", "INCONCLUSIVE", reason=str(error))
            return False

    def capture(self, process):
        try:
            startup = startup_evidence(self.early_log, process["pid"], require_patch=True)
            self.check("startup_attribution", **{k: v for k, v in startup.items() if k != "status"})
        except EvidenceGap as error:
            self.check("startup_attribution", "INCONCLUSIVE", reason=str(error),
                       note="Current properties and converted monotonic text cannot authenticate earlier process lifetimes; identity remains separately checked")
        final = self.snapshot("capture-final")
        require((final["pid"], final["starttime"]) == (process["pid"], process["starttime"]),
                "Launcher restarted during capture")
        self.early_continuity()
        self.check("capture_runtime", process=final)

    def wait_threads(self, process, name, predicate, timeout=None):
        deadline = time.monotonic() + (timeout or self.args.timeout)
        prior = None
        stable = 0
        samples = []
        while time.monotonic() < deadline:
            self.stream_health()
            state = self.state(name + "-state")
            self.healthy(state)
            require(state["pids"] == [process["pid"]], "Launcher PID changed during fwlog exercise")
            stat = parse_stat(self.remote(name + "-stat", "cat", f"/proc/{process['pid']}/stat")[0])
            require(stat["starttime"] == process["starttime"], "Launcher PID was reused")
            tids = self.tids(process["pid"], name + "-tids")
            samples.append({"uptime": state["uptime_seconds"], "tids": sorted(tids)})
            stable = stable + 1 if tids == prior and predicate(tids) else int(predicate(tids))
            if stable >= 3:
                self.check(name, samples=samples)
                return tids, state["uptime_seconds"]
            prior = tids
            time.sleep(0.25)
        self.check(name, "FAIL", samples=samples, reason="TID state did not settle within bound")
        raise ProbeFailure(f"{name}: thread transition exceeded {timeout or self.args.timeout}s")

    def worker_detail(self, pid, tid, name):
        for field in ("stat", "wchan", "syscall"):
            self.remote(name + "-" + field, "cat", f"/proc/{pid}/task/{tid}/{field}", check=False)

    def mode_check(self, name, tids, begin, end, mode, minimum=1):
        records = kernel_mode_evidence(self.stream_data("exercise-kmsg"), tids, begin, end, mode)
        source_ok = self.result["checks"]["kernel_log_source_binding"]["status"] == "PASS"
        status = "PASS" if source_ok and len(records) >= minimum else "INCONCLUSIVE"
        self.check(name, status, tids=sorted(tids), begin_uptime=begin, end_uptime=end,
                   mode=mode, records=records, minimum_records=minimum,
                   meaning="PID/TID-and-time-bound existing driver write/read log; not a final independent mode readback",
                   source_binding=source_ok)

    def ping_wifi(self, name):
        def counters(suffix):
            raw = self.remote(name + suffix, "cat", "/sys/class/net/wlan0/statistics/rx_packets",
                              "/sys/class/net/wlan0/statistics/tx_packets")[0]
            values = [int(value) for value in raw.split()]
            require(len(values) == 2, "Malformed Wi-Fi counters")
            return values
        address = self.remote(name + "-address", "ip", "-o", "-4", "addr", "show", "dev", "wlan0")[0]
        require(b" inet " in address, "wlan0 has no IPv4 address")
        before = counters("-before")
        raw, code = self.remote(name + "-ping", "ping", "-I", "wlan0", "-c", "4", "-i", "0.2",
                                "-W", "3", self.args.ping_target, check=False, timeout=25)
        after = counters("-after")
        received = re.search(rb"(\d+) packets transmitted,\s*(\d+) (?:packets )?received", raw)
        require(code == 0 and received is not None and int(received[2]) > 0,
                "Wi-Fi ping did not receive a reply")
        require(after[0] > before[0] and after[1] > before[1], "Wi-Fi counters did not advance")
        self.check(name, received=int(received[2]), target=self.args.ping_target,
                   interface="wlan0", before_packets=before, after_packets=after)

    def restart(self, process, old_session, name, check_final_disable):
        current = self.snapshot(name + "-before")
        require((current["pid"], current["starttime"]) == (process["pid"], process["starttime"]),
                "Signal target changed")
        raw = self.stream_data("exercise-logcat")
        require(raw.startswith(self.logcat_drained_prefix), "Native reader prefix changed")
        _, complete = binary_log_records(raw)
        # Keep a whole-frame boundary even if another entry is being written.
        log_prefix = raw[:complete]
        clock_before = self.log_clock(name + "-clock-before-signal")
        if not native_clock(clock_before):
            raise EvidenceGap("Native clock no longer monotonic before the guarded signal")
        begin = self.state(name + "-signal-window")["uptime_seconds"]
        self.mutated = True
        self.result["mutations_started"] = True
        self.save()
        self.shell(name + "-guarded-sigterm", guarded_term_command(current, current["sha256"]))
        deadline = time.monotonic() + self.args.timeout
        transitions = []
        replacement = None
        old_gone_at = None
        while time.monotonic() < deadline:
            self.stream_health()
            state = self.state(name + "-transition")
            old_raw, old_code = self.remote(name + "-old-stat", "cat", f"/proc/{current['pid']}/stat",
                                             check=False)
            old_alive = old_code == 0 and parse_stat(old_raw)["starttime"] == current["starttime"]
            transitions.append({"uptime": state["uptime_seconds"], "pids": state["pids"],
                                "service": state["init.svc.wmt_launcher"],
                                "ready": state["vendor.connsys.formeta.ready"], "old_alive": old_alive})
            if not old_alive and old_gone_at is None:
                # Read the upper time bound after observing disappearance, so
                # the final disable between state sampling and stat cannot be excluded.
                old_gone_at = self.state(name + "-old-gone-window")["uptime_seconds"]
            self.result["checks"][name] = {"status": "RUNNING", "transitions": transitions,
                                           "old_pid": current["pid"], "old_starttime": current["starttime"]}
            self.save()
            if (old_gone_at is not None and len(state["pids"]) == 1
                    and state["pids"][0] != current["pid"]
                    and state["init.svc.wmt_launcher"] == "running"
                    and state["vendor.connsys.formeta.ready"] == "yes"):
                replacement = self.snapshot(name + "-replacement")
                break
            time.sleep(0.15)
        require(replacement is not None and old_gone_at is not None,
                "Old process did not exit and recover through init within bound")
        require(replacement["starttime"] > current["starttime"], "Replacement birth is not newer")
        startup = None
        last_gap = "No new source startup records"
        while time.monotonic() < deadline:
            raw = self.stream_data("exercise-logcat")
            require(raw.startswith(log_prefix), "Own logcat stream was replaced or truncated")
            tail = raw[len(log_prefix):]
            try:
                clock_after = self.log_clock(name + "-clock-after-startup")
                binding = {"origin": "guarded-new-process-after-native-tail1-drain",
                           "pid": replacement["pid"], "starttime": replacement["starttime"],
                           "old_pid": current["pid"], "clock_before": clock_before, "clock_after": clock_after,
                           "discarded_history_bytes": self.discarded_history_bytes,
                           "controlled_prefix_bytes": len(log_prefix), "controlled_prefix_sha256": digest(log_prefix),
                           "birth_rule": "log_ns * CLK_TCK >= (proc_starttime + 1) * 1000000000",
                           "upper_rule": "log_ns < observed_BOOTTIME_centisecond_upper_ns",
                           "clock_note": "BOOTTIME includes suspend; this conservative bound can reject genuine MONOTONIC startup records"}
                startup = startup_evidence(tail, replacement["pid"], require_patch=False, clock_binding=binding)
                break
            except EvidenceGap as error:
                last_gap = str(error)
                time.sleep(0.25)
        self.file(name + "-new-process-logcat.bin", self.stream_data("exercise-logcat")[len(log_prefix):])
        if startup is not None and old_session is not None:
            require(startup["session"] > old_session, "Replacement session did not advance")
        details = {"old_pid": current["pid"], "old_starttime": current["starttime"],
                   "old_session": old_session, "new_process": replacement, "startup": startup,
                   "signal_begin_uptime": begin, "old_gone_uptime": old_gone_at,
                   "transitions": transitions, "observed_ready_no": any(t["ready"] == "no" for t in transitions),
                   "observed_service_stopped": any(t["service"] == "stopped" for t in transitions),
                   "observed_service_restarting": any(t["service"] == "restarting" for t in transitions),
                   "method": "Identity-guarded SIGTERM, then init automatic restart"}
        self.check(name, "PASS" if startup else "INCONCLUSIVE", **details,
                   **({} if startup else {"reason": last_gap}))
        if check_final_disable:
            self.mode_check(name + "-final-disable", {current["pid"]}, begin, old_gone_at, 0)
        if not startup:
            raise EvidenceGap(last_gap)
        return replacement, startup["session"]

    def exercise(self, process):
        require(self.args.phase == "normal-reboot", "Exercise is restricted to normal-reboot")
        self.original = self.property_value("original-fwlog-property")
        self.result["original_fwlog_property"] = self.original
        self.result["original_property_empty"] = self.original == ""
        self.result["property_restore_note"] = "An empty original value is restored as an empty string; property keys cannot be deleted"
        self.result["initial_pid_tids"] = process
        self.save()
        initial_gap = "Initial retained logs do not prove the current process's native clock and birth window"
        self.check("initial_observable_session", "INCONCLUSIVE", reason=initial_gap)
        if not self.args.establish_session:
            raise EvidenceGap(initial_gap + "; rerun in a NEW output directory with explicit --establish-session")
        self.start_streams()
        self.local_kernel_source()
        process, old_session = self.restart(process, None, "establish-session", check_final_disable=False)
        self.check("initial_observable_session", "RESOLVED_BY_ESTABLISH_SESSION", reason=initial_gap,
                   established_pid=process["pid"], established_session=old_session)
        self.set_fwlog("prime-fwlog-off", "no")
        baseline, _ = self.wait_threads(process, "fwlog-off-baseline", lambda tids: tids == {process["pid"]})
        enable_begin = self.state("fwlog-enable-window")["uptime_seconds"]
        self.set_fwlog("enable-fwlog", "yes")
        enabled, enabled_at = self.wait_threads(process, "fwlog-worker-started",
                                                 lambda tids: len(tids - baseline) == 1 and baseline < tids)
        worker = next(iter(enabled - baseline))
        self.worker_detail(process["pid"], worker, "fwlog-worker")
        self.mode_check("fwlog-bounded-enable-reentry", {worker}, enable_begin, enabled_at, 1, minimum=2)
        disable_begin = self.state("fwlog-disable-window")["uptime_seconds"]
        off_started = time.monotonic()
        self.set_fwlog("disable-fwlog", "no")
        retired, retired_at = self.wait_threads(process, "fwlog-worker-reclaimed", lambda tids: tids == baseline)
        self.check("fwlog-cycle", old_pid=process["pid"], baseline_tids=sorted(baseline),
                   enabled_tids=sorted(enabled), retired_tids=sorted(retired), worker_tid=worker,
                   disable_to_reclaimed_seconds=time.monotonic() - off_started,
                   assertion="Additional worker existed and was reclaimed while the same source launcher stayed healthy")
        self.mode_check("fwlog-cycle-disable", {process["pid"]}, disable_begin, retired_at, 0)
        self.ping_wifi("wifi-after-fwlog-cycle")
        self.set_fwlog("enable-fwlog-before-sigterm", "yes")
        enabled, _ = self.wait_threads(process, "fwlog-worker-before-sigterm",
                                       lambda tids: len(tids - baseline) == 1 and baseline < tids)
        self.worker_detail(process["pid"], next(iter(enabled - baseline)), "sigterm-worker")
        replacement, new_session = self.restart(process, old_session, "sigterm-restart", check_final_disable=True)
        self.ping_wifi("wifi-after-sigterm-restart")
        settled = self.snapshot("exercise-final")
        require((settled["pid"], settled["starttime"]) == (replacement["pid"], replacement["starttime"]),
                "Replacement restarted again before final runtime verification")
        self.early_continuity()
        self.check("exercise_runtime", new_process=settled, old_session=old_session,
                   new_session=new_session, boot_id=self.boot_id)

    def cleanup(self):
        errors = []
        cleanup = {"status": "PASS" if self.mutated else "NOT_NEEDED", "errors": errors}
        if self.mutated:
            require(self.original is not None, "Internal error: mutation without original property")
            try:
                self.remote("finally-restore-fwlog", "setprop", FWLOG, self.original)
                restored = self.property_value("finally-fwlog-readback")
                require(restored == self.original, "Original fwlog property was not restored exactly")
                cleanup["restored_property"] = restored
            except BaseException as error:
                errors.append("Property restore: " + repr(error))
            try:
                deadline = time.monotonic() + self.args.timeout
                started = False
                while time.monotonic() < deadline:
                    state = self.state("finally-service-state")
                    if (state["init.svc.wmt_launcher"] == "running" and
                            state["vendor.connsys.formeta.ready"] == "yes" and len(state["pids"]) == 1):
                        cleanup["process"] = self.snapshot("finally-process")
                        break
                    if state["init.svc.wmt_launcher"] == "stopped" and not started:
                        self.remote("finally-recovery-start", "setprop", "ctl.start", "wmt_launcher")
                        started = True
                    time.sleep(0.5)
                else:
                    raise ProbeFailure("Service did not recover within cleanup bound")
                cleanup["recovery_ctl_start_used"] = started
            except BaseException as error:
                errors.append("Service recovery: " + repr(error))
        for name, process, handle, error_handle in self.streams:
            prior_code = process.poll()
            try:
                if prior_code is None:
                    process.terminate()  # Host-side adb collector only; no device signal.
                    process.wait(timeout=8)
                else:
                    errors.append(f"Continuous collector {name} exited early with {prior_code}")
            except BaseException as error:
                errors.append(f"Collector {name} cleanup: {error!r}")
            finally:
                handle.close()
                error_handle.close()
            path = self.stream_path(name)
            stderr_path = self.out / (name + ".stderr")
            cleanup.setdefault("streams", []).append({"name": name, "host_pid": process.pid,
                "exit_code": process.poll(), "bytes": path.stat().st_size,
                "sha256": digest(path.read_bytes()), "stderr_bytes": stderr_path.stat().st_size,
                "stderr_sha256": digest(stderr_path.read_bytes())})
        if errors:
            cleanup["status"] = "FAIL"
        self.result["cleanup"] = cleanup
        self.save()

    def run(self):
        try:
            process = self.preflight()
            if self.args.mode == "capture":
                self.capture(process)
            else:
                self.exercise(process)
        except EvidenceGap as error:
            self.result["evidence_gap"] = str(error)
        except BaseException as error:
            self.result["failure"] = {"type": type(error).__name__, "message": str(error)}
            self.file("failure-traceback.txt", traceback.format_exc().encode())
        finally:
            try:
                self.cleanup()
            except BaseException as error:
                self.result["cleanup"] = {"status": "FAIL", "errors": [repr(error)]}
        statuses = [item["status"] for item in self.result["checks"].values()]
        if "failure" in self.result or "FAIL" in statuses or self.result["cleanup"]["status"] == "FAIL":
            status = "FAIL"
        elif "evidence_gap" in self.result or "INCONCLUSIVE" in statuses:
            status = "INCONCLUSIVE"
        else:
            status = "PASS"
        self.result["status"] = status
        self.result["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        self.save()
        print(json.dumps({"status": status, "result": str(self.out / "result.json")}))
        return {"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 2}[status]


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("mode", choices=("capture", "exercise"))
    result.add_argument("--build", required=True, type=int, help="Completed source-launcher build number (18 or later)")
    result.add_argument("--phase", required=True, choices=("first-boot", "normal-reboot"))
    result.add_argument("--expected-manifest", type=Path)
    result.add_argument("--build-inputs", type=Path)
    result.add_argument("--early-dir", type=Path)
    result.add_argument("--readback-result", type=Path)
    result.add_argument("--output", type=Path, required=True, help="New directory; existing paths are rejected")
    result.add_argument("--adb", default="/home/desmond/Android/Sdk/platform-tools/adb")
    result.add_argument("--serial", default="0123456789ABCDEF")
    result.add_argument("--timeout", type=float, default=90.0, help="Seconds per bounded transition (5..180)")
    result.add_argument("--ping-target", default="1.1.1.1", help="IPv4 peer reachable over wlan0")
    result.add_argument("--establish-session", action="store_true",
                        help="Establish a new session after the native log-clock/history boundary; required for exercise")
    result.add_argument("--kernel-tree", type=Path,
                        default=TRIAL / "build-project/lineage-17.1/kernel/xsh/k50sv1_64_bsp")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    if args.build < 18:
        raise SystemExit("--build must be 18 or later")
    if not 5 <= args.timeout <= 180:
        raise SystemExit("--timeout must be in [5, 180]")
    if ipaddress.ip_address(args.ping_target).version != 4:
        raise SystemExit("--ping-target must be an IPv4 address")
    if args.mode == "exercise" and args.phase != "normal-reboot":
        raise SystemExit("exercise requires --phase normal-reboot")
    if args.establish_session and args.mode != "exercise":
        raise SystemExit("--establish-session is exercise-only")
    args.expected_manifest = args.expected_manifest or TRIAL / f"build{args.build}-expected-installed.json"
    args.build_inputs = args.build_inputs or TRIAL / f"build{args.build}-input-update.json"
    args.early_dir = args.early_dir or TRIAL / f"runtime/build{args.build}-{args.phase}-early"
    args.readback_result = args.readback_result or TRIAL / f"runtime/build{args.build}-{args.phase}-readback/result.json"
    return Probe(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
