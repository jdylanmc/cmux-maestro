#!/usr/bin/env python3
"""Generate the original bundled Maestro pet sprite sheet.

Output follows the Codex pet contract: a 1536x1872 transparent WebP, 8 columns
by 9 rows of 192x208 cells. The artwork is original to this project. Requires
Pillow (development-time only; the generated asset is committed).

    python3 scripts/generate-maestro-pet.py [output-directory]
"""
import json
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw

CELL_W, CELL_H, COLS, ROWS = 192, 208, 8, 9
SS = 4  # supersampling
FRAMES = [6, 8, 8, 4, 5, 8, 6, 6, 6]
# idle, run right, run left, wave, jump, failure, waiting, working, review

SHELL = (226, 232, 240, 255)
SHELL_SHADE = (176, 188, 206, 255)
OUTLINE = (38, 50, 72, 255)
VISOR = (24, 34, 52, 255)
GLOW = (115, 191, 255, 255)
GLOW_DIM = (70, 120, 170, 255)
ALERT = (255, 112, 112, 255)
GOOD = (120, 230, 170, 255)


def s(v):
    return v * SS


def draw_head(d, dx=0, dy=0, tilt=0, eye="open", look=0, antenna=GLOW, squash=1.0, mouth="flat"):
    cx, cy = CELL_W / 2 + dx, 118 + dy
    w, h = 112, 92 * squash
    # shadow
    d.ellipse([s(cx - 46), s(190), s(cx + 46), s(200)], fill=(0, 0, 0, 50))
    # antenna
    ax = cx + tilt * 0.6
    d.line([s(cx), s(cy - h / 2), s(ax), s(cy - h / 2 - 22)], fill=OUTLINE, width=s(5))
    d.ellipse([s(ax - 8), s(cy - h / 2 - 34), s(ax + 8), s(cy - h / 2 - 18)], fill=antenna, outline=OUTLINE, width=s(3))
    # ears
    for sx in (-1, 1):
        ex = cx + sx * (w / 2 + 2)
        d.rounded_rectangle([s(ex - 8), s(cy - 14), s(ex + 8), s(cy + 14)], radius=s(5), fill=SHELL_SHADE, outline=OUTLINE, width=s(3))
    # head
    d.rounded_rectangle([s(cx - w / 2), s(cy - h / 2), s(cx + w / 2), s(cy + h / 2)], radius=s(26), fill=SHELL, outline=OUTLINE, width=s(4))
    d.rounded_rectangle([s(cx - w / 2 + 6), s(cy + h / 2 - 22), s(cx + w / 2 - 6), s(cy + h / 2 - 6)], radius=s(10), fill=SHELL_SHADE)
    # visor
    vx0, vx1, vy0, vy1 = cx - 42, cx + 42, cy - 26, cy + 14
    d.rounded_rectangle([s(vx0), s(vy0), s(vx1), s(vy1)], radius=s(14), fill=VISOR, outline=OUTLINE, width=s(3))
    ey = (vy0 + vy1) / 2
    for sx in (-1, 1):
        ex = cx + sx * 20 + look
        if eye == "open":
            d.rounded_rectangle([s(ex - 8), s(ey - 10), s(ex + 8), s(ey + 10)], radius=s(6), fill=GLOW)
        elif eye == "blink":
            d.rounded_rectangle([s(ex - 8), s(ey - 2), s(ex + 8), s(ey + 2)], radius=s(2), fill=GLOW)
        elif eye == "happy":
            d.arc([s(ex - 9), s(ey - 8), s(ex + 9), s(ey + 10)], 200, 340, fill=GOOD, width=s(5))
        elif eye == "x":
            d.line([s(ex - 7), s(ey - 7), s(ex + 7), s(ey + 7)], fill=ALERT, width=s(4))
            d.line([s(ex - 7), s(ey + 7), s(ex + 7), s(ey - 7)], fill=ALERT, width=s(4))
        elif eye == "up":
            d.rounded_rectangle([s(ex - 8), s(ey - 12), s(ex + 8), s(ey + 4)], radius=s(6), fill=GLOW)
        elif eye == "narrow":
            d.rounded_rectangle([s(ex - 9), s(ey - 4), s(ex + 9), s(ey + 4)], radius=s(3), fill=GLOW)
    # mouth
    my = cy + h / 2 - 16
    if mouth == "flat":
        d.line([s(cx - 12), s(my), s(cx + 12), s(my)], fill=OUTLINE, width=s(4))
    elif mouth == "smile":
        d.arc([s(cx - 14), s(my - 10), s(cx + 14), s(my + 6)], 20, 160, fill=OUTLINE, width=s(4))
    elif mouth == "frown":
        d.arc([s(cx - 14), s(my - 2), s(cx + 14), s(my + 14)], 200, 340, fill=OUTLINE, width=s(4))
    elif mouth == "o":
        d.ellipse([s(cx - 6), s(my - 6), s(cx + 6), s(my + 6)], outline=OUTLINE, width=s(3))
    return cx, cy, h


