#!/usr/bin/env python3
"""Rebuild the `logo` partition image with a new boot splash.

Only the boot splash is replaced. What is carried through byte-for-byte:

  * the other 78 blocks -- the charging animation, the battery-level frames,
    the low-battery and error screens, and the whole second 720x1600 set that
    belongs to a different panel. mtk_logo.pack() re-emits each untouched
    block's *original* zlib stream rather than re-deflating its pixels, so
    those bytes are identical, not merely equivalent. This is a shared
    shanzhai vendor image and there is no way to regenerate what is not
    understood.
  * the `logo` part_hdr, every field except `dsize`, including the second
    0x58891689 block header at 0x30 that is not understood.
  * the `cert1` and `cert2` part_hdr records that follow the logo record at
    3371760 and 3373984 in the factory image, and the partition padding behind
    them.

What is regenerated, and is therefore NOT byte-identical to the input:

  * the two boot-splash blocks (0 and 38) -- new pixels, new zlib streams.
  * the block offset table, `bodysize`, and the part_hdr's `dsize`, because
    the two new streams are a different length.
  * the 16-byte record-alignment pad in front of the trailer.
  * the zero fill that tops the file back up to the partition length.

Before this was fixed (T7) the claim above was simply false: mtk_logo.pack()
dropped the cert1/cert2 records entirely and the zero fill below hid it, and
every one of the 78 "carried" blocks was re-deflated, which on this image
changes 72 of the 80 streams.

Which block is the boot splash: index 0. It decodes to the stock "WELCOME"
screen, which is what this handset shows first, and MTK's LK renders index 0 as
the boot logo. Index 38 is byte-identical to index 0 and is replaced too --
identical input, so replacing both is never worse than replacing one, and it
covers LK picking the second set.

Usage: make-boot-logo.py <in-logo.bin> <overlay.png> <out-logo.bin>
"""

import os
import sys

from PIL import Image

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from mtk_logo import unpack, pack, bgra_to_rgba  # noqa: E402

BOOT_BLOCKS = (0, 38)
WIDTH = 720
# The panel is 720x1560 at 320 dpi, i.e. xhdpi, i.e. a 2x density bucket. The
# artwork is supplied at @3x, so the density-correct physical size is its @2x
# equivalent: two thirds of the source width. On the trimmed 607x113 wordmark
# that is 405x75, about 56% of the screen width, which is a normal boot-splash
# proportion and is derived rather than eyeballed.
LOGO_SCALE = 2.0 / 3.0
# Vertical placement, as a fraction of panel height to the CENTRE of the mark.
# Not 0.5: a splash centred on the geometric middle reads as low, because the
# eye puts the optical centre above it. 0.40 is the usual compromise and is what
# AOSP's own bootanimation and most OEM splashes land on.
LOGO_CENTRE_Y = 0.40


