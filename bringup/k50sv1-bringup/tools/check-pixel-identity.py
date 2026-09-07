#!/usr/bin/env python3
"""Fail-closed source check for the narrow Android-10 Coral Play identity."""

from __future__ import annotations

import re
import shlex
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parent
DEVICE = (
    TOOL_DIR / "../../../lineage-17.1/device/xsh/k50sv1_64_bsp"
).resolve()
CORAL_FINGERPRINT = (
    "google/coral/coral:10/QQ3A.200805.001/6578210:user/release-keys"
)
CORAL_DESCRIPTION = "coral-user 10 QQ3A.200805.001 6578210 release-keys"


def fail(message: str) -> None:
    raise SystemExit(f"Pixel identity source check failed: {message}")


def ordinary(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        fail(f"missing or symlinked source file: {path}")


def properties(path: Path) -> dict[str, str]:
    ordinary(path)
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            fail(f"malformed property in {path.name}: {line}")
        # Strip both halves. Android's property loader trims whitespace around
        # the `=`, so `ro.build.version.sdk = 30` sets the property on-device
        # while an untrimmed key misses forbidden_property_keys entirely -- the
        # set is matched with `in`, not with startswith, for exactly the
        # ro.build.version.* and ro.vendor.build.security_patch entries that
        # matter most here.
        key, value = (part.strip() for part in line.split("=", 1))
        if not key or key in result:
            fail(f"missing or duplicate property {key!r} in {path.name}")
        result[key] = value
    return result


def one_make_value(text: str, name: str) -> str:
    matches = re.findall(rf"(?m)^{re.escape(name)}\s*:?=\s*(\S.*)$", text)
    if len(matches) != 1:
        fail(f"expected exactly one {name} assignment")
    return matches[0].strip()


def make_assignments(path: Path) -> list[tuple[str, str, str]]:
    """Parse the simple assignment subset used by Android product makefiles."""
    ordinary(path)
    logical: list[str] = []
    pending = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        continued = stripped.endswith("\\")
        if continued:
            stripped = stripped[:-1].rstrip()
        pending = f"{pending} {stripped}".strip()
        if not continued:
            logical.append(pending)
            pending = ""
    if pending:
        fail(f"unterminated Make continuation in {path}")

    result: list[tuple[str, str, str]] = []
    for line in logical:
        match = re.match(r"^([A-Za-z0-9_.-]+)\s*([:+?]?=)\s*(.*?)\s*$", line)
        if match:
            result.append((match.group(1), match.group(2), match.group(3)))
    return result


def main() -> None:
    expected_product = {
        "ro.product.product.brand": "google",
        "ro.product.product.device": "coral",
        "ro.product.product.manufacturer": "Google",
        "ro.product.product.model": "Pixel 4 XL",
        "ro.product.product.name": "coral",
    }
    if properties(DEVICE / "product.prop") != expected_product:
        fail("product.prop is not the exact Pixel 4 XL product namespace")
    if properties(DEVICE / "system.prop") != {
        "ro.build.fingerprint": CORAL_FINGERPRINT
    }:
        fail("system.prop is not the exact canonical Coral fingerprint")

    board_path = DEVICE / "BoardConfig.mk"
    product_path = DEVICE / "lineage_k50sv1_64_bsp.mk"
    ordinary(board_path)
    ordinary(product_path)
    board = board_path.read_text(encoding="utf-8")
    product = product_path.read_text(encoding="utf-8")

    expected_make = {
        "TARGET_BOARD_PLATFORM": "mt6755",
        "TARGET_BOOTLOADER_BOARD_NAME": "k50sv1_64_bsp",
        "TARGET_OTA_ASSERT_DEVICE": "k50sv1_64_bsp",
        "PRODUCT_NAME": "lineage_k50sv1_64_bsp",
        "PRODUCT_DEVICE": "k50sv1_64_bsp",
        "PRODUCT_BRAND": "XSH",
        "PRODUCT_MODEL": "F212",
        "PRODUCT_MANUFACTURER": "XSH",
        "VENDOR_SECURITY_PATCH": "2020-08-05",
    }
    for name, expected in expected_make.items():
        source = board if name.startswith("TARGET_") or name == "VENDOR_SECURITY_PATCH" else product
        if one_make_value(source, name) != expected:
            fail(f"{name} no longer preserves {expected}")

    make_files = sorted(DEVICE.rglob("*.mk"))
    all_assignments: list[tuple[Path, str, str, str]] = []
    for make_file in make_files:
        all_assignments.extend(
            (make_file, name, operator, value)
            for name, operator, value in make_assignments(make_file)
        )

    expected_locations = {
        "TARGET_BOARD_PLATFORM": board_path,
        "TARGET_BOOTLOADER_BOARD_NAME": board_path,
        "TARGET_OTA_ASSERT_DEVICE": board_path,
        "VENDOR_SECURITY_PATCH": board_path,
        "PRODUCT_NAME": product_path,
        "PRODUCT_DEVICE": product_path,
        "PRODUCT_BRAND": product_path,
        "PRODUCT_MODEL": product_path,
        "PRODUCT_MANUFACTURER": product_path,
    }
    for name, expected_path in expected_locations.items():
        records = [record for record in all_assignments if record[1] == name]
        if len(records) != 1 or records[0][0] != expected_path:
            fail(f"{name} must have one assignment in {expected_path.name}")

    override_records = [
        record for record in all_assignments if record[1] == "PRODUCT_BUILD_PROP_OVERRIDES"
    ]
    if len(override_records) != 1 or override_records[0][0] != product_path:
        fail("expected one device-local PRODUCT_BUILD_PROP_OVERRIDES assignment")
    try:
        override_tokens = shlex.split(override_records[0][3])
    except ValueError as error:
        fail(f"malformed PRODUCT_BUILD_PROP_OVERRIDES: {error}")
    if override_tokens != [
        f"PRIVATE_BUILD_DESC={CORAL_DESCRIPTION}",
        "BUILD_DISPLAY_ID=QQ3A.200805.001",
    ]:
        fail("product build overrides exceed the description/display-ID boundary")

    forbidden_make_names = {
        "BUILD_FINGERPRINT",
        "BUILD_ID",
        "BUILD_NUMBER",
        "BUILD_VERSION_TAGS",
        "PLATFORM_SECURITY_PATCH",
        "PLATFORM_SDK_VERSION",
        "PLATFORM_VERSION",
    }
    for make_file, name, _operator, _value in all_assignments:
        if name in forbidden_make_names:
            fail(f"forbidden semantic Make assignment {name} in {make_file}")
        if name == "PRODUCT_SHIPPING_API_LEVEL" and _value != "26":
            fail(f"launch API override is not 26 in {make_file}")

    forbidden = {
        "PRODUCT_DEVICE := coral": "structural product-device spoof",
        "TARGET_BOARD_PLATFORM := msmnile": "Qualcomm platform spoof",
        "ro.product.first_api_level=29": "launch API spoof",
        "ro.build.version.security_patch=2020-08-05": "platform SPL downgrade",
        "ro.build.expect.bootloader=": "Pixel bootloader expectation",
        "ro.build.expect.baseband=": "Pixel baseband expectation",
    }
    # Every makefile and every property file under the device tree, not four
    # named files. Android Q appends <device>/vendor.prop to vendor/build.prop
    # and <device>/product.prop to product/build.prop with identical effect on
    # the resulting properties, so `ro.build.expect.bootloader=` written into
    # vendor.prop -- which this scope did not include -- reached the image
    # while this check passed. The same applies to any .mk that is included by
    # the product but is neither BoardConfig.mk nor lineage_k50sv1_64_bsp.mk.
    prop_files = sorted(DEVICE.rglob("*.prop"))
    scoped_text = "\n".join(
        [make_file.read_text(encoding="utf-8") for make_file in make_files]
        + [prop_path.read_text(encoding="utf-8") for prop_path in prop_files]
    )
    for token, label in forbidden.items():
        if token in scoped_text:
            fail(f"forbidden {label} found")

    forbidden_property_keys = {
        "ro.product.brand",
        "ro.product.device",
        "ro.product.manufacturer",
        "ro.product.model",
        "ro.product.name",
        "ro.build.version.release",
        "ro.build.version.sdk",
        "ro.build.version.security_patch",
        "ro.vendor.build.security_patch",
        "ro.product.first_api_level",
    }
    for prop_path in prop_files:
        ordinary(prop_path)
        for line_number, raw in enumerate(
            prop_path.read_text(encoding="utf-8").splitlines(), 1
        ):
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = (part.strip() for part in line.split("=", 1))
            if key == "ro.build.fingerprint":
                if prop_path != DEVICE / "system.prop" or value != CORAL_FINGERPRINT:
                    fail(f"unexpected public fingerprint source at {prop_path}:{line_number}")
                continue
            # Android Q resolves the public ro.product.<name> aliases by walking
            # ro.product.property_source_order across the partition namespaces
            # (system, product, vendor, odm, ...). Naming only two of those
            # namespaces left the rest open: ro.product.odm.model plus a
            # reordered source list moves the public model off product.prop
            # without touching a single key this check knew about. Only the five
            # audited ro.product.product.* keys may exist, only in product.prop,
            # and the resolution order itself may not be redefined here.
            if key == "ro.product.property_source_order":
                fail(f"partition resolution order override at {prop_path}:{line_number}")
            if key.startswith("ro.product."):
                if (
                    key not in expected_product
                    or prop_path != DEVICE / "product.prop"
                ):
                    fail(f"public product-identity override at {prop_path}:{line_number}")
                continue
            # ro.build.expect.bootloader / .baseband are the Pixel expectations
            # the forbidden-token scan covers as strings; catching them as keys
            # names the file and line, and covers any partition's .prop.
            if key.startswith("ro.build.expect."):
                fail(f"Pixel bootloader/baseband expectation at {prop_path}:{line_number}")
            if key in forbidden_property_keys:
                fail(f"structural/version property override at {prop_path}:{line_number}")

    carrier_xml = DEVICE / "overlay/packages/apps/CarrierConfig/res/xml/vendor.xml"
    ordinary(carrier_xml)
    # XML permits whitespace on both sides of the attribute '='; the parser
    # DefaultCarrierConfigService uses reads `device = "coral"` exactly as it
    # reads `device="coral"`, and the anchored `\bdevice=` did not.
    if re.search(r"<carrier_config\b[^>]*\bdevice\s*=", carrier_xml.read_text()):
        fail("CarrierConfig still filters on the now-spoofed public Build.DEVICE")

    print(
        "Pixel identity source: PASS "
        "(public Coral identity; real k50sv1/mt6755 build, OTA, SPL and partition identity)"
    )


if __name__ == "__main__":
    main()
