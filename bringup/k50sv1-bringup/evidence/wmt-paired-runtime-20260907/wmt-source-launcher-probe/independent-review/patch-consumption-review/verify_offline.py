#!/usr/bin/env python3
"""Replay the frozen collector's unchanged pure AST blocks; never launch ADB."""
import argparse
import ast
import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import traceback


HERE = Path(__file__).resolve().parent
SNAPSHOT = HERE / "snapshot"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def deny_process_launch(event, _args):
    if event.startswith("subprocess.") or event in {"os.system", "os.exec", "os.posix_spawn"}:
        raise RuntimeError("Offline verification forbids process launches: " + event)


def assigned(node, name):
    return isinstance(node, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == name for target in node.targets
    )


def blocks(path):
    source = path.read_text()
    tree = ast.parse(source, str(path))
    body = tree.body
    firmware_start = next(i for i, node in enumerate(body) if assigned(node, "firmware"))
    firmware_end = next(i for i, node in enumerate(body) if assigned(node, "source_tree"))
    records_start = next(i for i, node in enumerate(body) if assigned(node, "records"))
    records_end = next(i for i, node in enumerate(body) if assigned(node, "selected"))
    chunks = {
        "firmware": [next(node for node in body if assigned(node, "paths"))]
        + body[firmware_start:firmware_end],
        "records": body[records_start:records_end],
    }
    metadata = {name: [
        {"line": node.lineno, "end_line": node.end_lineno,
         "sha256": sha(ast.get_source_segment(source, node).encode())}
        for node in nodes
    ] for name, nodes in chunks.items()}
    compiled = {name: compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec")
                for name, nodes in chunks.items()}
    return compiled, metadata


def load_json(relative):
    return json.loads((SNAPSHOT / relative).read_text())


CURRENT, CURRENT_BLOCKS = blocks(SNAPSHOT / "collector-current.py")
BEFORE, BEFORE_BLOCKS = blocks(SNAPSHOT / "collector-before-order-fix.py")
PREFLASH = load_json("runtime/build19-preflash/result.json")


def firmware(result, compiled=CURRENT, product=None, actual=None, preflash=None):
    namespace = dict(sha=sha, product=product or SNAPSHOT / "product",
                     actual=result["installed_sha256"] if actual is None else actual,
                     preflash=PREFLASH if preflash is None else preflash)
    exec(compiled["firmware"], namespace)
    return namespace["firmware"]


def parse(raw, result, compiled=CURRENT, firmware_rows=None, uptime=None):
    namespace = dict(re=re, raw=raw,
                     firmware=firmware(result, compiled) if firmware_rows is None else firmware_rows,
                     observed_uptime=result["observed_uptime"] if uptime is None else uptime)
    exec(compiled["records"], namespace)
    return namespace


