#!/usr/bin/env python3
"""Validate the device-owned CarrierConfig identity matrix without a build."""

from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parent
DEFAULT_XML = (
    TOOL_DIR
    / "../../../lineage-17.1/device/xsh/k50sv1_64_bsp"
    / "overlay/packages/apps/CarrierConfig/res/xml/vendor.xml"
).resolve()
DEVICE = "k50sv1_64_bsp"


def fail(message: str) -> None:
    raise SystemExit(f"CarrierConfig overlay check failed: {message}")


def value_of(node: ET.Element) -> object:
    # Arrays carry their payload in child <item value="..."/> elements rather
    # than a value attribute -- the form AOSP's own CarrierConfig assets use
    # (see packages/apps/CarrierConfig/assets/*.xml). This function used to
    # assume every node had a value attribute and rejected any array outright.
    if node.tag in {"string-array", "int-array"}:
        items = list(node)
        if any(item.tag != "item" or "value" not in item.attrib for item in items):
            fail(f"{node.tag} {node.attrib.get('name', '<unnamed>')} has a malformed item")
        declared = node.attrib.get("num")
        if declared is not None and declared != str(len(items)):
            # DefaultCarrierConfigService trusts num; a stale one silently
            # truncates or over-reads the array.
            fail(f"{node.tag} {node.attrib.get('name', '<unnamed>')} declares "
                 f"num={declared} but holds {len(items)} items")
        values = [item.attrib["value"] for item in items]
        if node.tag == "int-array":
            try:
                return [int(v) for v in values]
            except ValueError:
                fail(f"invalid integer in {node.attrib.get('name', '<unnamed>')}")
        return values
    raw = node.attrib.get("value")
    if raw is None:
        fail(f"{node.tag} {node.attrib.get('name', '<unnamed>')} has no value")
    if node.tag == "boolean":
        if raw not in {"true", "false"}:
            fail(f"invalid boolean value {raw}")
        return raw == "true"
    if node.tag == "int":
        try:
            return int(raw)
        except ValueError:
            fail(f"invalid integer value {raw}")
    fail(f"unsupported value element {node.tag}")


def fragment_values(fragment: ET.Element) -> dict[str, object]:
    values: dict[str, object] = {}
    for child in fragment:
        name = child.attrib.get("name")
        if not name or name in values:
            fail(f"missing or duplicate key {name!r}")
        values[name] = value_of(child)
    return values


def matches(fragment: ET.Element, *, mcc: str, mnc: str, imsi: str) -> bool:
    filters = fragment.attrib
    if filters.get("device", DEVICE).lower() != DEVICE:
        return False
    if "mcc" in filters and filters["mcc"] != mcc:
        return False
    if "mnc" in filters and filters["mnc"] != mnc:
        return False
    if "imsi" in filters and re.fullmatch(filters["imsi"], imsi, re.IGNORECASE) is None:
        return False
    return True


def resolved(fragments: list[ET.Element], *, mcc: str, mnc: str, imsi: str) -> dict[str, object]:
    result: dict[str, object] = {}
    for fragment in fragments:
        if matches(fragment, mcc=mcc, mnc=mnc, imsi=imsi):
            result.update(fragment_values(fragment))
    return result


def parse_retry_config(config_strings, apn_type):
    """Resolve one APN type's bucket the way RetryManager.configure() does.

    Returns (mRetryForever, mMaxRetryCount, [delay_ms, ...]).
    Mirrors frameworks/opt/telephony RetryManager.java:246-322 and :364-376:
    the bucket whose name matches wins, `others` is the fallback, `infinite`
    is the only value that sets mRetryForever, and mMaxRetryCount is raised to
    the number of delay entries when the config does not set a larger one.
    """
    chosen = None
    for entry in config_strings:
        name, _, rest = entry.partition(":")
        if name.strip() == apn_type:
            chosen = rest
            break
        if name.strip() == "others" and chosen is None:
            chosen = rest
    if chosen is None:
        fail(f"no retry bucket resolves for apn type {apn_type!r}")

    retry_forever = False
    max_retry_count = 0
    delays = []
    for token in chosen.split(","):
        key, sep, value = token.partition("=")
        if sep:
            key, value = key.strip(), value.strip()
            if key == "max_retries":
                if value == "infinite":
                    retry_forever = True
                else:
                    max_retry_count = int(value)
            elif key != "default_randomization":
                fail(f"unrecognised retry config name/value pair: {token!r}")
        else:
            # A delay, with an optional ":randomization" suffix.
            delays.append(int(token.split(":", 1)[0].strip()))
    if len(delays) > max_retry_count:
        max_retry_count = len(delays)
    return retry_forever, max_retry_count, delays


