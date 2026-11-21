#!/usr/bin/env python3
"""Draws the TallySeam app icon (1024x1024 PNG, opaque, full-bleed: iOS rounds the corners).

Design: a white T with stitched seams along its bar and stem on teal, with a white band along the
bottom carrying the AM logo in one black line (dot A dot M dot). Rendered at 4x and scaled down for smooth edges.

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
    d.rounded_rectangle([p(250), p(190), p(774), p(320)], radius=p(34), fill=WHITE)
    d.rounded_rectangle([p(447), p(190), p(577), p(720)], radius=p(34), fill=WHITE)
    dashed_line(d, (p(285), p(255)), (p(739), p(255)), p(18), p(46), p(34), TEAL)
    dashed_line(d, (p(512), p(350)), (p(512), p(690)), p(18), p(46), p(34), TEAL)

    # White band along the bottom with the AM logo in one black line: dot A dot M dot, evenly spaced.
    # iOS rounds the band's outer corners along with the icon.
    band_top = 880
    d.rectangle([0, p(band_top), SIZE, SIZE], fill=WHITE)
    cy = (band_top + 1024) / 2
    f = font(p(64))
    r = p(10)
    # Equal visible gaps between neighbours (edge to edge), spanning the same width as before.
    items = ["•", "A", "•", "M", "•"]
    widths = []
    for item in items:
        if item == "•":
            widths.append(2 * r)
        else:
            x0, _, x1, _ = d.textbbox((0, 0), item, font=f, anchor="lt")
            widths.append(x1 - x0)
    span = p(620)
    gap = (span - sum(widths)) / (len(items) - 1)
    x = p(512) - span / 2
    for item, w in zip(items, widths):
        cx = x + w / 2
        if item == "•":
            d.ellipse([cx - r, p(cy) - r, cx + r, p(cy) + r], fill=BLACK)
        else:
            d.text((cx, p(cy)), item, font=f, fill=BLACK, anchor="mm")
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