def require_rejected(function):
    try:
        function()
    except AssertionError:
        return
    raise AssertionError("Malformed input unexpectedly passed the unchanged collector block")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="New child directory under this review")
    args = parser.parse_args()
    out = (HERE / args.output).resolve()
    assert out.parent == HERE
    out.mkdir(exist_ok=False)
    sys.addaudithook(deny_process_launch)
    cases = []

    def check(name, function):
        try:
            detail = function()
            cases.append(dict(name=name, status="PASS", detail=detail))
        except Exception:
            cases.append(dict(name=name, status="FAIL", traceback=traceback.format_exc()))

    def integrity():
        rows = json.loads((HERE / "snapshot-sha256.json").read_text())["rows"]
        for row in rows:
            data = (SNAPSHOT / row["snapshot"]).read_bytes()
            assert len(data) == row["bytes"] and sha(data) == row["sha256"]
        return dict(files=len(rows))

    check("frozen_input_integrity", integrity)
    observed = {}
    for phase in ("first-boot", "normal-reboot"):
        def actual_capture(phase=phase):
            base = f"runtime/build19-{phase}-patch-consumption"
            result = load_json(base + "/result.json")
            raw = (SNAPSHOT / f"runtime/build19-{phase}-early/consumed-kmsg-prefix.txt").read_bytes()
            assert len(raw) == result["continuous_prefix_bytes"]
            assert sha(raw) == result["continuous_prefix_sha256"]
            parsed = parse(raw, result)
            assert parsed["downloads"] == result["downloads"]
            assert firmware(result) == result["firmware"]
            selected = [part["raw"] for row in parsed["downloads"] for part in (row["start"], row["end"])]
            assert "\n".join(selected) + "\n" == (SNAPSHOT / base / "patch-download-records.txt").read_text()
            identity = (SNAPSHOT / base / "identity.txt").read_text().splitlines()
            assert identity[:3] == [result["boot_id"], result["incremental"], "0"]
            assert (SNAPSHOT / base / "final-identity.txt").read_text().splitlines() == identity[:3]
            assert float(identity[3].split()[0]) == result["observed_uptime"]
            assert load_json(f"runtime/build19-{phase}-early/early-complete.json")["identity"].splitlines()[0] == result["boot_id"]
            expected = load_json("build19-expected-installed.json")
            readback = load_json(f"runtime/build19-{phase}-readback/result.json")
            assert readback["status"] == "PASS" and readback["boot_id"] == result["boot_id"]
            assert readback["receipt_sha256"] == expected["receipt_sha256"]
            assert len(readback["rows"]) == len(expected["rows"]) == 30
            expected_map = {row["path"]: row["sha256"] for row in expected["rows"]}
            assert len(expected_map) == 30
            assert {row["path"]: row["readback_sha256"] for row in readback["rows"]} == expected_map
            assert all(row["matches"] and row["sha256"] == row["readback_sha256"] for row in readback["rows"])
            assert re.search(r"^wmt_drv\s", (SNAPSHOT / base / "modules.txt").read_text(), re.M)
            installed = {line.split(None, 1)[1].strip(): line.split()[0] for line in
                         (SNAPSHOT / base / "installed-hashes.txt").read_text().splitlines()}
            assert installed == result["installed_sha256"]
            for path in ("/vendor/bin/wmt_launcher", "/vendor/lib/modules/wmt_drv.ko"):
                assert installed[path] == expected_map[path]
            for row in parsed["downloads"]:
                # Independent consistency check against source fragment size 1000.
                assert row["expected_fragments"] == (row["body_bytes"] + 999) // 1000
                assert row["final_fragment_bytes"] == (row["body_bytes"] - 1) % 1000 + 1
            observed[phase] = dict(result=result, raw=raw, parsed=parsed)
            return dict(boot_id=result["boot_id"], records=len(parsed["records"]),
                        first_sequence=parsed["records"][0]["sequence"],
                        last_sequence=parsed["records"][-1]["sequence"],
                        body_bytes=[row["body_bytes"] for row in parsed["downloads"]],
                        accepted_uptime_upper_bound=result["observed_uptime"], readback_rows=30)
        check(phase + "_actual_capture_exact_replay", actual_capture)

    sample = observed["first-boot"]
    result, raw = sample["result"], sample["raw"]
    check("original_filename_order_rejected_actual_capture",
          lambda: require_rejected(lambda: parse(raw, result, BEFORE)))

    records = sample["parsed"]["records"]
    short = [row["raw"] for row in records if row["sequence"] <= result["downloads"][-1]["end"]["sequence"]]
    first = result["downloads"][0]
    start, end = first["start"]["sequence"], first["end"]["sequence"]

    def reject_lines(lines, **kwargs):
        require_rejected(lambda: parse(("\n".join(lines) + "\n").encode(), result, **kwargs))

    mutations = {
        "missing_sequence_zero": short[1:],
        "interior_sequence_gap": short[:start + 1] + short[start + 2:],
        "duplicate_sequence": short[:start + 1] + [short[start]] + short[start + 1:],
        "out_of_order_sequence": short[:start] + [short[start + 1], short[start]] + short[start + 2:],
    }
    changes = {
        "missing_first_start": (start, "mtk_wcn_soc_normal_patch_dwn:", "removed_record:"),
        "missing_first_terminal": (end, "mtk_wcn_soc_normal_patch_dwn:", "removed_record:"),
        "nonzero_transport_result": (end, "patch dwn:0", "patch dwn:-1"),
        "failure_terminal": (end, ") ok", ") fail"),
        "mismatched_fragment_count": (end, "frag(319,", "frag(318,"),
        "wrong_body_size": (start, "size(318380)", "size(318379)"),
    }
    for name, (index, old, new) in changes.items():
        lines = short.copy()
        assert old in lines[index]
        lines[index] = lines[index].replace(old, new, 1)
        mutations[name] = lines
    for name, lines in mutations.items():
        check(name, lambda lines=lines: reject_lines(lines))
    check("cutoff_during_second_download", lambda: reject_lines(
        short, uptime=result["downloads"][1]["start"]["seconds"]))
    check("only_one_complete_download", lambda: reject_lines(short[:end + 1]))

    def wrong_hash():
        actual = dict(result["installed_sha256"])
        actual["/vendor/firmware/ROMv2_lm_patch_1_0_hdr.bin"] = "0" * 64
        require_rejected(lambda: firmware(result, actual=actual))
    check("installed_firmware_hash_mismatch", wrong_hash)

    def header_rejected(value):
        data_map = {row["path"].lstrip("/"): (SNAPSHOT / "product" / row["path"].lstrip("/")).read_bytes()
                    for row in result["firmware"]}
        key = "vendor/firmware/ROMv2_lm_patch_1_0_hdr.bin"
        data = bytearray(data_map[key]); data[24] = value; data_map[key] = bytes(data)
        actual = dict(result["installed_sha256"]); actual["/" + key] = sha(data)
        preflash = copy.deepcopy(PREFLASH)
        next(row for row in preflash["files"] if row["path"] == "/" + key)["after_sha256"] = sha(data)
        class Product:
            def __truediv__(self, name):
                class File:
                    def read_bytes(self):
                        return data_map[name]
                return File()
        require_rejected(lambda: firmware(result, product=Product(), actual=actual, preflash=preflash))
    check("duplicate_header_sequence", lambda: header_rejected(0x21))
    check("wrong_header_count", lambda: header_rejected(0x32))

    report = dict(status="PASS" if all(row["status"] == "PASS" for row in cases) else "FAIL",
                  cases=cases, passed=sum(row["status"] == "PASS" for row in cases), total=len(cases),
                  method="Unmodified pure firmware/record AST nodes extracted from both frozen collectors; process launch audit hook enabled; actual readback evidence checked independently.",
                  process_launches=0, adb_calls=0,
                  blocks=dict(current=CURRENT_BLOCKS, before_order_fix=BEFORE_BLOCKS))
    (out / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("status", "passed", "total", "process_launches", "adb_calls")}))
    for row in cases:
        if row["status"] == "FAIL":
            print(row["name"], row["traceback"])
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
