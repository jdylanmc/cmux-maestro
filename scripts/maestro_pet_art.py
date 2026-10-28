"""Original extended Maestro expressions, drawn with the installed pet kit."""
import math
import sys
from pathlib import Path

from PIL import Image

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".agents/skills/maestro-pet"))
from pet_kit import Canvas

SHELL, SHADE, OUTLINE = "#e2e8f0", "#b0bcce", "#263248"
VISOR, BLUE, GREEN, AMBER = "#182234", "#73bfff", "#78e6aa", "#ffd078"


class Drawing:
    def __init__(self):
        self.canvas = Canvas(384, 416)

    def rect(self, x0, y0, x1, y1, color):
        self.canvas.rect(x0 * 2, y0 * 2, x1 * 2, y1 * 2, color)

    def ellipse(self, x, y, rx, ry, color):
        self.canvas.ellipse(x * 2, y * 2, rx * 2, ry * 2, color)

    def line(self, x0, y0, x1, y1, color, width=3):
        self.canvas.line(x0 * 2, y0 * 2, x1 * 2, y1 * 2, color, width * 2)

    def roundrect(self, x0, y0, x1, y1, r, color):
        self.rect(x0 + r, y0, x1 - r, y1, color)
        self.rect(x0, y0 + r, x1, y1 - r, color)
        for x in (x0 + r, x1 - r):
            for y in (y0 + r, y1 - r):
                self.ellipse(x, y, r, r, color)

    def path(self, points, color, width=3):
        for a, b in zip(points, points[1:]):
            self.line(*a, *b, color, width)

    def hand(self, x, y, raised=False):
        self.roundrect(x - 11, y - 12, x + 11, y + 12, 7, OUTLINE)
        self.roundrect(x - 8, y - 9, x + 8, y + 9, 5, SHELL)
        if raised:
            for shift in (-5, 0, 5):
                self.line(x + shift, y - 16, x + shift, y, SHELL, 4)

    def finish(self):
        image = Image.frombytes("RGBA", (384, 416), bytes(self.canvas.pixels))
        image = image.resize((192, 208), Image.Resampling.LANCZOS)
        result = Canvas()
        result.pixels[:] = image.tobytes()
        return result


