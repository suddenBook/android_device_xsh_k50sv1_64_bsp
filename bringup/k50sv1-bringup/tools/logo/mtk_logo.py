#!/usr/bin/env python3
"""Unpack and repack an MTK `logo` partition image.

Layout, as read back from this handset's factory logo.bin:

    0x000  struct part_hdr  (512 bytes)
           u32 magic     0x58881688
           u32 dsize     size of the body that follows this header
           char name[32] "logo"
           ... 0xff padding, then a second 0x58891689 block header

    0x200  body
           u32 nblocks
           u32 bodysize          total body length, offsets are relative to it
           u32 offset[nblocks]   byte offset of each zlib stream, from body start
           zlib streams, back to back

Each stream inflates to a raw BGRA8888 framebuffer, bottom row last, no header
of its own -- the width is not stored anywhere in the file, so the caller has
to supply it. Every full-screen block on this device is 720 px wide.

The `logo` record is NOT the whole partition. part_hdr records are chained: the
next record begins at the first REC_ALIGN (16 byte) boundary at or after the end
of the previous record's payload. This handset's factory image carries three of
them, confirmed with `grep -abo cert1 factory_image/logo.bin`,
`grep -abo cert2 factory_image/logo.bin` (which report the name field at record
offset + 8) and by walking the chain:

    record at   name     dsize     payload ends   next record at
    0           logo     3371247   3371759        3371760
    3371760     cert1    1709      3373981        3373984
    3373984     cert2    957       3375453        (chain ends)

3375453..8388607 is the zero padding that fills out the 8 MiB partition.

T7, the bug this module used to have: unpack() returned only
(part_hdr, blocks, dsize) and pack() emitted only header + body, so the cert1
and cert2 records -- everything from 3371760 on -- were silently dropped on
every repack. It stayed invisible because make-boot-logo.py then zero-filled the
result back up to the partition length, so the output was still exactly
8,388,608 bytes and still flashed; it just had both certificate records
replaced by zeros. unpack() now captures every byte after the logo record's own
payload as `trailer`, and pack() re-appends it byte-for-byte.

pack() also keeps each block's *original* zlib stream when the caller did not
change that block's pixels, rather than re-deflating it. That is what makes
"the other blocks are carried through byte-for-byte" literally true: this is a
shared shanzhai vendor image, zlib level 9 here does not reproduce the vendor's
deflate output (72 of the 80 streams come back different), and an unmodified
repack must be able to round-trip to the identical file.
"""

import struct
import sys
import zlib

HDR_MAGIC = 0x58881688
HDR_SIZE = 512
# part_hdr records are chained on 16-byte boundaries; see the table above, where
# the logo payload ends at 3371759 and cert1 starts at 3371760. The one pad byte
# there is 0x00 in the factory image, so that is what pack() writes.
REC_ALIGN = 16
REC_PAD = b"\x00"


class RoundTripError(Exception):
    """pack() rebuilt an image that does not decode back to its input.

    Raised instead of printing a warning: a mismatch here means the rebuilt
    image would boot-splash something other than what the caller asked for, or
    would have lost the cert chain again, and it must never reach a file.
    """


class LogoImage(object):
    """One unpacked MTK logo partition image.

    hdr      the logo record's 512-byte part_hdr, exactly as read
    blocks   decoded BGRA8888 framebuffers; mutate this list in place
    trailer  every byte after the logo record's 16-byte-aligned end: the
             cert1/cert2 part_hdr chain and any partition padding behind it
    dsize    the dsize field as read from `hdr`
    """

    def __init__(self, hdr, blocks, streams, trailer, dsize):
        self.hdr = hdr
        self.blocks = list(blocks)
        self.trailer = trailer
        self.dsize = dsize
        # Parallel to `blocks`: the zlib stream each block was read from, and
        # the bytes it decoded to. `_pristine` holds the very same objects that
        # `blocks` starts out with, so this costs no extra memory until a
        # caller actually replaces a block.
        self._streams = list(streams)
        self._pristine = list(blocks)

    def original_stream(self, i):
        """The stream block `i` came from, or None if the caller changed it."""
        if i >= len(self._pristine):
            return None  # a block the caller appended; it has no original
        blk = self.blocks[i]
        orig = self._pristine[i]
        if blk is orig or blk == orig:
            return self._streams[i]
        return None

    def changed_blocks(self):
        """Indices whose pixels differ from what unpack() read."""
        return [i for i in range(len(self.blocks))
                if self.original_stream(i) is None]


