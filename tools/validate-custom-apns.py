#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Validate the k50sv1 Lineage APN fragment and its merged runtime meaning."""

from __future__ import print_function, unicode_literals

import hashlib
import sys
import xml.etree.ElementTree as ET


# TelephonyManager.NETWORK_TYPE_* values this modem can actually be on, plus
# IWLAN for the Wi-Fi-calling PDN. The CDMA family (4 CDMA, 5 EVDO_0,
# 6 EVDO_A, 7 1xRTT, 12 EVDO_B, 14 EHRPD) is deliberately absent, and so are
# 11 IDEN and 20 NR, which this hardware does not have.
#
# The CDMA exclusion is load-bearing, not tidiness. DcTracker.createDataProfile()
# (:5085-5093) chooses the DataProfile type from this mask alone: 0 gives
# TYPE_COMMON, a mask that ServiceState.bearerBitmapHasCdma() accepts gives
# TYPE_3GPP2, anything else gives TYPE_3GPP. With the old 1|2|...|20 mask the
# IMS profile went out as TYPE_3GPP2 and mtkrild answered every SETUP_DATA_CALL
# with RIL_E_REQUEST_NOT_SUPPORTED (error 6), because this build has no C2K
# stack. Measured on the handset; see E-181.
CANONICAL_MASK_VALUES = (1, 2, 3, 8, 9, 10, 13, 15, 16, 17, 18, 19)
CANONICAL_MASK = "|".join(str(value) for value in CANONICAL_MASK_VALUES)
EXPECTED_MASK = 0
for _value in CANONICAL_MASK_VALUES:
    EXPECTED_MASK |= 1 << (_value - 1)
# The RIL radio technologies DcTracker treats as CDMA, as
# TelephonyManager.NETWORK_TYPE_* values (ServiceState:253-260 mapped back
# through networkTypeToRilRadioTechnology).
CDMA_NETWORK_TYPES = frozenset((4, 5, 6, 7, 12, 14))
COMMON_ATTRIBUTES = {
    "carrier",
    "mcc",
    "mnc",
    "apn",
    "type",
    "protocol",
    "roaming_protocol",
    "network_type_bitmask",
}
# One row per MCC/MNC the CarrierConfig overlay advertises VoLTE for. A
# carrier with the switch and no ims-typed APN gets an empty waiting list
# and MISSING_UNKNOWN_APN (DcTracker:1605-1610), so the two lists move
# together; check-carrier-config-overlay.py owns the other half.
#
# The MNC sits in the MIDDLE of each label on purpose. custom_apns.py
# matches carrier names as substrings, so "... IMS" and "... IMS 46002"
# would make the merge emit the longer row twice; the substring check
# below is what enforces it.
EXPECTED_ROWS = [
    (
        "k50sv1: Vodafone NL IMS",
        "204",
        "04",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Telecom MVNO IMS",
        "204",
        "04",
        "IMS",
        "spn",
        "中国电信",
    ),
    (
        "k50sv1: China Mobile 46000 IMS",
        "460",
        "00",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Mobile 46002 IMS",
        "460",
        "02",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Mobile 46004 IMS",
        "460",
        "04",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Mobile 46007 IMS",
        "460",
        "07",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Mobile 46008 IMS",
        "460",
        "08",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Unicom 46001 IMS",
        "460",
        "01",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Unicom 46006 IMS",
        "460",
        "06",
        "ims",
        "",
        "",
    ),
    (
        "k50sv1: China Unicom 46009 IMS",
        "460",
        "09",
        "ims",
        "",
        "",
    ),
]


def fail(message):
    raise ValueError(message)


def read_utf8(path):
    with open(path, "rb") as source:
        raw = source.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        fail("%s is not UTF-8: %s" % (path, error))


def parse_document(path):
    try:
        root = ET.fromstring(read_utf8(path).encode("utf-8"))
    except ET.ParseError as error:
        fail("%s is not valid XML: %s" % (path, error))
    if root.tag != "apns":
        fail("%s has unexpected root %s" % (path, root.tag))
    return root


def parse_fragment(path):
    text = read_utf8(path)
    if "\r" in text:
        fail("custom APN fragment must use LF line endings")
    lines = text.splitlines(True)
    if len(lines) != len(EXPECTED_ROWS) or any(not line.strip() for line in lines):
        fail("custom APN fragment must contain exactly %d non-empty lines"
             % len(EXPECTED_ROWS))
    if any(not line.endswith("\n") for line in lines):
        fail("every custom APN row must end on its own physical line")

    rows = []
    for number, line in enumerate(lines, 1):
        try:
            row = ET.fromstring(line.encode("utf-8"))
        except ET.ParseError as error:
            fail("custom APN line %d is not independently valid XML: %s" %
                 (number, error))
        if row.tag != "apn" or list(row) or (row.text or "").strip():
            fail("custom APN line %d must be one empty apn element" % number)
        rows.append(row)
    return text, rows


def parse_network_mask(value):
    if value != CANONICAL_MASK:
        fail("network_type_bitmask must be the canonical %s string" % CANONICAL_MASK)
    tokens = value.split("|")
    if any(not token.isdigit() or token == "0" for token in tokens):
        fail("network_type_bitmask contains a non-decimal or zero token")
    numbers = [int(token) for token in tokens]
    if len(numbers) != len(set(numbers)):
        fail("network_type_bitmask contains a duplicate token")
    mask = 0
    for number in numbers:
        mask |= 1 << (number - 1)
    if mask != EXPECTED_MASK or 18 not in numbers:
        fail("network_type_bitmask does not encode %d with IWLAN" % EXPECTED_MASK)
    if CDMA_NETWORK_TYPES & set(numbers):
        fail("network_type_bitmask names a CDMA technology, which makes "
             "DcTracker build a TYPE_3GPP2 profile that mtkrild rejects")
    return mask


