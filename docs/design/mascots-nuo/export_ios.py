# /// script
# dependencies = ["pillow>=11"]
# ///
"""Exports Orb, the Nuo mascot, to the Xcode asset catalogs: the pebble body for MascotView (its glow and face are
drawn natively), the one-color watch complication silhouette, and the app icons (iOS, watchOS, macOS).

Run from the repo root: uv run docs/design/mascots-nuo/export_ios.py
Sources: raw/orb_idle.png (chosen concept), raw/orb_base.png (the same pebble without face nor glow) and the icon
masters in icon/ (orb_icon_tinted.png is derived from the dark one). The other raw/orb_<pose>.png are design references.
"""
import json
import shutil
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).parent
IOS = ROOT.parents[2] / "ios"
INFO = {"author": "xcode", "version": 1}


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def clean_alpha(img):
    # Generated PNGs carry faint halo pixels: drop them so crops and silhouettes stay tight.
    img.putalpha(img.getchannel("A").point(lambda a: 0 if a < 40 else a))
    return img


def canvas_box(img):
    """Square canvas around the pebble, a little larger than it, shared by every export so MascotView's face
    geometry (fractions of this square) lines up with the art."""
    left, top, right, bottom = img.getchannel("A").point(lambda a: 255 if a > 40 else 0).getbbox()
    side = int(max(right - left, bottom - top) * 1.082)
    cx, cy = (left + right) / 2, (top + bottom) / 2
    return int(cx - side / 2), int(cy - side / 2), int(cx - side / 2) + side, int(cy - side / 2) + side


def export_body():
    idle = clean_alpha(Image.open(ROOT / "raw/orb_idle.png").convert("RGBA"))
    base = clean_alpha(Image.open(ROOT / "raw/orb_base.png").convert("RGBA"))
    # The art has a bright rim that reads as a white sticker outline on light screens: pull the edge in past it.
    base.putalpha(base.getchannel("A").filter(ImageFilter.MinFilter(7)))
    sprite = base.crop(canvas_box(idle))
    out = IOS / "Nuo/Design/Mascot/Mascot.xcassets"
    shutil.rmtree(out, ignore_errors=True)
    folder = out / "MascotBody.imageset"
    folder.mkdir(parents=True)
    write_json(out / "Contents.json", {"info": INFO})
    images = [{"idiom": "universal", "scale": "1x"}]
    # Largest use is the 104 pt hero: 3x = 312 px, so 432 px leaves headroom without bloating the app.
    for scale, px in (("2x", 288), ("3x", 432)):
        filename = f"MascotBody@{scale}.png"
        sprite.resize((px, px), Image.LANCZOS).save(folder / filename, optimize=True)
        images.append({"filename": filename, "idiom": "universal", "scale": scale})
    write_json(folder / "Contents.json", {"images": images, "info": INFO, "properties": {"compression-type": "lossy"}})


def export_silhouette():
    """One-color Orb for tinted watch complications: the filled pebble with its two eye dashes cut out."""
    idle = clean_alpha(Image.open(ROOT / "raw/orb_idle.png").convert("RGBA"))
    alpha = idle.getchannel("A").point(lambda a: 255 if a >= 128 else 0)
    eyes = Image.new("L", idle.size, 0)
    px, out = idle.load(), eyes.load()
    for y in range(idle.height):
        for x in range(idle.width):
            r, g, b, a = px[x, y]
            if a > 200 and r + g + b < 300:
                out[x, y] = 255
    # Wider cuts than the drawn dashes: at 30 pt a hairline gap would close up.
    eyes = eyes.filter(ImageFilter.MaxFilter(9))
    shape = ImageChops.subtract(alpha, eyes).filter(ImageFilter.GaussianBlur(1.5)).point(lambda v: 255 if v >= 128 else 0)
    sprite = Image.new("RGBA", idle.size, (0, 0, 0, 0))
    sprite.paste(Image.new("RGBA", idle.size, (255, 255, 255, 255)), (0, 0), shape)
    sprite = sprite.crop(canvas_box(idle))
    catalog = IOS / "Watch/Complications/Complications.xcassets"
    for old in catalog.glob("*.imageset"):
        shutil.rmtree(old)
    folder = catalog / "MascotSilhouette.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    write_json(catalog / "Contents.json", {"info": INFO})
    sprite.resize((128, 128), Image.LANCZOS).save(folder / "MascotSilhouette@2x.png", optimize=True)
    write_json(folder / "Contents.json", {
        "images": [{"idiom": "universal", "scale": "1x"}, {"filename": "MascotSilhouette@2x.png", "idiom": "universal", "scale": "2x"}],
        "info": INFO, "properties": {"template-rendering-intent": "template"}})


def export_icons():
    # The espresso icon is the primary one too: Orb's glow reads best on dark. orb_icon_light_alt.png is the
    # warm neutral alternative, kept for reference.
    dark = Image.open(ROOT / "icon/orb_icon_dark.png").convert("RGB")
    light = dark
    tinted = Image.open(ROOT / "icon/orb_icon_tinted.png").convert("L")

    ios = IOS / "Nuo/Assets.xcassets/AppIcon.appiconset"
    for f in ios.iterdir():
        f.unlink()
    light.save(ios / "AppIcon.png")
    dark.save(ios / "AppIcon-Dark.png")
    tinted.save(ios / "AppIcon-Tinted.png")
    write_json(ios / "Contents.json", {"images": [
        {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "AppIcon-Dark.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}], "filename": "AppIcon-Tinted.png",
         "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ], "info": INFO})

    watch = IOS / "Watch/Assets.xcassets/AppIcon.appiconset"
    for f in watch.iterdir():
        f.unlink()
    light.save(watch / "AppIcon.png")
    write_json(watch / "Contents.json", {"images": [
        {"filename": "AppIcon.png", "idiom": "universal", "platform": "watchos", "size": "1024x1024"}], "info": INFO})

    # macOS does not mask icons: draw the standard rounded tile (824 on a 1024 canvas) and its shadow, at 4x for clean edges.
    size, inset, radius = 4096, 400, 740
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([inset, inset, size - inset - 1, size - inset - 1], radius=radius, fill=255)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_mask = mask.transform(mask.size, Image.AFFINE, (1, 0, 0, 0, 1, -48)).filter(ImageFilter.GaussianBlur(56))
    shadow.putalpha(shadow_mask.point(lambda a: int(a * 0.35)))
    canvas.alpha_composite(shadow)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    layer.paste(light.resize((size - 2 * inset, size - 2 * inset), Image.LANCZOS).convert("RGBA"), (inset, inset))
    layer.putalpha(mask)
    canvas.alpha_composite(layer)
    master = canvas.resize((1024, 1024), Image.LANCZOS)
    mac = IOS / "Mac/Assets.xcassets/AppIcon.appiconset"
    for f in mac.iterdir():
        f.unlink()
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            filename = f"icon_{pt}x{pt}@{scale}x.png"
            master.resize((pt * scale, pt * scale), Image.LANCZOS).save(mac / filename, optimize=True)
            images.append({"filename": filename, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    write_json(mac / "Contents.json", {"images": images, "info": INFO})


if __name__ == "__main__":
    export_body()
    export_silhouette()
    export_icons()
