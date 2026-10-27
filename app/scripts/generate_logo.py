#!/usr/bin/env python3
"""Generate the Mumu Notes launcher icon and in-app logo.

The mark is a cream notebook page with two sage leaves growing from its top
edge: a note page for writing, a sprout for "木木". Everything is drawn at 2x
and downsampled for clean edges.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ANDROID_RES = ROOT / "android" / "app" / "src" / "main" / "res"
IMAGES = ROOT / "images"
S = 2048  # supersampled working canvas
K = S / 1024.0


def sc(value: float) -> float:
    return value * K


def pt(x: float, y: float) -> tuple[float, float]:
    return x * K, y * K


def cubic(p0, p1, p2, p3, steps: int = 48):
    points = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        points.append(
            (
                u * u * u * p0[0]
                + 3 * u * u * t * p1[0]
                + 3 * u * t * t * p2[0]
                + t * t * t * p3[0],
                u * u * u * p0[1]
                + 3 * u * u * t * p1[1]
                + 3 * u * t * t * p2[1]
                + t * t * t * p3[1],
            )
        )
    return points


def leaf_polygon(base, tip, width):
    bx, by = base
    tx, ty = tip
    dx, dy = tx - bx, ty - by
    length = math.hypot(dx, dy)
    nx, ny = -dy / length, dx / length
    c1 = (bx + dx * 0.26 + nx * width, by + dy * 0.26 + ny * width)
    c2 = (bx + dx * 0.74 + nx * width * 0.65, by + dy * 0.74 + ny * width * 0.65)
    side_a = cubic(base, c1, c2, tip, 40)
    c3 = (bx + dx * 0.74 - nx * width * 0.65, by + dy * 0.74 - ny * width * 0.65)
    c4 = (bx + dx * 0.26 - nx * width, by + dy * 0.26 - ny * width)
    side_b = cubic(tip, c3, c4, base, 40)
    return side_a + side_b


def gradient_background(size: int) -> Image.Image:
    bg = Image.new("RGBA", (size, size))
    top = (59, 142, 124)
    bottom = (35, 91, 80)
    px = bg.load()
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = (*color, 255)
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        (int(-size * 0.35), int(-size * 0.45), int(size * 0.85), int(size * 0.65)),
        fill=(255, 255, 255, 34),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
    return Image.alpha_composite(bg, glow)


def rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    return mask


def circle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, size - 1, size - 1), fill=255)
    return mask


def draw_page_layer() -> Image.Image:
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    left, top, right, bottom = sc(262), sc(318), sc(752), sc(884)
    radius = sc(44)
    d.rounded_rectangle(
        (left, top, right, bottom),
        radius=radius,
        fill=(252, 246, 232, 255),
    )
    fold = [pt(604, 318), pt(752, 318), pt(752, 468)]
    d.polygon(fold, fill=(235, 222, 197, 255))
    d.line(fold + [pt(604, 318)], fill=(213, 195, 163, 255), width=int(sc(4)))
    for y in (614, 692, 770):
        d.rounded_rectangle(
            (sc(326), sc(y), sc(686), sc(y + 13)),
            radius=sc(6.5),
            fill=(184, 211, 199, 255),
        )
        d.ellipse(
            (sc(300), sc(y - 2), sc(318), sc(y + 16)),
            fill=(111, 166, 148, 255),
        )
    return layer.rotate(-7, resample=Image.BICUBIC, center=pt(507, 601))


def draw_sprout_layer() -> Image.Image:
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    stem = cubic(pt(506, 566), pt(470, 410), pt(618, 332), pt(600, 218), 56)
    d.line(stem, fill=(46, 107, 91, 255), width=int(sc(21)), joint="curve")
    for p in (stem[0], stem[-1]):
        r = sc(10.5)
        d.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=(46, 107, 91, 255))
    d.polygon(leaf_polygon(pt(556, 354), pt(416, 206), sc(66)), fill=(86, 152, 130, 255))
    d.line(
        cubic(pt(552, 350), pt(506, 306), pt(466, 252), pt(424, 212), 24),
        fill=(50, 113, 95, 255),
        width=int(sc(5)),
    )
    d.polygon(leaf_polygon(pt(586, 330), pt(730, 166), sc(74)), fill=(136, 190, 166, 255))
    d.line(
        cubic(pt(588, 326), pt(638, 270), pt(686, 214), pt(724, 172), 24),
        fill=(57, 123, 104, 255),
        width=int(sc(5)),
    )
    r = sc(23)
    cx, cy = pt(590, 300)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=(218, 164, 92, 255))
    hr = sc(7)
    d.ellipse(
        (cx - hr - 4 * K, cy - hr - 4 * K, cx + hr - 4 * K, cy + hr - 4 * K),
        fill=(247, 222, 181, 255),
    )
    return layer


def build_mark(scale: float = 1.0) -> Image.Image:
    page = draw_page_layer()
    sprout = draw_sprout_layer()
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        (sc(270), sc(346), sc(760), sc(912)),
        radius=sc(50),
        fill=(13, 46, 40, 96),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(sc(26)))
    mark = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    mark = Image.alpha_composite(mark, shadow)
    mark = Image.alpha_composite(mark, sprout)
    mark = Image.alpha_composite(mark, page)
    mark = Image.alpha_composite(mark, sprout)
    if scale != 1.0:
        size = round(S * scale)
        scaled = mark.resize((size, size), Image.LANCZOS)
        canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        offset = ((S - size) // 2, (S - size) // 2)
        canvas.alpha_composite(scaled, offset)
        mark = canvas
    return mark.resize((1024, 1024), Image.LANCZOS)


def build_full_icon(mark_scale: float = 0.90) -> Image.Image:
    bg = gradient_background(S)
    mark = build_mark(mark_scale).resize((S, S), Image.LANCZOS)
    icon = Image.alpha_composite(bg, mark)
    rim = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle(
        (sc(18), sc(18), sc(1006), sc(1006)),
        radius=sc(218),
        outline=(255, 255, 255, 42),
        width=int(sc(5)),
    )
    icon = Image.alpha_composite(icon, rim)
    icon.putalpha(rounded_mask(S, sc(224)))
    return icon.resize((1024, 1024), Image.LANCZOS)


def main() -> None:
    tmp = ROOT / "scripts" / "_tmp"
    tmp.mkdir(parents=True, exist_ok=True)

    full = build_full_icon()
    mark = build_mark()
    preview = Image.new("RGBA", (1200, 1200), (247, 247, 242, 255))
    preview.alpha_composite(full.resize((560, 560), Image.LANCZOS), (40, 40))
    preview.alpha_composite(mark.resize((520, 520), Image.LANCZOS), (640, 60))
    preview.save(tmp / "logo_preview.png")

    legacy_sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, size in legacy_sizes.items():
        folder = ANDROID_RES / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        resized = full.resize((size, size), Image.LANCZOS)
        resized.save(folder / "mumu_launcher.webp", "WEBP", lossless=True)
        round_icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        round_icon.paste(resized, (0, 0), circle_mask(size))
        round_icon.save(folder / "mumu_launcher_round.webp", "WEBP", lossless=True)

        fg_size = round(size * 108 / 48)
        fg = Image.new("RGBA", (fg_size, fg_size), (0, 0, 0, 0))
        fg_mark = build_mark().resize(
            (round(fg_size * 0.72), round(fg_size * 0.72)), Image.LANCZOS
        )
        fg.alpha_composite(
            fg_mark, ((fg_size - fg_mark.width) // 2, (fg_size - fg_mark.height) // 2)
        )
        fg.save(folder / "mumu_launcher_foreground.webp", "WEBP", lossless=True)

    full.resize((512, 512), Image.LANCZOS).save(
        ROOT / "android" / "app" / "src" / "main" / "ic_launcher-playstore.png"
    )
    mark.resize((512, 512), Image.LANCZOS).save(IMAGES / "logo.png")
    mark.resize((512, 512), Image.LANCZOS).save(IMAGES / "nightly.png")
    print("logo assets generated")


if __name__ == "__main__":
    main()