#!/usr/bin/env python3
# Copyright 2026 The LineageOS Project
# SPDX-License-Identifier: Apache-2.0
"""Compile the real HAL, Q libgatekeeper and portable scrypt; no Android build."""

import argparse
import hashlib
import os
from pathlib import Path
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("android_root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = args.android_root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    module = Path(__file__).resolve().parents[1]
    includes = [root / path for path in (
        "system/gatekeeper/include", "hardware/libhardware/include",
        "system/core/libcutils/include", "system/core/libsystem/include",
        "external/scrypt", "external/scrypt/lib/crypto", "external/scrypt/lib/util",
    )]
    common = ["-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    common += [f"-I{path}" for path in includes]
    commands = [
        ["clang", "-std=gnu11", *common, "-DHAVE_CONFIG_H", "-DUSE_OPENSSL_PBKDF2",
         "-c", str(root / "external/scrypt/lib/crypto/crypto_scrypt-ref.c"),
         "-o", str(output / "scrypt.o")],
        # Q clang-r353983c1 does not enable sized delete. Keep that ABI when
        # compiling the unchanged Q libgatekeeper (see README.md).
        ["clang++", "-std=gnu++17", "-fno-sized-deallocation", *common,
         "-Wall", "-Wextra", "-Werror", "-pthread",
         str(module / "module.cpp"), str(module / "tests/gatekeeper_test.cpp"),
         str(root / "system/gatekeeper/gatekeeper.cpp"),
         str(root / "system/gatekeeper/gatekeeper_messages.cpp"), str(output / "scrypt.o"),
         "-Wl,--wrap=RAND_bytes", "-Wl,--wrap=crypto_scrypt", "-Wl,--wrap=clock_gettime",
         "-lcrypto", "-o", str(output / "gatekeeper-test")],
    ]
    for command in commands:
        subprocess.run(command, check=True)

    # Independently encode the stock little-endian handle and derive its
    # signature with Python/OpenSSL, not the HAL's scrypt implementation.
    metadata = struct.pack("<BQQ", 2, 0x0123456789abcdef, 1)
    salt = struct.pack("<Q", 0xfedcba9876543210)
    signature = hashlib.scrypt(metadata + b"independent legacy vector", salt=salt,
                               n=16384, r=8, p=1, dklen=32)
    vector = output / "legacy-handle.bin"
    vector.write_bytes(metadata + salt + signature + b"\x01")
    environment = os.environ.copy()
    environment["ASAN_OPTIONS"] = "detect_leaks=1:halt_on_error=1"
    environment["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    result = subprocess.run([str(output / "gatekeeper-test"), str(vector)],
                            env=environment, text=True, capture_output=True)
    (output / "result.txt").write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end="")
    result.check_returncode()


if __name__ == "__main__":
    main()
