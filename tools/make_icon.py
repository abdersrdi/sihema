#!/usr/bin/env python3
"""Draws the Sihema app icon (a toolpath: straight cuts joined by a rounded corner, with a tool dot) and writes the
asset catalog App/Shared/Assets.xcassets/AppIcon.appiconset for iOS and macOS.

    python tools/make_icon.py
"""
import json
import math
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "App", "Shared", "Assets.xcassets")
ICONSET = os.path.join(OUT, "AppIcon.appiconset")
SIZE = 1024
SS = 3
S = SIZE * SS

DARK_TOP = (58, 18, 30)
DARK_BOTTOM = (18, 6, 11)
CUT = (245, 209, 219)       # pale burgundy tint
RAPID = (115, 184, 237)     # glacier blue


def gradient():
    small = Image.new("RGB", (8, 256))
    px = small.load()
    for y in range(256):
        t = y / 255
        c = tuple(int(DARK_TOP[i] + (DARK_BOTTOM[i] - DARK_TOP[i]) * t) for i in range(3))
        for x in range(8):
            px[x, y] = c
    return small.resize((S, S), Image.BICUBIC)


def arc_points(cx, cy, r, a0, a1, n=60):
    return [(cx + r * math.cos(a0 + (a1 - a0) * i / n), cy + r * math.sin(a0 + (a1 - a0) * i / n)) for i in range(n + 1)]


def stroke(d, pts, width, color):
    d.line(pts, fill=color, width=width, joint="curve")
    r = width // 2
    for x, y in pts:
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def draw():
    img = gradient()
    d = ImageDraw.Draw(img)
    u = S / 100  # 100 units across

    # faint grid, like a drawing sheet
    grid = (255, 255, 255)
    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for i in range(10, 100, 10):
        od.line([(i * u, 0), (i * u, S)], fill=grid + (14,), width=max(2, int(0.25 * u)))
        od.line([(0, i * u), (S, i * u)], fill=grid + (14,), width=max(2, int(0.25 * u)))
    img = Image.alpha_composite(img.convert("RGBA"), overlay)
    d = ImageDraw.Draw(img)

    w = int(3.6 * u)
    # rapid approach (blue, dashed): from the lower left up to the start of the cut
    start = (20 * u, 78 * u)
    cut_start = (20 * u, 62 * u)
    steps = 8
    for i in range(steps):
        if i % 2 == 0:
            a = (start[0], start[1] + (cut_start[1] - start[1]) * i / steps)
            b = (start[0], start[1] + (cut_start[1] - start[1]) * (i + 1) / steps)
            d.line([a, b], fill=RAPID + (255,), width=int(2.4 * u))

    # the cut: up, across with a rounded corner, down, then a curve back (a pocket-like outline)
    pts = [(20 * u, 62 * u), (20 * u, 36 * u)]
    pts += arc_points(36 * u, 36 * u, 16 * u, math.pi, 1.5 * math.pi)
    pts += [(64 * u, 20 * u)]
    pts += arc_points(64 * u, 36 * u, 16 * u, 1.5 * math.pi, 2 * math.pi)
    pts += [(80 * u, 64 * u)]
    pts += arc_points(66 * u, 64 * u, 14 * u, 0, 0.5 * math.pi)
    pts += [(36 * u, 78 * u)]
    stroke(d, pts, w, CUT + (255,))

    # the tool: a blue dot at the cut start with a soft ring
    cx, cy = 20 * u, 62 * u
    r = 5.2 * u
    d.ellipse([cx - r * 1.9, cy - r * 1.9, cx + r * 1.9, cy + r * 1.9], outline=RAPID + (120,), width=int(1.2 * u))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=RAPID + (255,))
    return img.convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)


def main():
    os.makedirs(ICONSET, exist_ok=True)
    master = draw()
    os.makedirs(os.path.join(ROOT, "assets"), exist_ok=True)
    master.save(os.path.join(ROOT, "assets", "icon.png"))

    images = []
    master.save(os.path.join(ICONSET, "icon-1024.png"))
    images.append({"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"})

    # macOS wants the artwork inset on a rounded square with some margin; sizes in points at 1x and 2x
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"mac-{pt}@{scale}x.png"
            canvas = Image.new("RGBA", (px, px), (0, 0, 0, 0))
            inner = int(px * 0.82)
            art = master.resize((inner, inner), Image.LANCZOS).convert("RGBA")
            mask = Image.new("L", (inner, inner), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, inner - 1, inner - 1], radius=int(inner * 0.225), fill=255)
            canvas.paste(art, ((px - inner) // 2, (px - inner) // 2), mask)
            canvas.save(os.path.join(ICONSET, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})

    with open(os.path.join(ICONSET, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    print("wrote", ICONSET)


if __name__ == "__main__":
    main()
