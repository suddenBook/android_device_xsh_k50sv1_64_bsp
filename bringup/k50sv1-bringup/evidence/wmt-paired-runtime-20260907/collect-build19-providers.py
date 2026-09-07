#!/usr/bin/env python3
"""Bind the completed clean build's replaced native files to their producers."""
import hashlib
import json
import re
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parent
ROOT = BASE / "build-project/lineage-17.1"
OUT = ROOT / "out/target/product/k50sv1_64_bsp"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    receipt = OUT / "K50SV1-BUILD-RECEIPT"
    if not receipt.is_file() or "build.clean_output=true\n" not in receipt.read_text():
        raise RuntimeError("A successful clean-build receipt is required")
    expected = {
        "wmt_loader": ("device/xsh/k50sv1_64_bsp/wmt-loader", {"arm64"}),
        "wmt_launcher": ("device/xsh/k50sv1_64_bsp/wmt-launcher", {"arm64"}),
        "libtinycompress": ("external/tinycompress", {"arm", "arm64"}),
        "audio.bluetooth.default": ("system/bt/audio_bluetooth_hw", {"arm", "arm64"}),
        "android.hardware.graphics.allocator@2.0-impl": (
            "hardware/interfaces/graphics/allocator/2.0/default", {"arm", "arm64"}),
        "android.hardware.graphics.mapper@2.0-impl": (
            "hardware/interfaces/graphics/mapper/2.0/default", {"arm", "arm64"}),
        "android.hardware.graphics.composer@2.1-impl": (
            "hardware/interfaces/graphics/composer/2.1/default", {"arm", "arm64"}),
        "libbluetooth_audio_session": (
            "hardware/interfaces/bluetooth/audio/2.0/default", {"arm", "arm64"}),
        "android.hardware.bluetooth.audio@2.0-impl": (
            "hardware/interfaces/bluetooth/audio/2.0/default", {"arm", "arm64"}),
        "android.hardware.bluetooth@1.0-service": (
            "hardware/interfaces/bluetooth/1.0/default", {"arm64"}),
        "android.hardware.gnss@2.0-service-k50": (
            "device/xsh/k50sv1_64_bsp/gnss-service", {"arm64"}),
        "android.hardware.sensors@2.0-service": (
            "device/xsh/k50sv1_64_bsp/sensors-hal", {"arm64"}),
        "gatekeeper.default": ("device/xsh/k50sv1_64_bsp/gatekeeper", {"arm64"}),
        "wlan_assistant": ("device/xsh/k50sv1_64_bsp/wlan-assistant", {"arm64"}),
    }
    rows = []
    seen = set()

    def record(module, arch, source_path, artifact, installed):
        key = (module, arch)
        if key in seen:
            raise RuntimeError(f"Duplicate installed producer: {key}")
        seen.add(key)
        if not artifact.is_file() or not installed.is_file():
            raise RuntimeError(f"Missing artifact or install for {key}")
        if digest(artifact) != digest(installed):
            raise RuntimeError(f"Producer/install byte mismatch: {key}")
        rows.append({"module": module, "arch": arch, "source_path": source_path,
                     "source_artifact": str(artifact.relative_to(ROOT)),
                     "installed": str(installed.relative_to(OUT)),
                     "sha256": digest(installed), "bytes": installed.stat().st_size,
                     "matches_source_output": True})

    generated_make = ROOT / "out/soong/Android-lineage_k50sv1_64_bsp.mk"
    for block in generated_make.read_text().split("include $(CLEAR_VARS)"):
        values = dict(re.findall(r"^(LOCAL_[A-Z_]+) := (.*)$", block, re.M))
        module = values.get("LOCAL_MODULE")
        if module not in expected:
            continue
        if not any(values.get(k) == "true" for k in
                   ("LOCAL_VENDOR_MODULE", "LOCAL_PROPRIETARY_MODULE")):
            continue
        source, arches = expected[module]
        arch = values["LOCAL_MODULE_TARGET_ARCH"]
        if values["LOCAL_PATH"] != source or arch not in arches:
            raise RuntimeError(f"Unexpected source or architecture: {module}: {values}")
        artifact = Path(values["LOCAL_PREBUILT_MODULE_FILE"])
        directory = values["LOCAL_MODULE_PATH"].replace("$(OUT_DIR)", str(ROOT / "out"))
        installed = Path(directory) / (values.get("LOCAL_MODULE_STEM", module)
                                       + values.get("LOCAL_MODULE_SUFFIX", ""))
        record(module, arch, source, artifact, installed)
    required = {(module, arch) for module, (_, arches) in expected.items() for arch in arches}
    if seen != required:
        raise RuntimeError(f"Unresolved Soong producers: {required - seen}")

    # These two aliases compile existing AOSP C++ through device-owned Make recipes.
    legacy = [
        ("android.hardware.audio@5.0-service-mediatek", "arm", "audio",
         "obj_arm/EXECUTABLES/android.hardware.audio@5.0-service-mediatek_intermediates/android.hardware.audio@5.0-service-mediatek",
         "vendor/bin/hw/android.hardware.audio@5.0-service-mediatek",
         ["hardware/interfaces/audio/common/all-versions/default/service/service.cpp"]),
        ("libmtktinyxml", "arm64", "tinyxml",
         "obj/SHARED_LIBRARIES/libmtktinyxml_intermediates/libmtktinyxml.so",
         "vendor/lib64/libmtktinyxml.so",
         ["external/tinyxml/" + name for name in
          ("tinyxml.cpp", "tinyxmlparser.cpp", "tinyxmlerror.cpp", "tinystr.cpp")]),
    ]
    for module, arch, directory, artifact, installed, sources in legacy:
        source_path = "device/xsh/k50sv1_64_bsp/" + directory
        recipe = ROOT / source_path / "Android.mk"
        recipe_text = recipe.read_text()
        if "include $(BUILD_PREBUILT)" in recipe_text:
            raise RuntimeError(f"Unexpected prebuilt recipe: {module}")
        if any("../../../../" + source not in recipe_text for source in sources):
            raise RuntimeError(f"AOSP source selection changed: {module}")
        record(module, arch, source_path, OUT / artifact, OUT / installed)
        rows[-1]["source_files"] = {path: digest(ROOT / path) for path in sources}
        rows[-1]["recipe_sha256"] = digest(recipe)

    obsolete = [
        "vendor/bin/hw/android.hardware.bluetooth@1.0-service-mediatek",
        "vendor/bin/hw/android.hardware.gnss@2.0-service-mediatek",
        "vendor/etc/init/android.hardware.bluetooth@1.0-service-mediatek.rc",
        "vendor/etc/init/android.hardware.gnss@2.0-service-mediatek.rc",
        "vendor/lib/hw/android.hardware.bluetooth.audio@2.0-impl-mediatek.so",
        "vendor/lib/libbluetooth_audio_session_mediatek.so",
        "vendor/lib64/libbluetooth_audio_session_mediatek.so",
    ]
    if any((OUT / path).exists() for path in obsolete):
        raise RuntimeError("An obsolete service/provider/session path remains installed")
    policy_tool = ROOT.parent / "work/k50sv1-bringup/tools/check-launcher-policy.py"
    policy = subprocess.run(["python3", str(policy_tool), "product", "--lineage-root", str(ROOT),
                             "--product-out", str(OUT)], capture_output=True, text=True)
    (BASE / "build19-launcher-product-policy.json").write_text(policy.stdout)
    if policy.returncode:
        raise RuntimeError("Launcher product policy failed: " + policy.stderr + policy.stdout)
    launcher_policy = json.loads(policy.stdout)
    if launcher_policy.get("status") != "PASS":
        raise RuntimeError("Launcher product policy did not return PASS")
    result = {"status": "PASS", "build_receipt_sha256": digest(receipt),
              "generated_make_sha256": digest(generated_make), "native_file_count": len(rows),
              "native_providers": rows, "obsolete_paths_absent": obsolete,
              "launcher_policy_status": launcher_policy["status"], "handset_tested": False}
    (BASE / "build19-native-providers.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"PASS: {len(rows)} installed native files match their source outputs; "
          f"{len(obsolete)} obsolete paths absent; launcher removal policy passes")


if __name__ == "__main__":
    main()
