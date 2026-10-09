import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out_png, out_icns = sys.argv[1], sys.argv[2]

# macOS icon grid: ~824px rounded square centred on a 1024 canvas.
icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
inset, size = 100, 824
radius = 185

# Vertical gradient: warm orange to deep red.
grad = Image.new("RGBA", (size, size))
top, bottom = (255, 138, 36), (214, 40, 57)
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

def bolt(cx, cy, scale):
    pts = [(0.10, -0.50), (-0.28, 0.06), (-0.02, 0.06), (-0.12, 0.50), (0.28, -0.08), (0.02, -0.08)]
    return [(cx + x * scale, cy + y * scale) for x, y in pts]

layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
# Two bolts: one solid, one translucent behind it ("dual").
d.polygon(bolt(445, 512, 520), fill=(255, 255, 255, 110))
d.polygon(bolt(585, 512, 520), fill=(255, 255, 255, 255))
icon.alpha_composite(layer)

icon.save(out_png)
icon.save(out_icns, sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("ok")
