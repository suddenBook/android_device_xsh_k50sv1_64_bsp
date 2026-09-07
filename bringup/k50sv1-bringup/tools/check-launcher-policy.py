#!/usr/bin/env python3
"""Check Niagara removal in source, built partitions, or a rooted Q handset."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET


TOOL_DIR = Path(__file__).resolve().parent
DEFAULT_ROOT = TOOL_DIR.parents[2] / "lineage-17.1"
PACKAGE = "bitpit.launcher"
HOME_PACKAGE = "com.android.launcher3"
HOME_CLASS = "com.android.launcher3.lineage.LineageLauncher"
FORBIDDEN = re.compile(r"niagara|bitpit[.]launcher", re.I)
TEXT_SUFFIXES = {".mk", ".bp", ".xml", ".rc", ".sh", ".py", ".prop", ".conf",
                 ".java", ".kt", ".c", ".cpp", ".h", ".txt"}
PARTITIONS = ("system", "vendor", "product", "odm", "system_ext")
ANDROID = "{http://schemas.android.com/apk/res/android}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def scan_tree(tree, report):
    require(tree.is_dir(), f"Missing directory: {tree}")
    count = 0
    for directory, names, files in os.walk(tree):
        names[:] = sorted(name for name in names if name != ".git")
        for name in names + sorted(files):
            path = Path(directory) / name
            require(not FORBIDDEN.search(str(path.relative_to(tree))),
                    f"Residual Niagara path: {path}")
            if path.is_file() and path.suffix in TEXT_SUFFIXES:
                require(not FORBIDDEN.search(path.read_text(errors="replace")),
                        f"Residual Niagara configuration: {path}")
                count += 1
    report.setdefault("scanned_trees", []).append({"path": str(tree), "text_files": count})


def check_source(root, report):
    device = root / "device/xsh/k50sv1_64_bsp"
    scan_tree(device, report)
    scan_tree(root / "vendor/xsh/k50sv1_64_bsp", report)
    for relative in (
            "configs/preferred-apps-trebuchet.xml",
            "overlay/packages/apps/PermissionController/res/values/config.xml"):
        require(not (device / relative).exists(), f"Obsolete HOME workaround: {relative}")
    common = (root / "vendor/lineage/config/common.mk").read_text()
    require(re.search(r"^\s+TrebuchetQuickStep\s*\\?$", common, re.M),
            "Inherited Lineage product no longer includes TrebuchetQuickStep")
    manifest = ET.parse(root / "packages/apps/Trebuchet/AndroidManifest.xml").getroot()
    activity = manifest.find(f"./application/activity[@{ANDROID}name='{HOME_CLASS}']")
    require(activity is not None, "Trebuchet HOME activity is missing")
    require(any(item.get(ANDROID + "name") == "android.intent.category.HOME"
                for item in activity.findall("./intent-filter/category")),
            "Trebuchet activity no longer handles HOME")
    report["home_policy"] = "upstream Q priority selection; inherited Trebuchet HOME"


def check_product(root, product, aapt, report):
    require((product / "system").is_dir() and (product / "vendor").is_dir(),
            "Built system and vendor trees are required")
    if aapt is None:
        aapt = root / "out/host/linux-x86/bin/aapt2"
    require(aapt.is_file(), f"Missing aapt2: {aapt}")
    apks = []
    for partition in PARTITIONS:
        tree = product / partition
        if not tree.exists():
            continue
        scan_tree(tree, report)
        for apk in sorted(tree.rglob("*.apk")):
            result = subprocess.run([str(aapt), "dump", "badging", str(apk)],
                                    capture_output=True, text=True, timeout=30)
            require(result.returncode == 0, f"Unreadable APK manifest: {apk}: {result.stderr}")
            match = re.search(r"^package: name='([^']+)'", result.stdout, re.M)
            require(match is not None, f"Missing package identity in APK: {apk}")
            package = match.group(1)
            require(not FORBIDDEN.search(package), f"Niagara APK packaged as {apk}: {package}")
            apks.append({"path": str(apk.relative_to(product)), "package": package})
    require(any(apk["package"] == HOME_PACKAGE for apk in apks),
            "Built partitions do not contain Trebuchet")
    report["apks"] = apks


def check_runtime(run, post_setup, report):
    users_text = run("users", "pm list users")
    users = re.findall(r"UserInfo\{(\d+):", users_text)
    require("0" in users, "User inventory was unreadable or lacks the primary user")
    for user in users:
        packages = run(f"packages-user-{user}", f"pm list packages -u --user {user}")
        lines = packages.splitlines()
        require("package:android" in lines and all(line.startswith("package:") for line in lines),
                f"Package inventory is incomplete for user {user}")
        require(not FORBIDDEN.search(packages), f"Niagara installed or retained for user {user}")
        require(f"package:{HOME_PACKAGE}" in lines, f"Trebuchet missing for user {user}")
        for setting in ("enabled_notification_listeners", "enabled_accessibility_services",
                        "enabled_notification_policy_access_packages"):
            value = run(f"{setting}-user-{user}", f"settings --user {user} get secure {setting}")
            require(bool(value.strip()), f"Unreadable user {user} setting {setting}")
            require(not FORBIDDEN.search(value), f"Niagara remains in user {user} setting {setting}")
    permissions = run("declared-permissions", "pm list permissions")
    require("permission:android.permission.INTERNET" in permissions,
            "Declared permission inventory was unreadable")
    require(not FORBIDDEN.search(permissions), "Niagara still declares permissions")
    # grep's rc=1 is the successful absence case; rc>=2 must stay an error.
    configs = run("installed-configurations", r'''
test -d /system/etc/permissions || exit 2
for partition in /system /vendor /product /odm /system_ext; do
    for name in permissions default-permissions preferred-apps sysconfig init; do
        directory="$partition/etc/$name"
        if [ -d "$directory" ]; then
            grep -R -n -i -E 'niagara|bitpit[.]launcher' "$directory"
            result=$?
            [ "$result" -le 1 ] || exit "$result"
        fi
    done
done
exit 0
''')
    require(not configs.strip(), f"Niagara installed configuration remains: {configs.strip()}")
    paths = run("residual-paths", r'''
for partition in /system /vendor /product /odm /system_ext; do
    for name in app priv-app etc; do
        directory="$partition/$name"
        if [ -d "$directory" ]; then
            find "$directory" -iname '*niagara*' -o -iname '*bitpit.launcher*' || exit $?
        fi
    done
done
for path in /data/app/*bitpit.launcher* /data/user/*/bitpit.launcher /data/user_de/*/bitpit.launcher /data/data/bitpit.launcher /data/misc/profiles/cur/*/bitpit.launcher /data/misc/profiles/ref/bitpit.launcher; do
    if [ -e "$path" ] || [ -L "$path" ]; then printf '%s\n' "$path"; fi
done
exit 0
''')
    require(not paths.strip(), f"Niagara APK, configuration, or data paths remain: {paths.strip()}")
    role_text = run("home-role", "cat /data/system/users/0/roles.xml")
    roles = ET.fromstring(role_text)
    require(not FORBIDDEN.search(role_text), "Niagara remains in the primary user's roles")
    holders = [item.get("name") for item in roles.findall("./role[@name='android.app.role.HOME']/holder")]
    resolved = run("home-resolver", "cmd package resolve-activity --brief --user 0 "
                   "-a android.intent.action.MAIN -c android.intent.category.HOME "
                   "-c android.intent.category.DEFAULT")
    require(bool(resolved.strip()) and not FORBIDDEN.search(resolved), "HOME resolver is unreadable or selects Niagara")
    if post_setup:
        require(holders == [HOME_PACKAGE], f"Post-setup HOME holders are {holders}")
        components = {f"{HOME_PACKAGE}/.lineage.LineageLauncher", f"{HOME_PACKAGE}/{HOME_CLASS}"}
        require(any(line.strip() in components for line in resolved.splitlines()),
                f"Post-setup HOME does not resolve to Trebuchet: {resolved.strip()}")
    report["users"] = users
    report["home_role_holders"] = holders
    report["post_setup_checked"] = post_setup


def read_remote(adb, serial, label, command, report):
    # roles.xml need not end in a newline; keep the status on its own line.
    wrapped = "(\n" + command + "\n)\n__k50_launcher_rc=$?\nprintf '\\n__K50_LAUNCHER_RC__=%s\\n' \"$__k50_launcher_rc\""
    result = subprocess.run([str(adb), "-s", serial, "shell", wrapped],
                            env=dict(os.environ, ADB_LIBUSB=os.environ.get("ADB_LIBUSB", "1")),
                            capture_output=True, text=True, timeout=60)
    report["commands"].append({"label": label, "command": command,
                               "returncode": result.returncode,
                               "stdout": result.stdout, "stderr": result.stderr})
    require(result.returncode == 0 and not result.stderr.strip(),
            f"Could not read {label}: rc={result.returncode} {result.stderr.strip()}")
    lines = result.stdout.splitlines()
    require(bool(lines) and lines[-1] == "__K50_LAUNCHER_RC__=0",
            f"Missing successful remote status for {label}")
    return "\n".join(lines[:-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    for name in ("source", "product"):
        child = subparsers.add_parser(name)
        child.add_argument("--lineage-root", type=Path, default=DEFAULT_ROOT)
        if name == "product":
            child.add_argument("--product-out", type=Path, required=True)
            child.add_argument("--aapt", type=Path)
    runtime = subparsers.add_parser("runtime")
    runtime.add_argument("--adb", type=Path, required=True)
    runtime.add_argument("--serial", required=True)
    runtime.add_argument("--post-setup", action="store_true")
    args = parser.parse_args()
    report = {"mode": args.mode, "status": "FAIL",
              "tool_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    try:
        if args.mode == "source":
            check_source(args.lineage_root.resolve(), report)
        elif args.mode == "product":
            check_product(args.lineage_root.resolve(), args.product_out.resolve(), args.aapt, report)
        else:
            report["commands"] = []

            def run(label, command):
                return read_remote(args.adb, args.serial, label, command, report)

            check_runtime(run, args.post_setup, report)
        report["status"] = "PASS"
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
    print(json.dumps(report, indent=2))
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
