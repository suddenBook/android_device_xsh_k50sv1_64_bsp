#!/usr/bin/env python3
"""Read and write MediaTek's obfuscated /vendor/etc/.tp/ thermal configs.

The files are not encrypted, only rotated, so they can be edited and put back.
Per CRLF-terminated line, over the printable alphabet 0x20..0x7A (91 symbols):

    cipher[i] = 0x20 + ((plain[i] - 0x20 + (i % 10)) % 91)

Bytes outside that alphabet -- tab is the only one these files use -- pass
through untouched, and the index still advances over them. Derived from three
anchors that decode to obvious markers: "EPH" -> "EOF", "SfebIsj" -> "Sec_End",
"SfebGmowgWang" -> "Sec_Chip_Name"; the 91 wrap shows up on any line long
enough to push a lowercase letter past 'z'.

Usage:  mtk-thermal-conf.py decode FILE [FILE...]
        mtk-thermal-conf.py encode PLAINFILE > OBFUSCATED
        mtk-thermal-conf.py roundtrip FILE      prove decode(encode(x)) == x
"""
import sys

LO, HI = 0x20, 0x7A
N = HI - LO + 1          # 91


def _shift(data, sign):
    out = bytearray()
    for i, c in enumerate(data):
        if LO <= c <= HI:
            c = LO + ((c - LO + sign * (i % 10)) % N)
        out.append(c)
    return bytes(out)


def _split_keep(blob):
    """Yield (line, terminator). The index resets per line, and these files are
    not consistent about the terminator -- thermal.conf is all CRLF,
    thermal.off.conf is 75 bare LFs and one CRLF -- so splitting on the wrong
    one silently decodes half a file into garbage."""
    out, start, i, n = [], 0, 0, len(blob)
    while i < n:
        if blob[i] == 0x0A:
            out.append((blob[start:i], b"\n"))
            i += 1
            start = i
        elif blob[i] == 0x0D:
            term = b"\r\n" if i + 1 < n and blob[i + 1] == 0x0A else b"\r"
            out.append((blob[start:i], term))
            i += len(term)
            start = i
        else:
            i += 1
    out.append((blob[start:], b""))
    return out


def decode(blob):
    return b"".join(_shift(l, -1) + t for l, t in _split_keep(blob))


def encode(blob):
    return b"".join(_shift(l, +1) + t for l, t in _split_keep(blob))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    for path in sys.argv[2:]:
        blob = open(path, "rb").read()
        if mode == "decode":
            sys.stdout.buffer.write(decode(blob))
        elif mode == "encode":
            sys.stdout.buffer.write(encode(blob))
        elif mode == "roundtrip":
            ok = encode(decode(blob)) == blob
            print("%s: %s" % (path, "ROUNDTRIP OK" if ok else "ROUNDTRIP MISMATCH"))
            if not ok:
                return 1
        else:
            print("unknown mode", mode)
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