def _align(n):
    return (n + REC_ALIGN - 1) // REC_ALIGN * REC_ALIGN


def _parse(blob):
    """Split raw image bytes into (hdr, streams, trailer, dsize).

    Streams are returned still deflated so that the round-trip check can
    inflate them one at a time; the 80 blocks total ~253 MiB decoded.
    """
    if len(blob) < HDR_SIZE:
        raise ValueError("truncated MTK logo image: %d bytes" % len(blob))
    magic, dsize = struct.unpack("<II", blob[:8])
    if magic != HDR_MAGIC:
        raise ValueError("not an MTK logo image: magic %#x" % magic)
    end = HDR_SIZE + dsize
    if end > len(blob):
        raise ValueError("part_hdr dsize %d runs past EOF (%d bytes)"
                         % (dsize, len(blob)))
    # Bounded by dsize. This used to be blob[HDR_SIZE:], i.e. everything to EOF,
    # which is precisely why the cert chain was invisible: it sat inside `body`
    # past the last stream offset and nothing ever looked at it.
    body = blob[HDR_SIZE:end]
    if len(body) < 8:
        raise ValueError("part_hdr dsize %d is too small to hold a body header"
                         % dsize)
    nblocks, bodysize = struct.unpack("<II", body[:8])
    if bodysize > len(body):
        raise ValueError("bodysize %d exceeds dsize %d" % (bodysize, dsize))
    # Validate the offset table before slicing with it.
    #
    # A table with descending offsets, an offset past bodysize, or a bodysize
    # too small to hold the table itself all produced empty or reversed slices
    # here, and the first sign of any of it was a zlib.error from decompress()
    # in unpack() -- which reads as a corrupt stream rather than as a corrupt
    # index. The streams are stored back to back, so the table must ascend
    # strictly, start at or after the end of the table, and end at bodysize.
    table_end = 8 + 4 * nblocks
    if nblocks < 1 or table_end > bodysize:
        raise ValueError(
            "nblocks %d needs a %d-byte offset table, but bodysize is %d"
            % (nblocks, table_end, bodysize))
    offsets = list(struct.unpack("<%dI" % nblocks, body[8:table_end]))
    offsets.append(bodysize)
    for i in range(nblocks):
        if not table_end <= offsets[i] < offsets[i + 1] <= bodysize:
            raise ValueError(
                "block %d occupies body[%d:%d], which is out of order or "
                "outside the %d-byte body (table ends at %d)"
                % (i, offsets[i], offsets[i + 1], bodysize, table_end))
    streams = [body[offsets[i]:offsets[i + 1]] for i in range(nblocks)]
    return blob[:HDR_SIZE], streams, blob[_align(end):], dsize


def chain(blob):
    """Walk the part_hdr chain: [(offset, name, dsize), ...].

    Used for reporting and for the trailer sanity check. Stops at the first
    offset that is not a part_hdr, which is where the partition padding starts.
    """
    out, off = [], 0
    while off + HDR_SIZE <= len(blob):
        magic, dsize = struct.unpack("<II", blob[off:off + 8])
        if magic != HDR_MAGIC or off + HDR_SIZE + dsize > len(blob):
            break
        name = blob[off + 8:off + 40].split(b"\0")[0].decode("ascii", "replace")
        out.append((off, name, dsize))
        off = _align(off + HDR_SIZE + dsize)
    return out


def unpack(path):
    """Read an MTK logo image from `path` and return a LogoImage."""
    blob = open(path, "rb").read()
    hdr, streams, trailer, dsize = _parse(blob)
    return LogoImage(hdr, [zlib.decompress(s) for s in streams],
                     streams, trailer, dsize)


