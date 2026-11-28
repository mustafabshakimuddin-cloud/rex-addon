"""Draws the Apple TV icon and Top Shelf images from the same artwork as the iPhone icon.

    python3 app/tools/make_tv_icon.py

tvOS icons are layered (the Home Screen tilts the layers apart as focus moves): a back layer with
the gradient and a front layer with the reel and play symbol, on a transparent background.
Writes ReelTV/Assets.xcassets.
"""
import json, math, os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..", "ReelTV", "Assets.xcassets")
INFO = {"author": "xcode", "version": 1}
STOPS = [(0.0, (20, 16, 52)), (0.55, (74, 36, 140)), (1.0, (214, 64, 120))]


def mix(t):
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * k) for a, b in zip(c0, c1))
    return STOPS[-1][1]


def back(w, h):
    # Drawn small and scaled up: a gradient has no detail to lose.
    sw, sh = max(1, w // 8), max(1, h // 8)
    img = Image.new("RGB", (sw, sh))
    px = img.load()
    for y in range(sh):
        for x in range(sw):
            px[x, y] = mix(min(1.0, (x / sw) * 0.55 + (y / sh) * 0.45))
    img = img.resize((w, h), Image.BICUBIC).convert("RGBA")
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    r = h * 0.42
    ImageDraw.Draw(glow).ellipse((w / 2 - r, h / 2 - r, w / 2 + r, h / 2 + r), fill=(255, 190, 230, 80))
    return Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(h * 0.12))).convert("RGB")


def front(w, h, cx=None, scale=0.34):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = w / 2 if cx is None else cx
    cy = h / 2
    R = h * scale
    d.ellipse((cx - R, cy - R, cx + R, cy + R), outline=(255, 255, 255, 240), width=max(2, round(R * 0.153)))
    holes = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    hd = ImageDraw.Draw(holes)
    for i in range(5):
        a = math.radians(-90 + 36 + i * 72)
        hx, hy, hr = cx + math.cos(a) * R * 0.683, cy + math.sin(a) * R * 0.683, R * 0.147
        hd.ellipse((hx - hr, hy - hr, hx + hr, hy + hr), fill=(255, 255, 255, 70))
    img = Image.alpha_composite(img, holes)
    d = ImageDraw.Draw(img)
    k = R / 300
    d.polygon([(cx - 70 * k, cy - 110 * k), (cx - 70 * k, cy + 110 * k), (cx + 120 * k, cy)], fill=(255, 255, 255, 255))
    return img


def write_json(folder, data):
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump(data, f, indent=2)


def imageset(folder, sizes, draw):
    images = []
    for scale, (w, h) in sizes:
        name = f"image@{scale}.png"
        os.makedirs(folder, exist_ok=True)
        draw(w, h).save(os.path.join(folder, name))
        images.append({"idiom": "tv", "scale": scale, "filename": name})
    write_json(folder, {"images": images, "info": INFO})


def imagestack(folder, sizes):
    write_json(folder, {"info": INFO, "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer, draw in (("Front", front), ("Back", back)):
        path = os.path.join(folder, f"{layer}.imagestacklayer")
        write_json(path, {"info": INFO})
        imageset(os.path.join(path, "Content.imageset"), sizes, draw)


def shelf(w, h):
    img = back(w, h).convert("RGBA")
    return Image.alpha_composite(img, front(w, h, cx=w * 0.5, scale=0.28)).convert("RGB")


brand = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")
write_json(ROOT, {"info": INFO})
write_json(brand, {"assets": [
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
], "info": INFO})
imagestack(os.path.join(brand, "App Icon.imagestack"), [("1x", (400, 240)), ("2x", (800, 480))])
imagestack(os.path.join(brand, "App Icon - App Store.imagestack"), [("1x", (1280, 768))])
imageset(os.path.join(brand, "Top Shelf Image.imageset"), [("1x", (1920, 720)), ("2x", (3840, 1440))], shelf)
imageset(os.path.join(brand, "Top Shelf Image Wide.imageset"), [("1x", (2320, 720)), ("2x", (4640, 1440))], shelf)
accent = os.path.join(ROOT, "AccentColor.colorset")
src = os.path.join(os.path.dirname(__file__), "..", "Reel", "Assets.xcassets", "AccentColor.colorset", "Contents.json")
write_json(accent, json.load(open(src)))
print("wrote", os.path.normpath(ROOT))
