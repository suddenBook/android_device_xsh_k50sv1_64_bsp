#!/usr/bin/env python3
"""Replay factory-load traces through the actual post-flash verifier predicate."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verifier", type=Path,
                        default=Path(__file__).with_name("verify-post-flash.sh"))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--trace", type=Path)
    args = parser.parse_args()
    source = args.verifier.read_text()
    start = source.index("    if ! has 'ExtensionPluginFactory'")
    end = source.index("    ut801=", start)
    predicate = source[start:end]
    extension = "ImsExtensionFactory: Use MTK's ExtensionPluginFactory\n"
    legacy = "ImsExtensionFactory: Use Legacy's LegacyComponentFactory\n"
    call = "ExtensionPluginFactoryImpl: makeImsCallPlugin()\n"
    cases = [
        ("loaded-without-video-call-plugin", extension + legacy, "PASS"),
        ("loaded-and-video-call-plugin-used", extension + legacy + call, "PASS"),
        ("extension-selection-missing", legacy, "FAIL"),
        ("legacy-selection-missing", extension, "FAIL"),
        ("startup-missing", "unrelated log\n", "UNREAD"),
        ("method-use-without-factory-selection", call + legacy, "FAIL"),
    ]
    for fallback in ("Use default ExtensionPluginFactory",
                     "ExtensionPluginFactoryBase: makeImsCallPlugin()",
                     "Use default LegacyComponentFactory"):
        cases.append((fallback, extension + legacy + fallback, "FAIL"))
    if args.trace:
        cases.append(("captured-boot", args.trace.read_text(errors="replace"), "PASS"))
    script = '''ims_logs="$(cat "$1")"
has() { printf '%s\\n' "$2" | grep -q -- "$1"; }
ok() { printf 'PASS\\n'; }
no() { printf 'FAIL\\n'; }
skip() { printf 'UNREAD\\n'; }
''' + predicate
    rows = []
    with tempfile.TemporaryDirectory(prefix="ims-factory-test-") as directory:
        path = Path(directory) / "trace.txt"
        for name, log, expected in cases:
            path.write_text(log)
            run = subprocess.run(["bash", "-c", script, "fixture", str(path)],
                                 capture_output=True, text=True, timeout=10)
            actual = run.stdout.strip()
            rows.append(dict(case=name, expected=expected, actual=actual,
                             passed=run.returncode == 0 and actual == expected,
                             returncode=run.returncode, stderr=run.stderr))
    result = dict(passed=sum(row["passed"] for row in rows), total=len(rows), cases=rows,
                  verifier_sha256=hashlib.sha256(args.verifier.read_bytes()).hexdigest(),
                  runner_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    if args.trace:
        result["trace_sha256"] = hashlib.sha256(args.trace.read_bytes()).hexdigest()
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return int(result["passed"] != result["total"])


if __name__ == "__main__":
    raise SystemExit(main())
