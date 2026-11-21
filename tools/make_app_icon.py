#!/usr/bin/env python3
"""Draws the TallySeam app icon (1024x1024 PNG, opaque, full-bleed: iOS rounds the corners).

Design: four white tally marks crossed by a stitched mint seam on navy, with the AM monogram badge
in the bottom-right corner. Rendered at 4x and scaled down for smooth edges.

Usage: python tools/make_app_icon.py
Writes TallySeam/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png and branding/AppIcon-1024.png.
Needs Pillow and a serif font (Georgia, Lora or Times).
"""
import math
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
S = 4  # supersampling factor
SIZE = 1024 * S
NAVY = (20, 33, 61)
WHITE = (255, 255, 255)
MINT = (94, 234, 212)
BLACK = (0, 0, 0)

FONT_CANDIDATES = [
    "C:/Windows/Fonts/georgia.ttf",
    "/System/Library/Fonts/Supplemental/Georgia.ttf",
    "/Library/Fonts/Lora-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf",
    "C:/Windows/Fonts/times.ttf",
]


def font(px):
    for path in FONT_CANDIDATES:
        if pathlib.Path(path).exists():
            return ImageFont.truetype(path, px)
    sys.exit("No serif font found; add one to FONT_CANDIDATES.")


def p(v):
    return v * S


def round_line(d, a, b, width, color):
    d.line([a, b], fill=color, width=width)
    r = width / 2
    for (x, y) in (a, b):
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def dashed_line(d, a, b, width, dash, gap, color):
    (x1, y1), (x2, y2) = a, b
    length = math.hypot(x2 - x1, y2 - y1)
    ux, uy = (x2 - x1) / length, (y2 - y1) / length
    t = 0.0
    while t < length:
        e = min(t + dash, length)
        round_line(d, (x1 + ux * t, y1 + uy * t), (x1 + ux * e, y1 + uy * e), width, color)
        t += dash + gap


def draw():
    img = Image.new("RGB", (SIZE, SIZE), NAVY)
    d = ImageDraw.Draw(img)

    # Four tally marks.
    for x in (230, 360, 490, 620):
        round_line(d, (p(x), p(220)), (p(x), p(690)), p(64), WHITE)
    # The stitched seam crossing them, in place of the fifth stroke.
    dashed_line(d, (p(160), p(640)), (p(720), p(300)), p(50), p(86), p(50), MINT)

    # AM monogram badge (the developer's logo): black rounded square, A and dot on top, dot and M below.
    # Kept clear of the corner iOS rounds off (about 230 px radius at 1024).
    x0, y0, size = 680, 680, 280
    d.rounded_rectangle([p(x0), p(y0), p(x0 + size), p(y0 + size)], radius=p(64), fill=BLACK)
    f = font(p(110))
    d.text((p(x0 + 78), p(y0 + 108)), "A", font=f, fill=WHITE, anchor="mm")
    d.text((p(x0 + 190), p(y0 + 190)), "M", font=f, fill=WHITE, anchor="mm")
    r = p(16)
    for (cx, cy) in ((x0 + 200, y0 + 90), (x0 + 80, y0 + 196)):
        d.ellipse([p(cx) - r, p(cy) - r, p(cx) + r, p(cy) + r], fill=WHITE)

    return img.resize((1024, 1024), Image.LANCZOS)


def main():
    icon = draw()
    targets = [ROOT / "TallySeam/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
               ROOT / "branding/AppIcon-1024.png"]
    for t in targets:
        t.parent.mkdir(parents=True, exist_ok=True)
        icon.save(t, "PNG", optimize=True)
        print("wrote", t.relative_to(ROOT))


if __name__ == "__main__":
    main()
