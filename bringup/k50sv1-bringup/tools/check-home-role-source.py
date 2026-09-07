#!/usr/bin/env python3
"""Require the unmodified Q HOME policy and a device tree without Niagara."""

import argparse
from pathlib import Path
import subprocess
import sys

BASE = "d90ff6d3d7d15775edfc853dd59bf1e7f3e06f25"
TOOL_DIR = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lineage-root", type=Path,
                        default=TOOL_DIR.parents[2] / "lineage-17.1")
    args = parser.parse_args()
    root = args.lineage_root.resolve()
    source = root / "packages/apps/PermissionController"
    try:
        subprocess.run([sys.executable, str(TOOL_DIR / "check-launcher-policy.py"),
                        "source", "--lineage-root", str(root)], check=True)
        status = subprocess.check_output(
            ["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=source)
        if status:
            raise ValueError("PermissionController must have a clean committed source state")
        delta = subprocess.check_output(
            ["git", "-c", "core.abbrev=8", "diff", "--no-ext-diff", "--binary", BASE, "HEAD"],
            cwd=source)
        if delta:
            raise ValueError("PermissionController differs from the unmodified upstream Q base")
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"HOME role source check failed: {error}", file=sys.stderr)
        print("See upstream/README.md for the pinned local source branch.", file=sys.stderr)
        raise SystemExit(1)
    print("HOME role source: unmodified upstream Q tree; clean committed checkout")


if __name__ == "__main__":
    main()
