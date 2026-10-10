#!/usr/bin/env python3
"""Draws the FIT Studio app icon. Requires Pillow.

Usage: python3 scripts/make_icon.py Resources/AppIcon.png Resources/AppIcon.icns
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out_png, out_icns = sys.argv[1], sys.argv[2]

# macOS icon grid: ~824px rounded square centred on a 1024 canvas.
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
inset, size = 100, 824
radius = 185

# Diagonal gradient: teal to deep blue.
grad = Image.new("RGBA", (size, size))
top, bottom = (24, 196, 170), (34, 70, 196)
gd = ImageDraw.Draw(grad)
for y in range(size):
    t = y / (size - 1)
    gd.line([(0, y), (size, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)

shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([inset, inset + 14, inset + size, inset + size + 14], radius=radius, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
icon.alpha_composite(shadow)
icon.paste(grad, (inset, inset), mask)

# Drawn at 4x and scaled down for smooth lines.
K = 4
layer = Image.new("RGBA", (S * K, S * K), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)


def line(points, fill, width):
    pts = [(x * K, y * K) for x, y in points]
    d.line(pts, fill=fill, width=width * K, joint="curve")
    for x, y in pts:
        r = width * K / 2
        d.ellipse([x - r, y - r, x + r, y + r], fill=fill)


# Faint grid lines.
for y in (360, 512, 664):
    d.line([(220 * K, y * K), (804 * K, y * K)], fill=(255, 255, 255, 40), width=4 * K)
# Axis.
d.line([(220 * K, 760 * K), (804 * K, 760 * K)], fill=(255, 255, 255, 150), width=10 * K)

# Two recordings of the same ride: one translucent, one solid ("compare").
xs = [230, 320, 400, 470, 540, 610, 690, 790]
a = [640, 520, 575, 400, 455, 330, 420, 300]
b = [y + 46 for y in a]
line(list(zip(xs, b)), (255, 255, 255, 110), 30)
line(list(zip(xs, a)), (255, 255, 255, 255), 34)

layer = layer.resize((S, S), Image.LANCZOS)
icon.alpha_composite(layer)

icon.save(out_png)
icon.save(out_icns, sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("ok")
