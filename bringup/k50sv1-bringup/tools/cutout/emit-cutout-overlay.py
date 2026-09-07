#!/usr/bin/env python3
"""Turn a measured punch-hole bounding box into the Android 10 overlay resources.

Usage:
    emit-cutout-overlay.py LEFT RIGHT TOP BOTTOM

All four are display pixels, read off tools/cutout/cutout-grid.png shown
full-screen on the handset, and must enclose the opaque ring around the lens,
not just the glass. The panel is 720x1560.

Why this is scripted rather than hand-written: Android 10's DisplayCutout path
grammar is narrow and gets copied wrong from newer device trees.

  * Only four markers exist -- @bottom, @dp, @left, @right
    (frameworks/base/core/java/android/view/DisplayCutout.java:66-69).
    @ratio is Android 11+; using it makes PathParser throw and the whole cutout
    is silently dropped after a Log.wtf.
  * With no @dp the path is in PIXELS, and the origin is the TOP CENTRE of the
    display: x is measured from the horizontal centre, y from the top edge.
    @dp would scale by ro.sf.lcd_density/160 and ignore any `wm density`
    override, so a physical aperture is specified in pixels.
  * The safe inset the framework reports to apps is the bottom of the bounding
    box of config_mainBuiltInDisplayCutoutRectApproximation
    (DisplayCutout.java:678-681) -- so that path must be a rectangle flush with
    the top edge, not the circle.
  * The drawn path needs a degenerate "M 0,0 L 0,0 Z" so its bounding box also
    starts at y=0, which is what every AOSP emulation overlay does.
"""
import sys

if len(sys.argv) != 5:
    sys.exit(__doc__)
left, right, top, bottom = (int(a) for a in sys.argv[1:])

W, H, DENSITY = 720, 1560, 320
# left < right as well as top < bottom. Only the vertical span was ordered, so
# a transposed pair produced a negative rx, an arc command with a negative
# radius, and a rect whose corners cross -- all of which PathParser accepts
# syntactically and none of which is the measured aperture.
if not 0 <= left < right <= W:
    sys.exit(f"left={left}/right={right} are not a sane horizontal span "
             f"inside the {W}px panel width")
if not 0 <= top < bottom <= H:
    sys.exit(f"top={top}/bottom={bottom} are not a sane vertical span")

cx, cy = (left + right) / 2, (top + bottom) / 2
rx, ry = (right - left) / 2, (bottom - top) / 2
# Path coordinates are relative to the top centre of the display.
ox = cx - W / 2
status_bar_dp = -(-bottom * 160 // DENSITY)          # ceil, then round up to 4dp
status_bar_dp = ((status_bar_dp + 7) // 4) * 4       # +2dp of breathing room

print(f"""<!-- Measured punch hole: x {left}..{right}, y {top}..{bottom} px.
     Centre ({cx:g}, {cy:g}), radii ({rx:g}, {ry:g}), offset from display
     centre {ox:+g} px. Safe inset top will be {bottom} px. -->

<!-- device/xsh/k50sv1_64_bsp/overlay/frameworks/base/core/res/res/values/config.xml -->
    <!-- Drawn shape: two half arcs make the full ellipse. Pixels, origin at the
         top centre of the display. The trailing degenerate subpath pins the
         bounding box to the top edge. -->
    <string translatable="false" name="config_mainBuiltInDisplayCutout">
        M {ox - rx:g},{cy:g}
        A {rx:g},{ry:g} 0 1,0 {ox + rx:g},{cy:g}
        A {rx:g},{ry:g} 0 1,0 {ox - rx:g},{cy:g}
        Z
        M 0,0 L 0,0 Z
    </string>

    <!-- Reported to apps: the enclosing rectangle, flush with the top edge, so
         DisplayCutout.getSafeInsetTop() == {bottom}. -->
    <string translatable="false" name="config_mainBuiltInDisplayCutoutRectApproximation">
        M {ox - rx:g},0
        L {ox - rx:g},{bottom:g}
        L {ox + rx:g},{bottom:g}
        L {ox + rx:g},0
        Z
    </string>

    <!-- Let SystemUI paint the aperture black so its edge is anti-aliased. -->
    <bool name="config_fillMainBuiltInDisplayCutout">true</bool>

    <!-- Keep the full {W}x{H} logical display; true would letterbox the strip
         away permanently and hide the cutout from apps entirely. -->
    <bool name="config_maskMainBuiltInDisplayCutout">false</bool>

<!-- SUPERSEDED for this device: DENSITY is hardcoded 320, so this emits 40dp,
     which is 64px at the owner's forced density 256 and does not clear the
     70px aperture. The tree ships 45dp / 25dp; see overlay/.../dimens.xml. The
     config_mainBuiltInDisplayCutout* half above is still current. -->
<!-- device/xsh/k50sv1_64_bsp/overlay/frameworks/base/core/res/res/values/dimens.xml -->
    <!-- >= the {bottom} px cutout bottom at {DENSITY} dpi, rounded up. -->
    <dimen name="status_bar_height_portrait">{status_bar_dp}dp</dimen>
    <!-- Landscape puts the hole on a side edge; keep the AOSP default. Note it
         also drives quick_qs_offset_height in values-land, so raising it
         desynchronises the Quick Settings header from quick_qs_total_height. -->
    <dimen name="status_bar_height_landscape">24dp</dimen>""")

if status_bar_dp > 48:
    print(f"""
NOTE: {status_bar_dp}dp exceeds the 48dp quick_qs_offset_height default, so in
PORTRAIT you must also raise both, keeping the 128dp difference:
    <dimen name="quick_qs_offset_height">{status_bar_dp}dp</dimen>
    <dimen name="quick_qs_total_height">{status_bar_dp + 128}dp</dimen>""")
