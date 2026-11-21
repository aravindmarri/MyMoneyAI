#!/usr/bin/env python3
"""Draws the TallySeam app icon (1024x1024 PNG, opaque, full-bleed: iOS rounds the corners).

Design: a white T with stitched seams along its bar and stem on teal, with the AM logo as one line
(dot A dot M dot) on a black band across the bottom. Rendered at 4x and scaled down for smooth edges.

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
TEAL = (15, 118, 110)
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
    img = Image.new("RGB", (SIZE, SIZE), TEAL)
    d = ImageDraw.Draw(img)

    # A white T (bar and stem) with stitched seams running along the middle of each.
    d.rounded_rectangle([p(250), p(170), p(774), p(300)], radius=p(34), fill=WHITE)
    d.rounded_rectangle([p(447), p(170), p(577), p(700)], radius=p(34), fill=WHITE)
    dashed_line(d, (p(285), p(235)), (p(739), p(235)), p(18), p(46), p(34), TEAL)
    dashed_line(d, (p(512), p(330)), (p(512), p(670)), p(18), p(46), p(34), TEAL)

    # The AM logo as one horizontal line, dot A dot M dot, evenly spaced, white on a black band across
    # the bottom (iOS rounds the band's lower corners with the icon).
    d.rectangle([0, p(800), SIZE, SIZE], fill=BLACK)
    cy, step = 902, 120
    xs = [512 + (i - 2) * step for i in range(5)]
    r = p(14)
    f = font(p(96))
    for i, x in enumerate(xs):
        if i % 2 == 0:
            d.ellipse([p(x) - r, p(cy) - r, p(x) + r, p(cy) + r], fill=WHITE)
        else:
            d.text((p(x), p(cy)), "A" if i == 1 else "M", font=f, fill=WHITE, anchor="mm")

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
