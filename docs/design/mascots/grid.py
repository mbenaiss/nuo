# /// script
# dependencies = ["pillow>=11"]
# ///
"""Side-by-side animated comparison of every mascot and state, sampled on one shared timeline."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageSequence

ANIM = Path(__file__).parent / "anim"
MASCOTS = ["nono", "crema", "grain", "pip"]
STATES = ["idle", "talk", "think", "work", "done", "sleep"]
CELL, STEP, TOTAL, LABEL = 200, 80, 4800, 36


def timeline(path):
    img = Image.open(path)
    frames, t = [], 0
    for f in ImageSequence.Iterator(img):
        d = f.info.get("duration", 100)
        frames.append((t, t + d, f.convert("RGBA").resize((CELL, CELL), Image.LANCZOS)))
        t += d
    return frames, t


def at(frames, total, ms):
    ms %= total
    return next(f for start, end, f in frames if start <= ms < end)


tracks = {(m, s): timeline(ANIM / f"{m}_{s}.png") for m in MASCOTS for s in STATES}
font = ImageFont.load_default(size=22)
out = []
for ms in range(0, TOTAL, STEP):
    canvas = Image.new("RGBA", (CELL * len(STATES), LABEL + CELL * len(MASCOTS)), (246, 244, 240, 255))
    draw = ImageDraw.Draw(canvas)
    for c, s in enumerate(STATES):
        draw.text((c * CELL + CELL // 2, LABEL // 2), s, fill=(110, 108, 114), font=font, anchor="mm")
    for r, m in enumerate(MASCOTS):
        for c, s in enumerate(STATES):
            frames, total = tracks[(m, s)]
            canvas.alpha_composite(at(frames, total, ms), (c * CELL, LABEL + r * CELL))
    out.append(canvas.convert("P", palette=Image.ADAPTIVE, colors=255))
out[0].save(ANIM / "comparison.gif", save_all=True, append_images=out[1:], duration=STEP, loop=0, optimize=True)
print(len(out), "frames")
