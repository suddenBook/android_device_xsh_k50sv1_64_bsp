#!/usr/bin/env python3
"""Build an isolated Java Wi-Fi Direct group probe with the installed Android SDK."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import zipfile


BASE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, default=Path("/home/desmond/Android/Sdk"))
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    tools = sdk / "build-tools/36.1.0"
    platform = sdk / "platforms/android-36/android.jar"
    out = BASE / "out"
    if out.is_symlink():
        raise RuntimeError("The disposable output directory must not be a symlink")
    if out.exists():
        shutil.rmtree(out)
    for name in ("classes", "dex"):
        (out / name).mkdir(parents=True)

    def run(command):
        subprocess.run([str(item) for item in command], cwd=BASE, check=True)

    java = BASE / "P2pProbeActivity.java"
    manifest = BASE / "AndroidManifest.xml"
    run(["javac", "--release", "8", "-classpath", platform, "-d", out / "classes", java])
    run([tools / "d8", "--release", "--min-api", "26", "--lib", platform,
         "--output", out / "dex", *sorted((out / "classes").rglob("*.class"))])
    unsigned = out / "unsigned.apk"
    run([tools / "aapt2", "link", "--manifest", manifest, "-I", platform, "-o", unsigned])
    with zipfile.ZipFile(unsigned, "a") as archive:
        archive.write(out / "dex/classes.dex", "classes.dex")
    run([tools / "zipalign", "-f", "4", unsigned, out / "aligned.apk"])

    signing = BASE / "signing"
    signing.mkdir(mode=0o700, exist_ok=True)
    signing.chmod(0o700)
    key = signing / "test-only.p12"
    password = signing / "password.txt"
    if key.exists() != password.exists():
        raise RuntimeError("Incomplete test-only signing key/password pair")
    if not key.exists():
        descriptor = os.open(password, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(secrets.token_hex(24) + "\n")
        previous = os.umask(0o077)
        try:
            run(["keytool", "-genkeypair", "-alias", "p2p-probe", "-keyalg", "RSA",
                 "-keysize", "2048", "-validity", "3650", "-storetype", "PKCS12",
                 "-keystore", key, "-storepass:file", password, "-keypass:file", password,
                 "-dname", "CN=K50 P2P Probe Test Only,O=Local Test,C=XX", "-noprompt"])
        finally:
            os.umask(previous)
    key.chmod(0o600)
    password.chmod(0o600)
    apk = out / "k50-p2p-probe.apk"
    run([tools / "apksigner", "sign", "--ks", key, "--ks-pass", f"file:{password}",
         "--min-sdk-version", "26", "--v4-signing-enabled", "false",
         "--out", apk, out / "aligned.apk"])
    run([tools / "apksigner", "verify", "--verbose", apk])
    badging = subprocess.check_output([str(tools / "aapt2"), "dump", "badging", str(apk)], text=True)
    permissions = {line.split("name='")[1].split("'")[0]
                   for line in badging.splitlines() if line.startswith("uses-permission:")}
    expected = {"android.permission.ACCESS_WIFI_STATE",
                "android.permission.CHANGE_WIFI_STATE",
                "android.permission.ACCESS_FINE_LOCATION"}
    if permissions != expected:
        raise RuntimeError(f"Unexpected P2P probe permissions: {permissions}")
    provenance = {
        "apk_sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
        "sources": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (java, manifest, Path(__file__).resolve())},
        "sdk": str(sdk), "compile_platform": "android-36",
        "build_tools": "36.1.0", "runtime_tested": False,
    }
    (out / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"BUILD_OK {apk} sha256={provenance['apk_sha256']}")


if __name__ == "__main__":
    main()
