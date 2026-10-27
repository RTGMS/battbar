#!/usr/bin/env python3
"""Generate the BattBar app, notification and tray icons."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
ASSETS = ROOT / "assets"
ICONSET = BUILD / "icon.iconset"

VOLT = (198, 242, 107)
VOLT_BRIGHT = (232, 255, 184)
VOLT_DIM = (122, 168, 66)
INK_TOP = (25, 43, 28)
INK_BOTTOM = (4, 9, 5)


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (size, size), top + (255,))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / max(1, size - 1)
        eased = t * t * (3 - 2 * t)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * eased) for i in range(3))
        draw.line((0, y, size, y), fill=color + (255,))
    return image


def radial_glow(size: int, color: tuple[int, int, int, int], center: tuple[float, float], radius: float) -> Image.Image:
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    cx, cy = center
    draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.45))


def draw_battery(
    draw: ImageDraw.ImageDraw,
    body: tuple[float, float, float, float],
    cap: tuple[float, float, float, float],
    radius: float,
    stroke: int,
    color: tuple[int, int, int, int],
) -> None:
    draw.rounded_rectangle(body, radius=radius, outline=color, width=stroke)
    draw.rounded_rectangle(cap, radius=min(cap[2] - cap[0], cap[3] - cap[1]) / 2, fill=color)


def make_app_icon() -> Image.Image:
    size = 1024
    scale = 2
    canvas_size = size * scale
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    margin = 54 * scale
    radius = 214 * scale
    shape = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(shape).rounded_rectangle(
        (margin, margin, canvas_size - margin, canvas_size - margin),
        radius=radius,
        fill=255,
    )

    background = vertical_gradient(canvas_size, INK_TOP, INK_BOTTOM)
    background = Image.alpha_composite(
        background,
        radial_glow(canvas_size, (128, 196, 74, 120), (280 * scale, 180 * scale), 360 * scale),
    )
    background = Image.alpha_composite(
        background,
        radial_glow(canvas_size, (35, 92, 62, 100), (735 * scale, 845 * scale), 350 * scale),
    )

    noise = Image.effect_noise((canvas_size, canvas_size), 10).convert("RGBA")
    noise.putalpha(10)
    background = Image.alpha_composite(background, noise)
    canvas.paste(background, (0, 0), shape)

    draw = ImageDraw.Draw(canvas)

    # Rounded-square rim light.
    draw.rounded_rectangle(
        (margin, margin, canvas_size - margin, canvas_size - margin),
        radius=radius,
        outline=(255, 255, 255, 38),
        width=3 * scale,
    )

    body = (235 * scale, 380 * scale, 745 * scale, 660 * scale)
    cap = (755 * scale, 485 * scale, 789 * scale, 555 * scale)

    # Soft shadow beneath the glyph.
    shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (body[0] + 2 * scale, body[1] + 14 * scale, body[2] + 2 * scale, body[3] + 17 * scale),
        radius=90 * scale,
        fill=(0, 0, 0, 110),
    )
    shadow_draw.rounded_rectangle(
        (cap[0] + 2 * scale, cap[1] + 13 * scale, cap[2] + 2 * scale, cap[3] + 15 * scale),
        radius=15 * scale,
        fill=(0, 0, 0, 90),
    )
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(17 * scale)))

    # Outer glow around the battery outline.
    glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    draw_battery(glow_draw, body, cap, 80 * scale, 32 * scale, VOLT + (150,))
    glow = glow.filter(ImageFilter.GaussianBlur(11 * scale))
    canvas.alpha_composite(glow)

    draw = ImageDraw.Draw(canvas)
    draw_battery(draw, body, cap, 80 * scale, 24 * scale, VOLT + (255,))

    # A thin highlight on the upper-left edge of the outline.
    draw.arc(
        (body[0] + 9 * scale, body[1] + 9 * scale, body[2] - 9 * scale, body[3] - 9 * scale),
        start=178,
        end=268,
        fill=VOLT_BRIGHT + (180,),
        width=3 * scale,
    )

    # Three charge bars, bottom aligned, like the in-app BattBar mark.
    bar_width = 54 * scale
    bar_gap = 30 * scale
    bars_total = bar_width * 3 + bar_gap * 2
    bar_x = body[0] + ((body[2] - body[0]) - bars_total) / 2
    bar_bottom = 607 * scale
    heights = (70, 112, 154)
    for index, height in enumerate(heights):
        x0 = bar_x + index * (bar_width + bar_gap)
        y0 = bar_bottom - height * scale
        fill = VOLT_BRIGHT if index == 2 else VOLT
        draw.rounded_rectangle(
            (x0, y0, x0 + bar_width, bar_bottom),
            radius=bar_width / 2,
            fill=fill + (255,),
        )
        # A soft highlight at the top of every bar.
        draw.rounded_rectangle(
            (x0 + 9 * scale, y0 + 6 * scale, x0 + bar_width - 9 * scale, y0 + 15 * scale),
            radius=4 * scale,
            fill=(255, 255, 255, 90),
        )

    return canvas.resize((size, size), Image.LANCZOS)


def make_notification_icon(icon: Image.Image) -> Image.Image:
    # The notification icon is the app icon without the dark tile, so it
    # remains readable on the system's light and dark notification banners.
    size = 256
    glyph = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glyph)
    body = (33, 82, 203, 174)
    cap = (208, 112, 223, 144)
    draw_battery(draw, body, cap, 22, 9, VOLT + (255,))
    bars = ((57, 40, 18), (93, 56, 18), (129, 72, 18))
    for x, height, width in bars:
        draw.rounded_rectangle((x, 158 - height, x + width, 158), radius=9, fill=VOLT_BRIGHT + (255,))
    return glyph


def make_tray_template() -> Image.Image:
    size = 176
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((16, 50, 140, 126), radius=16, outline=255, width=10)
    draw.rounded_rectangle((144, 74, 158, 102), radius=6, fill=255)
    draw.rounded_rectangle((27, 61, 112, 115), radius=7, fill=255)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.putalpha(mask)
    return icon.resize((44, 44), Image.LANCZOS)


def make_tray_color() -> Image.Image:
    size = 128
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle((4, 4, size - 4, size - 4), radius=30, fill=(12, 24, 16, 255))
    draw.rounded_rectangle((4, 4, size - 4, size - 4), radius=30, outline=(255, 255, 255, 26), width=2)
    draw_battery(draw, (26, 46, 92, 82), (96, 58, 104, 70), 9, 6, VOLT + (255,))
    draw.rounded_rectangle((34, 54, 72, 74), radius=4, fill=VOLT_BRIGHT + (255,))
    return icon.resize((32, 32), Image.LANCZOS)


def save_iconset(icon: Image.Image) -> None:
    if ICONSET.exists():
        shutil.rmtree(ICONSET)
    ICONSET.mkdir(parents=True)
    specs = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for filename, px in specs:
        icon.resize((px, px), Image.LANCZOS).save(ICONSET / filename)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(BUILD / "icon.icns")], check=True)


def main() -> None:
    BUILD.mkdir(exist_ok=True)
    ASSETS.mkdir(exist_ok=True)

    icon = make_app_icon()
    icon.save(BUILD / "icon.png")
    icon.resize((512, 512), Image.LANCZOS).save(ASSETS / "icon-512.png")
    icon.resize((64, 64), Image.LANCZOS).save(ASSETS / "icon-64.png")
    make_notification_icon(icon).save(ASSETS / "notification.png")
    icon.save(BUILD / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

    if shutil.which("iconutil"):
        save_iconset(icon)

    tray = make_tray_template()
    tray.save(ASSETS / "trayTemplate@2x.png")
    tray.resize((22, 22), Image.LANCZOS).save(ASSETS / "trayTemplate.png")

    tray_color = make_tray_color()
    tray_color.resize((32, 32), Image.LANCZOS).save(ASSETS / "tray-win.png")
    tray_color.resize((64, 64), Image.LANCZOS).save(ASSETS / "tray-win@2x.png")

    print("Icons written to build/ and assets/")


if __name__ == "__main__":
    main()
