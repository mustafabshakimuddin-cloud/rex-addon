"""Makes the Mac app icon set from the iPhone icon (tools/make_icon.py draws that one).

    python3 app/tools/make_mac_icon.py

macOS takes the artwork full-bleed and applies its own rounded shape. Writes
ReelMac/Assets.xcassets.
"""
import json, os
from PIL import Image

HERE = os.path.dirname(__file__)
SOURCE = os.path.join(HERE, "..", "Reel", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")
ROOT = os.path.join(HERE, "..", "ReelMac", "Assets.xcassets")
INFO = {"author": "xcode", "version": 1}

icon_set = os.path.join(ROOT, "AppIcon.appiconset")
os.makedirs(icon_set, exist_ok=True)
art = Image.open(SOURCE).convert("RGB")
images = []
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        pixels = points * scale
        name = f"icon_{points}x{points}@{scale}x.png"
        art.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(icon_set, name))
        images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}", "filename": name})
with open(os.path.join(icon_set, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": INFO}, f, indent=2)
with open(os.path.join(ROOT, "Contents.json"), "w") as f:
    json.dump({"info": INFO}, f, indent=2)
accent = os.path.join(ROOT, "AccentColor.colorset")
os.makedirs(accent, exist_ok=True)
with open(os.path.join(HERE, "..", "Reel", "Assets.xcassets", "AccentColor.colorset", "Contents.json")) as f:
    data = json.load(f)
with open(os.path.join(accent, "Contents.json"), "w") as f:
    json.dump(data, f, indent=2)
print("wrote", os.path.normpath(ROOT))