def bubble_question(d, cx, cy, pulse):
    r = 20 + 2 * pulse
    bx, by = cx + 58, cy - 62
    d.ellipse([s(bx - r), s(by - r), s(bx + r), s(by + r)], fill=(20, 40, 66, 255), outline=GLOW, width=s(3))
    d.arc([s(bx - 9), s(by - 14), s(bx + 9), s(by + 2)], 190, 40, fill=GLOW, width=s(4))
    d.line([s(bx), s(by + 2), s(bx), s(by + 6)], fill=GLOW, width=s(4))
    d.ellipse([s(bx - 2), s(by + 10), s(bx + 2), s(by + 14)], fill=GLOW)


def frame(row, i, n):
    img = Image.new("RGBA", (s(CELL_W), s(CELL_H)), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    t = i / n
    wave = math.sin(t * 2 * math.pi)
    if row == 0:
        draw_head(d, dy=2 * wave, eye="blink" if i == 4 else "open", antenna=GLOW if i % 6 < 3 else GLOW_DIM)
    elif row in (1, 2):
        sign = 1 if row == 1 else -1
        bounce = -abs(math.sin(t * 2 * math.pi)) * 8
        draw_head(d, dx=sign * 4, dy=bounce, tilt=sign * 10, look=sign * 6, mouth="smile", antenna=GLOW)
    elif row == 3:
        draw_head(d, dy=-3 * abs(wave), eye="happy", mouth="smile", antenna=GOOD, tilt=8 * wave)
    elif row == 4:
        lift = [0, -18, -30, -18, 0][i % 5]
        sq = [0.9, 1.04, 1.06, 1.04, 0.9][i % 5]
        draw_head(d, dy=lift + (8 if i == 0 else 0), squash=sq, eye="open", mouth="o")
    elif row == 5:
        draw_head(d, dx=3 * wave, eye="x", mouth="frown", antenna=ALERT if i % 2 == 0 else (120, 50, 50, 255), tilt=6 * wave)
    elif row == 6:
        pulse = math.sin(t * 2 * math.pi)
        cx, cy, h = draw_head(d, eye="up", look=-2, tilt=-6, antenna=GLOW if i % 2 == 0 else GLOW_DIM, mouth="o")
        bubble_question(d, cx, cy, pulse)
    elif row == 7:
        look = [-9, -5, 0, 5, 9, 5][i % 6] if n == 6 else 0
        cx, cy, h = draw_head(d, look=look, antenna=GLOW if i % 2 == 0 else GLOW_DIM, mouth="flat")
        for k in range(3):
            on = (i + k) % 3 == 0
            d.ellipse([s(cx - 22 + k * 22 - 4), s(cy - h / 2 - 52), s(cx - 22 + k * 22 + 4), s(cy - h / 2 - 44)],
                      fill=GLOW if on else GLOW_DIM)
    elif row == 8:
        cx, cy, h = draw_head(d, eye="narrow", look=[-8, -3, 2, 7, 2, -3][i % 6], mouth="flat", dy=1 * wave)
        sweep = cx - 36 + (i % 6) * 14
        d.rectangle([s(sweep), s(cy - 22), s(sweep + 4), s(cy + 10)], fill=(115, 191, 255, 150))
    return img.resize((CELL_W, CELL_H), Image.LANCZOS)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "CMUXMaestroSidebar/Pets")
    out.mkdir(parents=True, exist_ok=True)
    sheet = Image.new("RGBA", (CELL_W * COLS, CELL_H * ROWS), (0, 0, 0, 0))
    for r in range(ROWS):
        for c in range(FRAMES[r]):
            sheet.paste(frame(r, c, FRAMES[r]), (c * CELL_W, r * CELL_H))
    sheet.save(out / "maestro-pet.webp", "WEBP", lossless=True, quality=100, method=6)
    (out / "maestro-pet.json").write_text(json.dumps({
        "id": "maestro",
        "displayName": "Maestro",
        "description": "An original AI robot head that tracks agent state. Created for CMUX Maestro.",
        "spritesheetPath": "maestro-pet.webp",
    }, indent=2) + "\n")
    if "--preview" in sys.argv:
        sheet.save(Path("/tmp/maestro-pet-preview.png"))


if __name__ == "__main__":
    main()
