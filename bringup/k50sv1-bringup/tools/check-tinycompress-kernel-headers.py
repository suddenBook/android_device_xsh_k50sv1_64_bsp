#!/usr/bin/env python3
"""Check the exact local Tinycompress integration required by the device header module."""

import argparse
from pathlib import Path
import subprocess
import sys

BASE = "848ec3ad67cc414294d18776a2b4d644be95fd64"
TOOL_DIR = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lineage-root", type=Path,
                        default=TOOL_DIR.parents[2] / "lineage-17.1")
    args = parser.parse_args()
    root = args.lineage_root.resolve()
    selected = root / "device/xsh/k50sv1_64_bsp/tinycompress/Android.bp"
    if not selected.exists():
        return
    source = root / "external/tinycompress"
    patch = TOOL_DIR.parent / "upstream/tinycompress-kernel-headers.patch"
    try:
        status = subprocess.check_output(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=source)
        if status:
            raise ValueError("external/tinycompress must have a clean committed source state")
        delta = subprocess.check_output(
            ["git", "-c", "core.abbrev=8", "diff", "--no-ext-diff", "--binary", BASE, "HEAD"],
            cwd=source)
        if not delta or delta != patch.read_bytes():
            raise ValueError("source does not exactly match the recorded audio-header dependency patch")
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"Tinycompress source check failed: {error}", file=sys.stderr)
        print("See upstream/README.md for the pinned local source branch.", file=sys.stderr)
        raise SystemExit(1)
    print("Tinycompress source: exact committed audio-header dependency patch; clean checkout")


if __name__ == "__main__":
    main()
