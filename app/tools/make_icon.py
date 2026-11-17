"""Draws the app icon: a play symbol inside a film reel on a deep indigo-to-magenta gradient.

    python3 app/tools/make_icon.py

Writes Reel/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024, no alpha, as the App
Store requires). Original artwork, drawn here, so the icon can be changed by editing this file.
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
out = os.path.join(os.path.dirname(__file__), "..", "Reel", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")

# Diagonal gradient: deep indigo -> violet -> warm magenta.
grad = Image.new("RGB", (S, S))
px = grad.load()
stops = [(0.0, (20, 16, 52)), (0.55, (74, 36, 140)), (1.0, (214, 64, 120))]
def mix(t):
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
    return stops[-1][1]
for y in range(S):
    for x in range(S):
        px[x, y] = mix(min(1.0, (x * 0.35 + y * 0.65) / S))

img = grad.convert("RGBA")
# Soft glow behind the reel.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((212, 212, 812, 812), fill=(255, 190, 230, 90))
img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(90)))

d = ImageDraw.Draw(img)
cx = cy = S // 2
R = 300
white = (255, 255, 255, 240)
d.ellipse((cx - R, cy - R, cx + R, cy + R), outline=white, width=46)
# Five translucent reel holes near the rim, drawn on their own layer so they blend.
holes = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(holes)
for i in range(5):
    a = math.radians(-90 + 36 + i * 72)
    hx, hy, hr = cx + math.cos(a) * 205, cy + math.sin(a) * 205, 44
    hd.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=(255, 255, 255, 60))
img = Image.alpha_composite(img, holes)
d = ImageDraw.Draw(img)
# Play triangle, optically centred (nudged right).
tri = [(cx - 70, cy - 110), (cx - 70, cy + 110), (cx + 120, cy)]
d.polygon(tri, fill=(255, 255, 255, 255))

img.convert("RGB").save(out, "PNG")
print("wrote", os.path.normpath(out))
