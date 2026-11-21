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

    # Black corner block running to the bottom and right edges; iOS's rounded icon corner becomes its
    # outer edge. Only the inner (top-left) corner is rounded, like the logo's own square.
    block = 300
    bx = 1024 - block
    d.rounded_rectangle([p(bx), p(bx), p(1024) + p(200), p(1024) + p(200)], radius=p(75), fill=BLACK)

    # The AM logo exactly as in branding/am-logo.svg (a 75-unit square): "A" and a dot on top, a dot and
    # "M" below, same positions and sizes, centred in the part of the block iOS doesn't round off
    # (slightly up and left of the block's middle, because the outer corner is cut away).
    L = 220
    lx, ly = bx + 30, bx + 30

    def u(v):
        return v / 75 * L

    d.text((p(lx + u(13.0)), p(ly + u(25.9))), "A", font=font(p(u(19.41))), fill=WHITE, anchor="ls")
    d.text((p(lx + u(47.41)), p(ly + u(63.47))), "M", font=font(p(u(20.38))), fill=WHITE, anchor="ls")
    r = p(u(3.75))
    for (cx, cy) in ((56.25, 18.77), (18.75, 56.32)):
        x, y = p(lx + u(cx)), p(ly + u(cy))
        d.ellipse([x - r, y - r, x + r, y + r], fill=WHITE)

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
