#!/usr/bin/env python3
"""Draws the TallySeam app icon (1024x1024 PNG, opaque, full-bleed: iOS rounds the corners).

Design: a white T with stitched seams along its bar and stem on teal, with the AM logo in a black
block in the bottom-right corner. Rendered at 4x and scaled down for smooth edges.

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
    d.rounded_rectangle([p(250), p(230), p(734), p(360)], radius=p(34), fill=WHITE)
    d.rounded_rectangle([p(427), p(230), p(557), p(770)], radius=p(34), fill=WHITE)
    dashed_line(d, (p(285), p(295)), (p(699), p(295)), p(18), p(46), p(34), TEAL)
    dashed_line(d, (p(492), p(390)), (p(492), p(740)), p(18), p(46), p(34), TEAL)

    # Black corner block running to the bottom and right edges; iOS's rounded icon corner becomes its
    # outer edge. Only the inner (top-left) corner is rounded, like the logo's own square.
    block = 300
    bx = 1024 - block
    d.rounded_rectangle([p(bx), p(bx), p(1024) + p(200), p(1024) + p(200)], radius=p(75), fill=BLACK)

    # The AM logo as one row, "• A • M •", centred in the part of the block iOS doesn't round off
    # (a little up and left of the block's middle, because the outer corner is cut away).
    f = font(p(70))
    r, gap = p(9), p(12)
    parts = ["dot", "A", "dot", "M", "dot"]
    widths = [2 * r if t == "dot" else f.getlength(t) for t in parts]
    total = sum(widths) + gap * (len(parts) - 1)
    x = p(bx + 135) - total / 2
    baseline = p(bx + 150)
    cap = f.getbbox("A", anchor="ls")[1]  # negative: cap height above the baseline
    for t, w in zip(parts, widths):
        if t == "dot":
            cy = baseline + cap / 2
            d.ellipse([x, cy - r, x + 2 * r, cy + r], fill=WHITE)
        else:
            d.text((x, baseline), t, font=f, fill=WHITE, anchor="ls")
        x += w + gap

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
