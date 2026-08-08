# Builds the four-mode comparison image from the raw menu bar captures.
#
# Each row is the SAME strip of the real menu bar, in one of Nocturne's four
# modes, captured on macOS 26.3.1 at 2x. Only the right-hand portion is kept:
# the left of the bar is app menus and carries no information about the clock.
#
# Deliberately no drop shadows or device frames. The thing being demonstrated
# is a 44pt difference in one corner, and chrome around it only competes.
from PIL import Image, ImageDraw, ImageFont

SCALE = 2                 # captures are Retina 2x
KEEP_RIGHT_PT = 620       # points of bar to keep, measured from the right edge
LABEL_W = 360             # label gutter, in output pixels
PAD = 28
GAP = 18
BG = (251, 250, 248)      # the site's warm paper
INK = (15, 15, 15)
SOFT = (107, 107, 107)
ACCENT = (140, 106, 47)

ROWS = [
    ("mode-1-clock-visible.png", "Clock visible", "normal macOS, 142pt"),
    ("mode-2-blind.png",         "Blind",         "analog dial, 44pt"),
    ("mode-3-gone.png",          "Gone",          "patched over, experimental"),
    ("mode-4-hide-everything.png", "Hide everything", "whole bar, minus its own icon"),
]


def font(size, bold=False):
    for p in (
        "/System/Library/Fonts/SFNSDisplay.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
        "/Library/Fonts/Arial.ttf",
    ):
        try:
            return ImageFont.truetype(p, size, index=1 if bold and p.endswith("ttc") else 0)
        except OSError:
            continue
    return ImageFont.load_default()


crops = []
for fn, _, _ in ROWS:
    im = Image.open(fn).convert("RGB")
    keep = KEEP_RIGHT_PT * SCALE
    # Trim the bottom few pixels: the capture catches the top edge of whatever
    # window sits under the bar, which is not part of the menu bar.
    bar_h = int(im.height * 0.72)
    crops.append(im.crop((im.width - keep, 0, im.width, bar_h)))

row_w, row_h = crops[0].size
out_w = LABEL_W + row_w + PAD * 2
out_h = PAD * 2 + row_h * len(ROWS) + GAP * (len(ROWS) - 1)

out = Image.new("RGB", (out_w, out_h), BG)
d = ImageDraw.Draw(out)
f_name = font(30, bold=True)
f_note = font(23)

y = PAD
for (im, (_, name, note)) in zip(crops, ROWS):
    out.paste(im, (LABEL_W, y))
    d.rectangle([LABEL_W, y, LABEL_W + row_w - 1, y + row_h - 1], outline=(229, 225, 216))
    d.text((PAD, y + row_h // 2 - 30), name, font=f_name, fill=INK)
    d.text((PAD, y + row_h // 2 + 6), note, font=f_note, fill=SOFT)
    y += row_h + GAP

out.save("nocturne-modes.png")
print(f"wrote nocturne-modes.png  {out.width}x{out.height}")
