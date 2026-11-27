# /// script
# dependencies = ["pillow>=11"]
# ///
"""Turns the Codex mascot poses (raw/<mascot>_<pose>.png) into looping state animations (APNG + GIF) and a sheet."""
import math
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).parent
RAW, OUT = ROOT / "raw", ROOT / "anim"
SIZE = 320
POSES = ["idle", "blink", "talk_a", "talk_b", "think", "work", "done", "sleep"]


def load(mascot):
    frames = {p: Image.open(RAW / f"{mascot}_{p}.png").convert("RGBA") for p in POSES if (RAW / f"{mascot}_{p}.png").exists()}
    for img in frames.values():
        # Generated PNGs carry faint halo pixels: drop them so the crop box and edges stay clean.
        img.putalpha(img.getchannel("A").point(lambda a: 0 if a < 40 else a))
    boxes = [img.getbbox() for img in frames.values() if img.getbbox()]
    # One union box for every pose keeps the same scale and baseline, so switching poses never makes it jump.
    left, top = min(b[0] for b in boxes), min(b[1] for b in boxes)
    right, bottom = max(b[2] for b in boxes), max(b[3] for b in boxes)
    side = max(right - left, bottom - top)
    cx = (left + right) / 2
    box = (int(cx - side / 2), int(bottom - side), int(cx + side / 2), int(bottom))
    inner = int(SIZE * 0.82)
    out = {}
    for pose, img in frames.items():
        sprite = img.crop(box).resize((inner, inner), Image.LANCZOS)
        out[pose] = sprite
    return out


def frame(sprite, dy=0.0, scale=1.0):
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    w = int(sprite.width * scale)
    s = sprite.resize((w, w), Image.LANCZOS) if scale != 1.0 else sprite
    x = (SIZE - s.width) // 2
    y = SIZE - s.height - int(SIZE * 0.06) + int(round(dy))
    canvas.alpha_composite(s, (x, y))
    return canvas


def animations(f):
    """state -> list of (image, duration ms)."""
    def bob(pose, amp, period_frames, ms):
        return [(frame(f[pose], dy=amp * math.sin(2 * math.pi * i / period_frames)), ms) for i in range(period_frames)]

    anims = {}
    idle = bob("idle", 3, 24, 80)
    if "blink" in f:
        idle[10] = (frame(f["blink"], dy=3 * math.sin(2 * math.pi * 10 / 24)), 120)
    anims["idle"] = idle
    if "talk_a" in f and "talk_b" in f:
        seq = ["talk_a", "talk_b", "idle", "talk_b", "talk_a", "idle"]
        anims["talk"] = [(frame(f[p], dy=-2 if p == "talk_a" else 0), 150) for p in seq]
    if "think" in f:
        anims["think"] = bob("think", 4, 20, 110)
    if "work" in f:
        anims["work"] = [(frame(f["work"], dy=-3 if i % 2 else 0), 120) for i in range(8)]
    if "done" in f:
        pops = [0.9, 1.05, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
        anims["done"] = [(frame(f["done"], scale=s), 90 if i < 3 else 160) for i, s in enumerate(pops)]
    if "sleep" in f:
        anims["sleep"] = bob("sleep", 2, 16, 200)
    return anims


def save(name, frames):
    images, durations = zip(*frames)
    images[0].save(OUT / f"{name}.png", save_all=True, append_images=list(images[1:]), duration=list(durations), loop=0, disposal=1)
    images[0].save(OUT / f"{name}.gif", save_all=True, append_images=list(images[1:]), duration=list(durations), loop=0, disposal=2, transparency=0, optimize=False)


def main(mascots):
    OUT.mkdir(exist_ok=True)
    for mascot in mascots:
        f = load(mascot)
        for state, frames in animations(f).items():
            save(f"{mascot}_{state}", frames)
        sheet = Image.new("RGBA", (SIZE * len(f), SIZE), (0, 0, 0, 0))
        for i, pose in enumerate(POSES):
            if pose in f:
                sheet.alpha_composite(frame(f[pose]), (i * SIZE, 0))
        sheet.save(OUT / f"{mascot}_sheet.png")
        print(mascot, sorted(animations(f)))


if __name__ == "__main__":
    main(sys.argv[1:] or ["nono", "crema", "grain", "pip"])
