# █ dcj · dotcomjack.com · MIT
# Appends the third row, Only the clock, to docs/clock-before-after.png.
#
# Rows 1 and 2 are the original Aug 8 capture (Clock visible, then Blind) and
# are never touched. Row 3 is built from row 1: the same strip of bar with
# everything patched over except the clock, plus Nocturne's moon in the status
# item slot next to it. The moon glyph is lifted from the Sep 5 capture in
# docs/modes, which is at the same 2x scale (icons measure 25 to 27px in both).
#
# Idempotent: it only ever reads the first two rows, so re-running it
# regenerates row 3 rather than stacking a fourth.
from PIL import Image

SRC = "clock-before-after.png"
MOON_SRC = "modes/mode-1-clock-visible.png"

ROW_H = 66            # one strip of bar, in output pixels
BAND = (66, 86)       # the dark separator between rows, copied as-is
CLOCK_X = (426, 668)  # columns of row 1 holding "Sat Aug 8  3:14 AM"
SLOT_CX = 372         # centre of the status item slot left of the clock
MOON_BOX = (2671, 16, 2704, 50)   # moon glyph in the Sep 5 capture

ba = Image.open(SRC).convert("RGB")
row1 = ba.crop((0, 0, ba.width, ROW_H))
band = ba.crop((0, BAND[0], ba.width, BAND[1]))
top = ba.crop((0, 0, ba.width, BAND[1] + ROW_H))   # rows 1, band, 2

# Row 3 background: each column filled with that column's own blank-band
# colour, so the wallpaper tint and its slight gradient carry through.
px = row1.load()
row3 = Image.new("RGB", row1.size)
p3 = row3.load()
blank_rows = list(range(2, 16)) + list(range(50, 64))
for x in range(row1.width):
    r = g = b = 0
    for y in blank_rows:
        c = px[x, y]
        r += c[0]; g += c[1]; b += c[2]
    n = len(blank_rows)
    col = (r // n, g // n, b // n)
    for y in range(ROW_H):
        p3[x, y] = col

# The clock, exactly as it was in row 1.
row3.paste(row1.crop((CLOCK_X[0], 0, CLOCK_X[1], ROW_H)), (CLOCK_X[0], 0))

# The bar's bottom edge: rows 1 and 2 carry a soft fringe where the capture
# meets the window below, so row 3 borrows row 1's last few pixel rows.
EDGE = 3
row3.paste(row1.crop((0, ROW_H - EDGE, row1.width, ROW_H)), (0, ROW_H - EDGE))

# The moon: white glyph on a dark bar, alpha recovered from luminance.
moon = Image.open(MOON_SRC).convert("RGB").crop(MOON_BOX)
mp = moon.load()
bg = min(sum(mp[x, y]) / 3 for x in range(moon.width) for y in range(moon.height))
alpha = Image.new("L", moon.size)
ap = alpha.load()
for x in range(moon.width):
    for y in range(moon.height):
        lum = sum(mp[x, y]) / 3
        ap[x, y] = int(max(0.0, min(1.0, (lum - bg) / (238 - bg))) * 255)
white = Image.new("RGB", moon.size, (255, 255, 255))
row3.paste(white, (SLOT_CX - moon.width // 2, MOON_BOX[1]), alpha)

out = Image.new("RGB", (ba.width, top.height + band.height + ROW_H))
out.paste(top, (0, 0))
out.paste(band, (0, top.height))
out.paste(row3, (0, top.height + band.height))
out.save(SRC)
print(f"wrote {SRC}  {out.width}x{out.height}")
