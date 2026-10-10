#!/usr/bin/env python3
"""Draws the DMG window background (1x and 2x). Requires Pillow.

Usage: python3 scripts/make_dmg_background.py Resources/dmg-background.png Resources/dmg-background@2x.png
Icon positions must match scripts/dmg_settings.py.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 600, 400
APP_X, APPS_X, ICON_Y = 160, 440, 185


def font(size):
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def draw(scale):
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(img)
    top, bottom = (252, 250, 247), (238, 234, 228)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))

    # Arrow from the app to Applications, in the icon's teal.
    accent = (24, 160, 160)
    y = ICON_Y * scale
    x0, x1 = (APP_X + 82) * scale, (APPS_X - 82) * scale
    d.line([(x0, y), (x1 - 14 * scale, y)], fill=accent, width=6 * scale)
    d.polygon([(x1, y), (x1 - 22 * scale, y - 14 * scale), (x1 - 22 * scale, y + 14 * scale)], fill=accent)

    title = "Drag FIT Studio into Applications"
    sub = "Then open it from Launchpad or Spotlight."
    f1, f2 = font(17 * scale), font(13 * scale)
    for text, f, ty, colour in ((title, f1, 318, (40, 40, 40)), (sub, f2, 346, (110, 110, 110))):
        tw = d.textlength(text, font=f)
        d.text(((w - tw) / 2, ty * scale), text, font=f, fill=colour)
    return img


if __name__ == "__main__":
    draw(1).save(sys.argv[1])
    draw(2).save(sys.argv[2])
