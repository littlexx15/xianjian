# -*- coding: utf-8 -*-
"""Generate the 鲜剪 app icon: a clean citrus slice on a warm rounded square."""
from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SIZE = 1024


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(int(lerp(a, b, t) + 0.5) for a, b in zip(c1, c2))


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return m


def radial_gradient(size, inner, outer, cx, cy, r_inner, r_outer):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy)
            if d <= r_inner:
                px[x, y] = inner + (255,)
            elif d >= r_outer:
                continue
            else:
                t = (d - r_inner) / (r_outer - r_inner)
                col = mix(inner[:3], outer[:3], t)
                a = int(lerp(inner[3] if len(inner) > 3 else 255, outer[3] if len(outer) > 3 else 0, t))
                px[x, y] = col + (a,)
    return img


def draw_icon():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    radius = int(SIZE * 0.22)

    # Warm persimmon gradient background
    bg = Image.new("RGB", (SIZE, SIZE))
    pix = bg.load()
    top = (255, 138, 72)
    bot = (176, 52, 26)
    for y in range(SIZE):
        ty = y / (SIZE - 1)
        # smooth cosine so the square has no horizontal seam
        t = 0.5 - 0.5 * math.cos(ty * math.pi)
        row = mix(top, bot, t)
        for x in range(SIZE):
            tx = x / (SIZE - 1)
            lift = 22 * (1 - tx) * (1 - ty)
            pix[x, y] = (
                min(255, int(row[0] + lift)),
                min(255, int(row[1] + lift * 0.55)),
                min(255, int(row[2] + lift * 0.18)),
            )
    mask = rounded_mask(SIZE, radius)
    square = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    square.paste(bg, mask=mask)

    # Soft vignette
    vig = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(vig).ellipse(
        (int(SIZE * -0.1), int(SIZE * -0.2), int(SIZE * 1.1), int(SIZE * 0.95)), fill=40
    )
    vig = vig.filter(ImageFilter.GaussianBlur(180))
    overlay = Image.new("RGBA", (SIZE, SIZE), (90, 20, 8, 0))
    overlay.putalpha(vig)
    square = Image.alpha_composite(square, overlay)
    square.putalpha(mask)

    canvas = Image.alpha_composite(canvas, square)

    fruit = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(fruit, "RGBA")
    cx = SIZE / 2
    cy = SIZE / 2 + SIZE * 0.03
    r = SIZE * 0.30

    # Drop shadow under fruit
    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow, "RGBA")
    sd.ellipse((cx - r * 0.95, cy - r * 0.7, cx + r * 0.95, cy + r * 1.15), fill=(80, 18, 8, 90))
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    canvas = Image.alpha_composite(canvas, shadow)

    # Peel
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(232, 96, 28, 255))
    # Peel rim highlight
    d.ellipse(
        (cx - r * 0.97, cy - r * 0.97, cx + r * 0.97, cy + r * 0.97),
        outline=(255, 176, 92, 90),
        width=8,
    )
    # White pith
    pith_r = r * 0.86
    d.ellipse((cx - pith_r, cy - pith_r, cx + pith_r, cy + pith_r), fill=(255, 236, 214, 255))
    # Pulp disk
    pulp_r = r * 0.80
    d.ellipse((cx - pulp_r, cy - pulp_r, cx + pulp_r, cy + pulp_r), fill=(255, 122, 48, 255))

    # Radial segments
    segs = 10
    for i in range(segs):
        a0 = math.radians(-90 + i * (360 / segs) + 1.2)
        a1 = math.radians(-90 + (i + 1) * (360 / segs) - 1.2)
        col = (255, 154, 64, 255) if i % 2 == 0 else (244, 92, 36, 255)
        pts = [(cx, cy)]
        steps = 10
        for s in range(steps + 1):
            a = a0 + (a1 - a0) * s / steps
            pts.append((cx + math.cos(a) * pulp_r * 0.98, cy + math.sin(a) * pulp_r * 0.98))
        d.polygon(pts, fill=col)
        # membrane
        d.line(
            (
                cx + math.cos(a0) * 18,
                cy + math.sin(a0) * 18,
                cx + math.cos(a0) * pith_r * 0.98,
                cy + math.sin(a0) * pith_r * 0.98,
            ),
            fill=(255, 232, 204, 210),
            width=5,
        )

    # Core
    d.ellipse((cx - 28, cy - 28, cx + 28, cy + 28), fill=(255, 228, 196, 255))
    d.ellipse((cx - 12, cy - 12, cx + 12, cy + 12), fill=(255, 176, 110, 255))

    # Gloss highlight
    gloss = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss, "RGBA")
    gd.ellipse(
        (cx - r * 0.62, cy - r * 0.78, cx + r * 0.08, cy - r * 0.08),
        fill=(255, 255, 255, 55),
    )
    gloss = gloss.filter(ImageFilter.GaussianBlur(18))
    fruit = Image.alpha_composite(fruit, gloss)

    # Leaf — pointed oval rotated onto the peel
    leaf = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ld = ImageDraw.Draw(leaf, "RGBA")
    stem_x, stem_y = cx - 6, cy - r + 10
    leaf_pts = []
    length, width, rot = 118.0, 52.0, math.radians(-128)
    for i in range(0, 181, 4):
        a = math.radians(i)
        px = (1 - math.cos(a)) * length / 2
        py = math.sin(a) * width / 2
        leaf_pts.append(
            (
                stem_x + px * math.cos(rot) - py * math.sin(rot),
                stem_y + px * math.sin(rot) + py * math.cos(rot),
            )
        )
    ld.polygon(leaf_pts, fill=(74, 160, 78, 255))
    mid = leaf_pts[len(leaf_pts) // 2]
    ld.line((stem_x, stem_y, mid[0], mid[1]), fill=(46, 112, 54, 200), width=4)
    ld.line((stem_x, stem_y + 4, cx + 8, cy - r + 16), fill=(72, 122, 46, 255), width=8)
    fruit = Image.alpha_composite(fruit, leaf)

    canvas = Image.alpha_composite(canvas, fruit)

    # Tiny cut mark: a clean white notch at 4 o'clock, suggesting 剪
    cut = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cut, "RGBA")
    ang = math.radians(38)
    x1 = cx + math.cos(ang) * (r - 8)
    y1 = cy + math.sin(ang) * (r - 8)
    x2 = cx + math.cos(ang) * (r + 18)
    y2 = cy + math.sin(ang) * (r + 18)
    # scissors-like two-blade tick, very small and elegant
    bx = cx + math.cos(ang) * (r + 70)
    by = cy + math.sin(ang) * (r + 70)
    # skip extra ornament — keep fruit-only
    canvas = Image.alpha_composite(canvas, cut)

    # Re-apply rounded mask so nothing spills
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(canvas, mask=mask)
    return out


def to_ico(img: Image.Image, path: Path):
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    img.save(path, format="ICO", sizes=sizes)


def main():
    icon = draw_icon()
    png = ROOT / "水果混剪器-logo.png"
    ico = ROOT / "水果混剪器.ico"
    png2 = ROOT / "鲜剪-logo.png"
    ico2 = ROOT / "鲜剪.ico"
    icon.save(png, "PNG")
    icon.save(png2, "PNG")
    to_ico(icon, ico)
    to_ico(icon, ico2)
    print("wrote", png, ico)


if __name__ == "__main__":
    main()