def pack(image):
    """Rebuild the image bytes from a LogoImage, trailer included.

    Compression level 9 keeps a re-deflated block inside the partition; blocks
    the caller did not touch keep their original stream instead, so they are
    reproduced bit-for-bit rather than merely pixel-for-pixel.

    The result is verified by decoding it again before it is returned, so no
    caller can write an image that failed the check.
    """
    streams = []
    for i, blk in enumerate(image.blocks):
        cached = image.original_stream(i)
        streams.append(cached if cached is not None else zlib.compress(blk, 9))

    n = len(streams)
    table_len = 8 + 4 * n
    offsets, cur = [], table_len
    for s in streams:
        offsets.append(cur)
        cur += len(s)
    bodysize = cur
    body = struct.pack("<II", n, bodysize)
    body += struct.pack("<%dI" % n, *offsets)
    body += b"".join(streams)
    # dsize in the part_hdr counts the body, and the header keeps everything
    # else byte-for-byte -- the second block header at 0x30 is not understood
    # and is not ours to regenerate.
    hdr = bytearray(image.hdr)
    struct.pack_into("<I", hdr, 4, bodysize)
    out = bytes(hdr) + body
    # T7: pad the logo record out to the next 16-byte boundary and re-append the
    # cert1/cert2 chain. Both used to be dropped here, and the caller's zero-fill
    # to the partition length hid the loss.
    out += REC_PAD * (-len(out) % REC_ALIGN)
    out += image.trailer
    _verify_round_trip(out, image)
    return out


def _verify_round_trip(out, image):
    """Decode `out` again and prove it matches `image`, or raise.

    This exists because T7 was a silent data-loss bug: the repacked file was
    the right length and flashed fine, and nothing ever compared it against
    what went in. Every property that repack is supposed to preserve is
    asserted here, and a failure is an exception, never a warning.
    """
    hdr, streams, trailer, _ = _parse(out)
    # dsize (hdr[4:8]) is the one field pack() rewrites; the rest is carried.
    if hdr[:4] != image.hdr[:4] or hdr[8:] != image.hdr[8:]:
        raise RoundTripError("part_hdr changed outside its dsize field")
    if len(streams) != len(image.blocks):
        raise RoundTripError("block count changed: packed %d, wanted %d"
                             % (len(streams), len(image.blocks)))
    for i, stream in enumerate(streams):
        raw = zlib.decompress(stream)
        want = image.blocks[i]
        if len(raw) != len(want):
            raise RoundTripError(
                "block %d geometry changed: packed %d bytes (%d px), "
                "wanted %d bytes (%d px)"
                % (i, len(raw), len(raw) // 4, len(want), len(want) // 4))
        if raw != want:
            raise RoundTripError("block %d pixels changed on repack" % i)
    if trailer != image.trailer:
        raise RoundTripError(
            "trailer changed: packed %d bytes, wanted %d bytes (the cert1/"
            "cert2 chain must survive byte-for-byte)"
            % (len(trailer), len(image.trailer)))


def bgra_to_rgba(raw):
    b = bytearray(raw)
    b[0::4], b[2::4] = b[2::4], b[0::4]
    return bytes(b)


if __name__ == "__main__":
    img = unpack(sys.argv[1])
    # tools/flash-logo-image.sh:37 matches this first line against
    # 'blocks=80 *' before it will flash anything. Keep its shape.
    print("blocks=%d dsize=%d" % (len(img.blocks), img.dsize))
    for i, b in enumerate(img.blocks):
        px = len(b) // 4
        print("  %2d  raw=%-8d px=%-8d %s" %
              (i, len(b), px, "720x%d" % (px // 720) if px % 720 == 0 else "?"))
    print("trailer=%d bytes after %d" % (len(img.trailer),
                                         _align(HDR_SIZE + img.dsize)))
    for off, name, dsize in chain(open(sys.argv[1], "rb").read())[1:]:
        print("  %-8s at %-10d dsize=%d" % (name, off, dsize))