def same_file(a, b):
    """True if writing `b` would land on `a`.

    Two checks, because neither alone is enough. os.path.samefile() compares
    st_dev/st_ino, which is the only thing that catches a hard link or a bind
    mount -- but it needs both paths to exist, and the output normally does
    not yet. os.path.realpath() works on a path that does not exist (it
    resolves the directories that do and leaves the final component alone),
    which is what catches `factory_image/logo.bin` reached through a symlinked
    directory or a `..` segment.
    """
    try:
        if os.path.samefile(a, b):
            return True
    except OSError:
        pass  # b (or a) does not exist yet -- fall through to realpath
    return os.path.realpath(a) == os.path.realpath(b)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(
            "usage: make-boot-logo.py <in-logo.bin> <overlay.png> <out-logo.bin>")
    src, overlay_png, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    # T7: there was no such guard, so `make-boot-logo.py factory_image/logo.bin
    # art.png factory_image/logo.bin` happily overwrote its own input. That file
    # is the only pristine copy of this handset's factory logo partition and the
    # documented rollback path (notes/HANDOFF.md flashes it back verbatim); once
    # it is overwritten there is nothing to restore from. Refuse, loudly, before
    # anything is read or rendered.
    if same_file(src, dst):
        raise SystemExit(
            "refusing to write the output over the input: %s and %s are the "
            "same file. The input is the only pristine copy; pick another "
            "destination." % (src, dst))

    # The dst == src test above is necessary and NOT sufficient, and that was
    # found the expensive way: reading factory_image/logo.bin through a COPY and
    # writing the result back to factory_image/logo.bin passes it -- the two
    # paths genuinely are different files -- and destroys the original just the
    # same. factory_image/ is not under version control, so there is nothing to
    # restore from. Refuse to clobber ANY existing destination; an intentional
    # rebuild in place is one environment variable away.
    if os.path.exists(dst) and os.environ.get("K50SV1_LOGO_OVERWRITE") != "1":
        raise SystemExit(
            "refusing to overwrite an existing file: %s. factory_image/ is not "
            "under version control and this tool cannot undo itself. Write to a "
            "new path, or set K50SV1_LOGO_OVERWRITE=1 if you really mean it."
            % dst)

    img = unpack(src)

    if max(BOOT_BLOCKS) >= len(img.blocks):
        raise SystemExit("image has %d blocks, boot splash needs index %d"
                         % (len(img.blocks), max(BOOT_BLOCKS)))

    # Derive the panel height from block 0, but insist the block really is a
    # whole number of 720 px rows first -- `// 4 // WIDTH` alone silently
    # truncates a block that is not, and every check below would then be run
    # against a height that does not describe the block.
    stride = WIDTH * 4
    if len(img.blocks[BOOT_BLOCKS[0]]) % stride:
        raise SystemExit("block %d is %d bytes, not a multiple of %d px x 4"
                         % (BOOT_BLOCKS[0], len(img.blocks[BOOT_BLOCKS[0]]),
                            WIDTH))
    height = len(img.blocks[BOOT_BLOCKS[0]]) // stride

    logo = Image.open(overlay_png).convert("RGBA")
    logo = logo.resize(
        (round(logo.width * LOGO_SCALE), round(logo.height * LOGO_SCALE)),
        Image.LANCZOS)

    canvas = Image.new("RGBA", (WIDTH, height), (0, 0, 0, 255))
    canvas.alpha_composite(logo, (
        (WIDTH - logo.width) // 2,
        round(height * LOGO_CENTRE_Y) - logo.height // 2))

    # LK blits raw BGRA straight to the framebuffer.
    raw = bgra_to_rgba(canvas.tobytes())

    # T7: this check used to be `if len(blocks[i]) != len(raw)` -- a pure
    # byte-count invariant. WIDTH*HEIGHT*4 is the same number for a transposed
    # 1560x720 canvas, or for any other geometry with the same pixel count, so a
    # wrongly-shaped splash passed and LK would blit it as diagonal garbage
    # (there is no width field in the container to catch it later). Assert the
    # geometry itself, on both sides.
    expect = WIDTH * height * 4
    if canvas.size != (WIDTH, height) or len(raw) != expect:
        raise SystemExit("rendered %dx%d = %d bytes, expected %dx%d = %d"
                         % (canvas.size[0], canvas.size[1], len(raw),
                            WIDTH, height, expect))
    for i in BOOT_BLOCKS:
        if len(img.blocks[i]) != expect:
            raise SystemExit("block %d is %d bytes, expected %dx%dx4 = %d"
                             % (i, len(img.blocks[i]), WIDTH, height, expect))
        img.blocks[i] = raw

    # pack() re-appends the cert1/cert2 trailer and then decodes its own output
    # and asserts block count, per-block geometry, pixels and trailer bytes
    # against `img`. It raises rather than returning a bad image, so nothing
    # unverified can reach the write below.
    out = pack(img)
    orig_size = os.path.getsize(src)
    if len(out) > orig_size:
        raise SystemExit("rebuilt image is %d bytes, partition holds %d"
                         % (len(out), orig_size))
    # Pad back to the original partition length so a flash overwrites every
    # byte of the old image rather than leaving a tail of it behind. The trailer
    # already carries the factory image's own tail, so in practice this only
    # replaces the bytes the smaller boot-splash streams freed up.
    open(dst, "wb").write(out + b"\x00" * (orig_size - len(out)))
    print("%s: %d blocks, %d bytes (%d padded to %d), trailer %d bytes, "
          "regenerated blocks %s"
          % (dst, len(img.blocks), len(out), len(out), orig_size,
             len(img.trailer), list(BOOT_BLOCKS)))


if __name__ == "__main__":
    main()