def main() -> None:
    if len(sys.argv) > 2:
        fail("usage: check-carrier-config-overlay.py [vendor.xml]")
    xml_path = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else DEFAULT_XML
    if not xml_path.is_file() or xml_path.is_symlink():
        fail(f"missing or symlinked XML: {xml_path}")

    root = ET.parse(xml_path).getroot()
    if root.tag != "carrier_config_list":
        fail(f"unexpected root {root.tag}")
    fragments = list(root)
    if len(fragments) != 4 or any(node.tag != "carrier_config" for node in fragments):
        fail("expected exactly four carrier_config fragments")
    if any("cid" in fragment.attrib for fragment in fragments):
        fail("cid filters are broken on this Android-Q branch")

    # Order matters: DefaultCarrierConfigService merges matching fragments in
    # file order, so the device-global emergency fragment comes first and the
    # carrier fragments follow. CMCC and CU are matched by IMSI prefix because
    # each carrier owns several MNCs (TelephonyProvider carrier_list.textpb
    # canonical_id 1435/1436, MediaTek OperatorUtils OP01/OP02).
    expected_filters = [
        {},
        {"mcc": "460", "imsi": r"460(00|02|04|07|08).*"},
        {"mcc": "460", "imsi": r"460(01|06|09).*"},
        {
            "mcc": "204",
            "mnc": "04",
            "imsi": r"20404[01245789].*",
        },
    ]
    if [fragment.attrib for fragment in fragments] != expected_filters:
        fail("carrier fragment filters or order changed")

    # The device-wide fragment. The IMS retry curve is here rather than per
    # carrier because an IMS PDN that cannot come up is not carrier-specific;
    # E-180 measured one setup attempt every 8.5 s, forever, on a roaming SIM.
    # `ims` would otherwise fall into the `others` bucket, whose max_retries
    # cannot accumulate (RetryManager.setWaitingApns resets it every round).
    ims_retry = [
        "default:default_randomization=2000,5000,10000,20000,40000,80000:5000,"
        "160000:5000,320000:5000,640000:5000,1280000:5000,1800000:5000",
        "mms:default_randomization=2000,5000,10000,20000,40000,80000:5000,"
        "160000:5000,320000:5000,640000:5000,1280000:5000,1800000:5000",
        "ims:max_retries=infinite,default_randomization=2000,5000,10000,30000,"
        "60000,300000:5000,900000:5000,1800000:5000",
        "others:max_retries=3, 5000, 5000, 5000",
    ]
    emergency_only = {
        "carrier_use_ims_first_for_emergency_bool": False,
        "carrier_data_call_retry_config_strings": ims_retry,
    }
    # CMCC and CU get the two IMS availability bools and nothing else: the
    # VoLTE and Wi-Fi calling switches appear with AOSP's defaults (VoLTE on,
    # WFC off until the user turns it on). Owner instruction, E-170;
    # stock reaches the same state through MtkCarrierConfigManager.putDefault(),
    # which flips both defaults to true for every SIM.
    ims_switches = {
        **emergency_only,
        "carrier_volte_available_bool": True,
        "carrier_wfc_ims_available_bool": True,
    }
    expected_matrix = [
        ("China Mobile", "460", "00", "460001234567890", ims_switches),
        ("China Mobile 46002", "460", "02", "460021234567890", ims_switches),
        ("China Mobile 46007", "460", "07", "460071234567890", ims_switches),
        ("China Mobile 46008", "460", "08", "460081234567890", ims_switches),
        ("China Unicom", "460", "01", "460011234567890", ims_switches),
        ("China Unicom 46006", "460", "06", "460061234567890", ims_switches),
        ("China Unicom 46009", "460", "09", "460091234567890", ims_switches),
        # China Telecom (OP09) and other 460 MNCs are deliberately outside
        # both IMSI patterns: their AOSP/carrier-app policy is preserved.
        ("China Telecom 46003", "460", "03", "460031234567890", emergency_only),
        ("China Telecom 46011", "460", "11", "460111234567890", emergency_only),
        (
            "Vodafone NL",
            "204",
            "04",
            "204040123456789",
            {
                **emergency_only,
                "carrier_volte_available_bool": True,
                "carrier_wfc_ims_available_bool": True,
                "carrier_default_wfc_ims_mode_int": 1,
                "editable_wfc_mode_bool": False,
                "editable_wfc_roaming_mode_bool": True,
                "wfc_spn_format_idx_int": 1,
            },
        ),
        ("20404 non-cid20 allocation", "204", "04", "204043123456789", emergency_only),
        ("unrelated carrier", "310", "260", "310260123456789", emergency_only),
    ]
    for label, mcc, mnc, imsi, expected in expected_matrix:
        actual = resolved(fragments, mcc=mcc, mnc=mnc, imsi=imsi)
        if actual != expected:
            fail(f"{label} resolved to {actual}, expected {expected}")

    # Semantics, not just the literal. A retry curve can be syntactically
    # perfect and still terminate: RetryManager.reset() zeroes mMaxRetryCount
    # and configure() raises it to the number of delay entries (:315-318), so
    # a bucket without `max_retries=infinite` runs out, the context goes
    # FAILED, the next network request calls setWaitingApns() and the whole
    # sequence restarts from the first delay. That is the loop E-180 measured,
    # and the first version of the `ims` bucket had exactly that shape while
    # passing a literal comparison. Resolve the bucket the way the framework
    # does and assert what it actually means.
    retry_forever, max_retry_count, delays = parse_retry_config(ims_retry, "ims")
    if not retry_forever:
        fail("the ims retry bucket is finite; only max_retries=infinite keeps "
             "the context RETRYING instead of cycling through FAILED")
    if delays[-1] != 1800000:
        fail(f"the ims retry tail is {delays[-1]} ms, expected 1800000 "
             "(getRetryTimer clamps past the end of the array to the last entry)")
    if delays != sorted(delays):
        fail(f"the ims retry delays are not monotonically increasing: {delays}")

    availability = {"carrier_volte_available_bool", "carrier_wfc_ims_available_bool"}
    for fragment in fragments:
        keys = set(fragment_values(fragment))
        if keys & availability and not (
            "mcc" in fragment.attrib and ({"mnc", "imsi"} & set(fragment.attrib))
        ):
            fail("an IMS availability key is not carrier-filtered")

    print("CarrierConfig overlay matrix: PASS (CMCC, CU and Vodafone NL VoLTE/WFC switches; other carriers untouched)")


if __name__ == "__main__":
    main()
