#!/usr/bin/env python3
"""Calculate the shipped dump loop's bounds; does not execute kernel code.

The u32 arithmetic and format widths come from dump-memory-disassembly.txt
and dump-formats.txt. The rejected-size return and truncation rules come
from the built kernel's vsnprintf. Input values cannot change the width of
%02x for an unsigned byte, so synthetic bytes suffice for this calculation.
"""

import csv
from pathlib import Path

CAPACITY = 1024
INPUT_LENGTH = 952
UINT32_MASK = (1 << 32) - 1
INT_MAX = (1 << 31) - 1
prefix = f"[52:65:67:49:6e:66],Len:{INPUT_LENGTH}:["
buffer = bytearray(CAPACITY)
rows = []
stores = []


def append(position, text, label):
    size = (CAPACITY - position) & UINT32_MASK
    if size > INT_MAX:
        returned, written, rejected = 0, 0, True
    else:
        returned, rejected = len(text), False
        written = min(len(text), max(size - 1, 0))
        for offset, value in enumerate(text.encode()[:written]):
            address = position + offset
            assert 0 <= address < CAPACITY, (label, address)
            buffer[address] = value
            stores.append(address)
        if size:
            terminator = position + written
            assert 0 <= terminator < CAPACITY, (label, terminator)
            buffer[terminator] = 0
            stores.append(terminator)
    rows.append((label, position, size, written, returned, rejected))
    return returned


position = append(0, prefix, "prefix")
for index in range(min(INPUT_LENGTH, 512)):
    position = (position + append(position, "00,", f"byte[{index}]")) & UINT32_MASK
append(position, "]", "closing bracket")

assert len(prefix) == 29
assert position == 1025
assert max(stores) == 1023
rejected = [row for row in rows if row[-1]]
assert rejected[0][0] == "byte[332]"
assert rejected[0][2] == 0xFFFFFFFF
assert len(rejected) == 181
assert buffer[1023] == 0

destination = Path(__file__).with_name("arithmetic.csv")
with destination.open("w", newline="") as stream:
    writer = csv.writer(stream)
    writer.writerow(("call", "position", "size_u32", "characters_stored", "return", "rejected"))
    writer.writerows(rows)

print("Arithmetic calculation only; the module and kernel were not executed.")
print(f"Prefix length: {len(prefix)}; input length: {INPUT_LENGTH}; loop count: 512")
print("Each unsigned-byte format produces 3 characters, excluding NUL.")
print("Boundary rows: call, position, size_u32, characters_stored, return, rejected")
for row in rows:
    if row[0] in ("byte[330]", "byte[331]", "byte[332]", "byte[511]", "closing bracket"):
        print(row)
print(f"Rejected calls: {len(rejected)} (180 byte appends and the closing bracket)")
print(f"Final position: {position}; highest destination store offset: {max(stores)}")
print("The 1024-byte buffer retains NUL at offset 1023.")
print("A full 512-byte dump with this prefix, closing bracket and NUL needs 1567 bytes.")