def mood_frame(state, index, count):
    d = Drawing()
    wave = math.sin(index / count * math.tau)
    cx, cy, half = 96, 118 + wave * 2, 56
    color = GREEN if state in ("proud", "celebrating") else BLUE
    if state == "sleepy":
        cy += 10
    if state == "startled":
        cy -= [12, 20, 16, 8, 12][index]
        color = AMBER
    if state == "proud":
        cy -= 6
    if state == "celebrating":
        cy -= [4, 14, 22, 14, 4][index]
    if state == "compacting":
        half = 38 + 4 * wave
    d.ellipse(96, 195, 46, 5, "#00000032")
    if state == "gone":
        d.line(96, 75, 96 + 3 * wave, 48, SHADE, 5)
        d.ellipse(96 + 3 * wave, 46, 7, 7, SHADE)
        d.roundrect(33, 102, 159, 132, 5, SHADE)
        d.roundrect(38, 72, 154, 164, 24, SHADE)
        d.roundrect(42, 76, 150, 160, 21, "#536379")
        d.line(76, 148, 116, 148, SHADE, 3)
        return d.finish()
    ax = cx + (14 if state == "confused" else 4 * wave)
    if state == "confused":
        d.path([(cx, cy - 44), (cx + 12, cy - 56), (cx - 3, cy - 64), (ax, cy - 76)], OUTLINE, 5)
        color = AMBER
    else:
        d.line(cx, cy - 44, ax, cy - 70, OUTLINE, 5)
    d.ellipse(ax, cy - 74, 8, 8, OUTLINE)
    d.ellipse(ax, cy - 74, 6, 6, color)
    if state == "startled":
        for sign in (-1, 1):
            d.path([(ax + sign * 14, cy - 65), (ax + sign * 22, cy - 73),
                    (ax + sign * 18, cy - 78), (ax + sign * 27, cy - 85)], AMBER, 4)
    for sign in (-1, 1):
        ex = cx + sign * (half + 2)
        d.roundrect(ex - 8, cy - 14, ex + 8, cy + 14, 5, OUTLINE)
        d.rect(ex - 4, cy - 10, ex + 4, cy + 10, SHADE)
    d.roundrect(cx - half, cy - 46, cx + half, cy + 46, 24, OUTLINE)
    d.roundrect(cx - half + 4, cy - 42, cx + half - 4, cy + 42, 21, SHELL)
    d.roundrect(cx - half + 7, cy + 24, cx + half - 7, cy + 40, 8, SHADE)
    visor_half = half - 14
    d.roundrect(cx - visor_half, cy - 26, cx + visor_half, cy + 14, 12, VISOR)
    for sign in (-1, 1):
        ex, ey = cx + sign * (20 if half == 56 else 13), cy - 6
        if state == "startled":
            d.ellipse(ex, ey, 14, 17, "#ffffff")
            d.ellipse(ex, ey + 1, 4, 6, VISOR)
        elif state == "sleepy":
            d.path([(ex - 9, ey), (ex, ey + 4), (ex + 9, ey)], BLUE, 4)
        elif state in ("proud", "celebrating"):
            d.path([(ex - 9, ey + 2), (ex, ey - 6), (ex + 9, ey + 2)], GREEN, 5)
        elif state == "thinking":
            d.roundrect(ex - 7 + 5 * wave, ey - 11, ex + 7 + 5 * wave, ey - 2, 3, BLUE)
            d.line(ex - 11, ey - 17, ex + 9, ey - 20, BLUE, 3)
        elif state == "confused":
            if sign == -1:
                d.ellipse(ex, ey, 11, 11, AMBER)
                d.ellipse(ex, ey, 5, 5, VISOR)
            else:
                d.line(ex - 10, ey - 3, ex + 9, ey + 5, AMBER, 5)
            d.line(ex - 11, ey - 20, ex + 9, ey - 13, AMBER, 3)
        elif state == "needs-permission":
            d.roundrect(ex - 8, ey - 8, ex + 8, ey + 7, 5, AMBER)
        elif state == "compacting":
            d.path([(ex - sign * 6, ey - 8), (ex + sign * 2, ey), (ex - sign * 6, ey + 8)], BLUE, 4)
        else:
            look = 6 if index < count / 2 else -6
            d.roundrect(ex - 8 + look, ey - 10, ex + 8 + look, ey + 10, 5, BLUE)
    my = cy + 30
    if state == "startled":
        d.ellipse(cx, my, 9, 11, OUTLINE)
        d.ellipse(cx, my, 4, 6, VISOR)
        d.path([(157, cy - 41), (153, cy - 28), (161, cy - 28), (157, cy - 41)], BLUE, 4)
        d.ellipse(157, cy - 27, 5, 7, BLUE)
    elif state == "confused":
        d.path([(80, my + 2), (88, my - 2), (96, my + 3), (105, my - 2)], OUTLINE, 3)
    elif state == "sleepy":
        d.ellipse(cx, my, 7, 5 + wave, OUTLINE)
    elif state in ("proud", "celebrating"):
        d.path([(81, my - 4), (90, my + 3), (102, my + 3), (112, my - 4)], OUTLINE, 4)
    else:
        d.line(86, my, 106, my, OUTLINE, 3)
    if state == "thinking":
        d.hand(117, cy + 33)
        d.line(110, cy + 29, 108, cy + 17, SHELL, 5)
    elif state == "delegating":
        for sign in (-1, 1):
            x, y = 96 + sign * 71, 110 + sign * 15 * wave
            d.line(96 + sign * 58, 129, x, y, SHADE, 6)
            d.hand(x, y)
            d.line(x, y - 8, x + sign * 10, y - 37, OUTLINE, 6)
            d.line(x, y - 8, x + sign * 10, y - 37, SHELL, 3)
    elif state == "needs-permission":
        d.line(145, 139, 165, 119, SHADE, 6)
        d.hand(165, 105 + wave * 2, raised=True)
        d.line(161, 105, 169, 105, OUTLINE, 2)
    elif state == "compacting":
        for sign in (-1, 1):
            d.hand(cx + sign * (half + 9), cy + 4)
        for y in (cy - 17, cy - 9, cy - 1):
            d.line(91, y, 101, y, BLUE, 2)
    elif state == "sleepy":
        for x, y, size in ((142, 66, 10), (161, 42, 14)):
            y += wave * 3
            d.path([(x, y), (x + size, y), (x, y + size), (x + size, y + size)], BLUE, 3)
    elif state == "proud":
        d.hand(30, 141 - wave * 2)
        d.hand(162, 141 + wave * 2)
        d.line(58, cy + 4, 66, cy + 4, GREEN, 3)
        d.line(126, cy + 4, 134, cy + 4, GREEN, 3)
    elif state == "celebrating":
        for sign in (-1, 1):
            d.line(96 + sign * 57, cy + 10, 96 + sign * 70, cy - 23, SHADE, 6)
            d.hand(96 + sign * 71, cy - 30, raised=True)
        for k, (x, y) in enumerate(((25, 39), (53, 24), (137, 28), (171, 37))):
            y += (index * 5 + k * 3) % 14
            d.line(x - 3, y - 4, x + 3, y + 4, GREEN if k % 2 else AMBER, 4)
    return d.finish()