def bool_value(value, default):
    if value is None:
        return default
    return "1" if value.lower() == "true" else "0"


def database_identity(row):
    """Mirror TelephonyProvider Q's CARRIERS_UNIQUE_FIELDS defaults."""
    mcc = row.get("mcc", "")
    mnc = row.get("mnc", "")
    mvno_type = row.get("mvno_type", "")
    mvno_match = row.get("mvno_match_data", "") if mvno_type else ""
    return (
        mcc + mnc,
        mcc,
        mnc,
        row.get("apn", ""),
        row.get("proxy", ""),
        row.get("port", ""),
        row.get("mmsproxy", ""),
        row.get("mmsport", ""),
        row.get("mmsc", ""),
        bool_value(row.get("carrier_enabled"), "1"),
        row.get("bearer", "0"),
        mvno_type,
        mvno_match,
        row.get("profile_id", "0"),
        row.get("protocol", "IP"),
        row.get("roaming_protocol", "IP"),
        bool_value(row.get("user_editable"), "1"),
        "1",  # OWNED_BY_OTHERS; XML getRow() does not parse owned_by.
        row.get("apn_set_id", "0"),
        row.get("carrier_id", "-1"),
    )


def validate_rows(rows):
    actual = []
    carriers = []
    identities = []
    for number, row in enumerate(rows, 1):
        mvno = row.get("mvno_type", "")
        expected_attributes = set(COMMON_ATTRIBUTES)
        if mvno:
            expected_attributes.update(("mvno_type", "mvno_match_data"))
        if set(row.attrib) != expected_attributes:
            fail("custom APN line %d has missing or unsupported attributes" % number)
        if row.get("type") != "ims":
            fail("custom APN line %d must use exact type=ims" % number)
        if row.get("protocol") != "IPV4V6" or \
                row.get("roaming_protocol") != "IPV4V6":
            fail("custom APN line %d must use IPV4V6 in both directions" % number)
        parse_network_mask(row.get("network_type_bitmask", ""))
        actual.append((
            row.get("carrier", ""),
            row.get("mcc", ""),
            row.get("mnc", ""),
            row.get("apn", ""),
            mvno,
            row.get("mvno_match_data", ""),
        ))
        carriers.append(row.get("carrier", ""))
        identities.append(database_identity(row))

    if actual != EXPECTED_ROWS:
        fail("custom APN identities or order differ from the %d approved rows"
             % len(EXPECTED_ROWS))
    if len(set(carriers)) != len(EXPECTED_ROWS):
        fail("custom carrier labels are not unique")
    for left_index, left in enumerate(carriers):
        for right_index, right in enumerate(carriers):
            if left_index != right_index and left in right:
                fail("custom carrier labels have a substring collision")
    if len(set(identities)) != len(EXPECTED_ROWS):
        fail("custom APNs collide under TelephonyProvider database identity")
    return carriers, identities


def validate_external_collisions(custom_rows, custom_identities, roots):
    external = []
    for source_name, root in roots:
        for row in root.findall("apn"):
            external.append((source_name, row, database_identity(row)))
    for custom_row, custom_identity in zip(custom_rows, custom_identities):
        for source_name, row, identity in external:
            if custom_identity == identity:
                fail("%s collides with %s carrier %r under TelephonyProvider identity" %
                     (custom_row.get("carrier"), source_name,
                      row.get("carrier", "")))


def merge_document(default_text, fragment_text, carriers):
    for carrier in carriers:
        if carrier in default_text:
            fail("carrier label %r collides with Lineage merge substring logic" % carrier)
    if default_text.count("</apns>") != 1:
        fail("clean Lineage APN document has an ambiguous closing tag")
    return default_text.replace("</apns>", fragment_text + "</apns>")


def main(argv):
    if len(argv) != 4:
        fail("usage: validate-custom-apns.py DEFAULT_APNS CUSTOM_FRAGMENT INTERNAL_APNS")
    default_path, fragment_path, internal_path = argv[1:]
    default_text = read_utf8(default_path)
    default_root = parse_document(default_path)
    internal_root = parse_document(internal_path)
    fragment_text, custom_rows = parse_fragment(fragment_path)
    carriers, identities = validate_rows(custom_rows)
    validate_external_collisions(
        custom_rows,
        identities,
        (("Lineage default", default_root), ("framework internal", internal_root)),
    )

    merged_text = merge_document(default_text, fragment_text, carriers)
    try:
        merged_root = ET.fromstring(merged_text.encode("utf-8"))
    except ET.ParseError as error:
        fail("faithfully merged APN document is invalid: %s" % error)
    base_count = len(default_root.findall("apn"))
    merged_count = len(merged_root.findall("apn"))
    if merged_count != base_count + len(EXPECTED_ROWS):
        fail("merged APN row count is not clean-base plus %d"
             % len(EXPECTED_ROWS))
    for carrier in carriers:
        if sum(1 for row in merged_root.findall("apn")
               if row.get("carrier") == carrier) != 1:
            fail("merged APN document does not contain exactly one %r" % carrier)

    merged_bytes = merged_text.encode("utf-8")
    print("status=PASS")
    print("base_rows=%d" % base_count)
    print("internal_rows=%d" % len(internal_root.findall("apn")))
    print("custom_rows=%d" % len(EXPECTED_ROWS))
    print("merged_rows=%d" % merged_count)
    print("network_type_bitmask=%d" % EXPECTED_MASK)
    print("merged_sha256=%s" % hashlib.sha256(merged_bytes).hexdigest())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (IOError, OSError, ValueError) as error:
        print("ERROR: %s" % error, file=sys.stderr)
        sys.exit(1)
