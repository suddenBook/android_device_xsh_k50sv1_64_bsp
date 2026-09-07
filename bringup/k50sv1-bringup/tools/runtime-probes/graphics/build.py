#!/usr/bin/env python3
"""Build and inspect the isolated ARMv7 graphics probe using an installed SDK/NDK."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import zipfile


BASE = Path(__file__).resolve().parent
BUILD = BASE / "build"
OUT = BASE / "out"
SIGNING = BASE / "signing"
APK_NAME = "k50-graphics-probe-armeabi-v7a.apk"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, default=Path("/home/desmond/Android/Sdk"))
    parser.add_argument("--build-tools", default="36.1.0")
    parser.add_argument("--ndk", default="30.0.15729638")
    parser.add_argument("--platform", default="android-36")
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    build_tools = sdk / "build-tools" / args.build_tools
    ndk = sdk / "ndk" / args.ndk
    llvm = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
    android_jar = sdk / "platforms" / args.platform / "android.jar"
    clang = llvm / "armv7a-linux-androideabi26-clang"
    readelf = llvm / "llvm-readelf"
    for path in [android_jar, clang, readelf] + [
        build_tools / name for name in ["aapt2", "d8", "zipalign", "apksigner"]
    ]:
        if not path.is_file():
            parser.error(f"Missing local tool or platform: {path}")
    for name in ["javac", "java", "keytool"]:
        if shutil.which(name) is None:
            parser.error(f"Missing executable: {name}")

    # Only this fixture's disposable intermediate directory is removed.
    if BUILD.exists():
        if BUILD.is_symlink():
            raise RuntimeError("Refusing a symlink at the build directory")
        shutil.rmtree(BUILD)
    for path in [BUILD / "classes", BUILD / "dex", BUILD / "lib/armeabi-v7a", OUT]:
        path.mkdir(parents=True, exist_ok=True)

    command_log = []
    with (OUT / "build.log").open("w", encoding="utf-8") as log:
        def run(command):
            command = [str(part) for part in command]
            command_log.append(command)
            line = "$ " + shlex.join(command)
            print(line, flush=True)
            log.write(line + "\n")
            log.flush()
            result = subprocess.run(command, cwd=BASE, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, check=False)
            print(result.stdout, end="", flush=True)
            log.write(result.stdout)
            log.flush()
            if result.returncode:
                raise RuntimeError(f"Command failed with exit status {result.returncode}: {line}")
            return result.stdout

        versions = {
            "javac": run(["javac", "-version"]).strip(),
            "java": run(["java", "-version"]).strip(),
            "clang": run([clang, "--version"]).strip(),
            "aapt2": run([build_tools / "aapt2", "version"]).strip(),
            "ndk_source_properties": (ndk / "source.properties").read_text(),
        }
        library = BUILD / "lib/armeabi-v7a/libgraphicsprobe.so"
        run([
            clang, "-std=c11", "-O2", "-g0", "-fPIC", "-fvisibility=hidden",
            "-ffunction-sections", "-fdata-sections", "-fstack-protector-strong",
            "-D_FORTIFY_SOURCE=2", "-Wall", "-Wextra", "-Werror", "-shared",
            "-Wl,--no-undefined", "-Wl,--as-needed", "-Wl,--gc-sections", "-Wl,--build-id=sha1",
            "-Wl,-soname,libgraphicsprobe.so", "-Wl,-z,relro,-z,now", "-Wl,-z,noexecstack",
            BASE / "jni/graphics_probe.c", "-landroid", "-llog", "-lEGL", "-lGLESv2", "-o", library,
        ])
        java_sources = sorted((BASE / "src").rglob("*.java"))
        run(["javac", "--release", "8", "-Xlint:all", "-Werror",
             "-classpath", android_jar, "-d", BUILD / "classes", *java_sources])
        classes = sorted((BUILD / "classes").rglob("*.class"))
        run([build_tools / "d8", "--release", "--min-api", "26", "--lib", android_jar,
             "--output", BUILD / "dex", *classes])
        resources = BUILD / "resources.apk"
        run([build_tools / "aapt2", "link", "--manifest", BASE / "AndroidManifest.xml",
             "-I", android_jar, "--min-sdk-version", "26", "--target-sdk-version", "29",
             "-o", resources])
        unsigned = BUILD / "unsigned.apk"
        with zipfile.ZipFile(resources) as source, zipfile.ZipFile(unsigned, "w") as destination:
            for entry in source.infolist():
                destination.writestr(entry, source.read(entry.filename))
            for path, name in [(BUILD / "dex/classes.dex", "classes.dex"),
                               (library, "lib/armeabi-v7a/libgraphicsprobe.so")]:
                info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                destination.writestr(info, path.read_bytes())
        aligned = BUILD / "aligned.apk"
        run([build_tools / "zipalign", "-f", "4", unsigned, aligned])

        # A locally generated key exists solely to install this test APK.
        SIGNING.mkdir(mode=0o700, exist_ok=True)
        SIGNING.chmod(0o700)
        key = SIGNING / "test-only.p12"
        password = SIGNING / "password.txt"
        if key.exists() != password.exists():
            raise RuntimeError("Signing key/password pair is incomplete; preserve and inspect it")
        if not key.exists():
            descriptor = os.open(password, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(secrets.token_hex(24) + "\n")
            previous_umask = os.umask(0o077)
            try:
                run(["keytool", "-genkeypair", "-alias", "graphics-probe", "-keyalg", "RSA",
                     "-keysize", "2048", "-validity", "3650", "-storetype", "PKCS12",
                     "-keystore", key, "-storepass:file", password, "-keypass:file", password,
                     "-dname", "CN=K50 Graphics Probe Test Only,O=Local Test,C=XX", "-noprompt"])
            finally:
                os.umask(previous_umask)
        for path in [key, password]:
            path.chmod(0o600)
            if stat.S_IMODE(path.stat().st_mode) != 0o600:
                raise RuntimeError(f"Signing file is not private: {path.name}")
        apk = OUT / APK_NAME
        run([build_tools / "apksigner", "sign", "--ks", key, "--ks-key-alias", "graphics-probe",
             "--ks-pass", f"file:{password}",
             "--min-sdk-version", "26", "--v1-signing-enabled", "true",
             "--v2-signing-enabled", "true", "--v3-signing-enabled", "false",
             "--v4-signing-enabled", "false", "--out", apk, aligned])
        verification = run([build_tools / "apksigner", "verify", "--verbose", "--print-certs", apk])
        run([build_tools / "zipalign", "-c", "-v", "4", apk])
        badging = run([build_tools / "aapt2", "dump", "badging", apk])
        elf = run([readelf, "-h", "-d", "--dyn-syms", library])
        with zipfile.ZipFile(apk) as archive:
            native_entries = [name for name in archive.namelist() if name.startswith("lib/")]
            if native_entries != ["lib/armeabi-v7a/libgraphicsprobe.so"]:
                raise RuntimeError(f"Unexpected native APK content: {native_entries}")
        if "Class:                             ELF32" not in elf or not re.search(r"Machine:\s+ARM\b", elf):
            raise RuntimeError("JNI ELF is not 32-bit ARM")
        needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", elf)
        required = {"libandroid.so", "liblog.so", "libEGL.so", "libGLESv2.so"}
        allowed = required | {"libc.so", "libm.so", "libdl.so"}
        if not required.issubset(needed) or set(needed) - allowed:
            raise RuntimeError(f"Unexpected JNI dependencies: {needed}")
        for marker in ["package: name='local.k50.graphicsprobe'", "minSdkVersion:'26'",
                       "targetSdkVersion:'29'", "native-code: 'armeabi-v7a'",
                       "launchable-activity: name='local.k50.graphicsprobe.GraphicsProbeActivity'"]:
            if marker not in badging:
                raise RuntimeError(f"APK metadata missing: {marker}")
        if "uses-permission:" in badging:
            raise RuntimeError("Probe must not request Android permissions")
        (OUT / "apk-verification.txt").write_text(verification + "\n" + badging, encoding="utf-8")
        (OUT / "native-elf.txt").write_text(elf, encoding="utf-8")
        inputs = [BASE / "AndroidManifest.xml", BASE / "jni/graphics_probe.c", Path(__file__).resolve()]
        inputs.extend(java_sources)
        provenance = {
            "built_at_utc": datetime.now(timezone.utc).isoformat(),
            "package": "local.k50.graphicsprobe", "abi": "armeabi-v7a",
            "min_sdk": 26, "target_sdk": 29,
            "compile_platform": args.platform, "build_tools": args.build_tools,
            "ndk": args.ndk, "versions": versions,
            "native_needed": needed, "runtime_tested": False,
            "render_modes": ["cpu", "egl"], "default_render_mode": "cpu",
            "apk_sha256": sha256(apk), "jni_sha256": sha256(library),
            "source_sha256": {str(path.relative_to(BASE)): sha256(path) for path in inputs},
            "commands": command_log,
        }
        (OUT / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
        (OUT / "SHA256SUMS").write_text(f"{sha256(apk)}  {APK_NAME}\n", encoding="utf-8")
        apk.chmod(0o644)
        print(f"BUILD_OK apk={apk} sha256={sha256(apk)}")


if __name__ == "__main__":
    main()
