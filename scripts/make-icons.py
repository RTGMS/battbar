#!/usr/bin/env python3
"""Generate the app, tray and notification icons for MouseBattery."""

from __future__ import annotations

import math
import os
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
ASSETS = ROOT / "assets"
ICONSET = BUILD / "icon.iconset"

MINT = (155, 232, 184)
MINT_BRIGHT = (206, 255, 224)
CREAM_TOP = (247, 249, 238)
CREAM_BOTTOM = (201, 215, 201)
INK = (7, 16, 12)


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
    return layer.filter(ImageFilter.GaussianBlur(radius * 0.42))


def cubic_bezier(points: list[tuple[float, float]], steps: int = 80) -> list[tuple[float, float]]:
    """Sample a cubic bezier when given four control points."""
    p0, p1, p2, p3 = points
    samples = []
    for index in range(steps + 1):
        t = index / steps
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        samples.append((x, y))
    return samples


def mouse_outline(scale: float, offset_x: float = 0, offset_y: float = 0) -> list[tuple[float, float]]:
    """A rounded, slightly tapered top-down mouse silhouette."""

    def point(x: float, y: float) -> tuple[float, float]:
        return (offset_x + x * scale, offset_y + y * scale)

    segments = [
        cubic_bezier([(512, 248), (676, 248), (746, 382), (748, 536)]),
        cubic_bezier([(748, 536), (750, 708), (664, 812), (512, 814)]),
        cubic_bezier([(512, 814), (360, 812), (274, 708), (276, 536)]),
        cubic_bezier([(276, 536), (278, 382), (348, 248), (512, 248)]),
    ]
    outline: list[tuple[float, float]] = []
    for segment in segments:
        outline.extend(point(x, y) for x, y in segment)
    return outline


def draw_arc(draw: ImageDraw.ImageDraw, box: tuple[float, float, float, float], start: float, end: float, fill, width: int) -> None:
    """Draw a round-capped clockwise arc; angles are in degrees."""
    cx = (box[0] + box[2]) / 2
    cy = (box[1] + box[3]) / 2
    radius = (box[2] - box[0]) / 2
    total = end - start
    steps = max(10, int(abs(total) / 2))
    points = []
    for index in range(steps + 1):
        angle = math.radians(start + total * index / steps)
        points.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius))
    draw.line(points, fill=fill, width=width, joint="curve")
    cap = width / 2
    for x, y in (points[0], points[-1]):
        draw.ellipse((x - cap, y - cap, x + cap, y + cap), fill=fill)


def make_app_icon() -> Image.Image:
    size = 1024
    scale = 2
    canvas_size = size * scale
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    margin = 54 * scale
    radius = 214 * scale
    shape = Image.new("L", (canvas_size, canvas_size), 0)
    shape_draw = ImageDraw.Draw(shape)
    shape_draw.rounded_rectangle(
        (margin, margin, canvas_size - margin, canvas_size - margin),
        radius=radius,
        fill=255,
    )

    background = vertical_gradient(canvas_size, (23, 52, 38), (5, 13, 9))
    background = Image.alpha_composite(
        background,
        radial_glow(canvas_size, (88, 183, 126, 120), (230 * scale, 100 * scale), 350 * scale),
    )
    background = Image.alpha_composite(
        background,
        radial_glow(canvas_size, (26, 77, 51, 95), (850 * scale, 930 * scale), 390 * scale),
    )

    # Grain-like fine texture.
    noise = Image.effect_noise((canvas_size, canvas_size), 12).convert("RGBA")
    noise.putalpha(14)
    background = Image.alpha_composite(background, noise)

    canvas.paste(background, (0, 0), shape)

    draw = ImageDraw.Draw(canvas)

    # Border highlight.
    draw.rounded_rectangle(
        (margin, margin, canvas_size - margin, canvas_size - margin),
        radius=radius,
        outline=(255, 255, 255, 34),
        width=3 * scale,
    )

    # Ambient ring behind the mouse.
    ring_box = (
        (canvas_size - 620 * scale) / 2,
        (canvas_size - 620 * scale) / 2,
        (canvas_size + 620 * scale) / 2,
        (canvas_size + 620 * scale) / 2,
    )
    draw.arc(ring_box, 0, 360, fill=(255, 255, 255, 15), width=24 * scale)
    draw_arc(draw, ring_box, 122, 398, MINT + (220,), 24 * scale)
    # A tiny marker at the open end of the gauge.
    marker_angle = math.radians(122)
    marker_x = (ring_box[0] + ring_box[2]) / 2 + math.cos(marker_angle) * 310 * scale
    marker_y = (ring_box[1] + ring_box[3]) / 2 + math.sin(marker_angle) * 310 * scale
    draw.ellipse(
        (marker_x - 14 * scale, marker_y - 14 * scale, marker_x + 14 * scale, marker_y + 14 * scale),
        fill=MINT_BRIGHT + (220,),
    )

    # Soft shadow under the mouse.
    shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    outline = mouse_outline(1.02 * scale, offset_x=-5 * scale, offset_y=18 * scale)
    shadow_draw.polygon(outline, fill=(0, 0, 0, 140))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30 * scale))
    canvas.alpha_composite(shadow)

    # Mouse body, clipped from a pale vertical gradient.
    body_mask = Image.new("L", (canvas_size, canvas_size), 0)
    body_mask_draw = ImageDraw.Draw(body_mask)
    body_outline = mouse_outline(scale)
    body_mask_draw.polygon(body_outline, fill=255)
    body_gradient = vertical_gradient(canvas_size, CREAM_TOP, CREAM_BOTTOM)
    canvas.paste(body_gradient, (0, 0), body_mask)

    # Rim light.
    draw.line(body_outline + [body_outline[0]], fill=(255, 255, 255, 140), width=3 * scale, joint="curve")

    # Center seam and wheel well.
    seam = ImageDraw.Draw(canvas)
    seam.rounded_rectangle(
        (509 * scale, 270 * scale, 515 * scale, 592 * scale),
        radius=3 * scale,
        fill=(35, 57, 44, 120),
    )
    wheel_box = (479 * scale, 310 * scale, 545 * scale, 436 * scale)
    wheel_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(wheel_mask).rounded_rectangle(wheel_box, radius=33 * scale, fill=255)
    wheel_fill = Image.new("RGBA", (canvas_size, canvas_size), (28, 52, 39, 255))
    wheel_draw = ImageDraw.Draw(wheel_fill)
    wheel_draw.rounded_rectangle(wheel_box, radius=33 * scale, outline=(246, 250, 238, 255), width=5 * scale)
    canvas.paste(wheel_fill, (0, 0), wheel_mask)
    # Glowing wheel core.
    glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.rounded_rectangle(
        (494 * scale, 326 * scale, 530 * scale, 420 * scale),
        radius=18 * scale,
        fill=MINT + (255,),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(12 * scale))
    canvas.alpha_composite(glow)
    draw.rounded_rectangle(
        (492 * scale, 324 * scale, 532 * scale, 422 * scale),
        radius=20 * scale,
        fill=MINT + (255,),
    )
    draw.rounded_rectangle(
        (501 * scale, 332 * scale, 508 * scale, 396 * scale),
        radius=4 * scale,
        fill=MINT_BRIGHT + (210,),
    )

    # Small indicator near the bottom, like a charge LED.
    led_glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    ImageDraw.Draw(led_glow).ellipse(
        (495 * scale, 654 * scale, 529 * scale, 688 * scale),
        fill=MINT + (160,),
    )
    led_glow = led_glow.filter(ImageFilter.GaussianBlur(17 * scale))
    canvas.alpha_composite(led_glow)
    draw.ellipse(
        (499 * scale, 658 * scale, 525 * scale, 684 * scale),
        fill=(24, 48, 36, 255),
        outline=MINT + (200,),
        width=3 * scale,
    )
    draw.ellipse((506 * scale, 665 * scale, 518 * scale, 677 * scale), fill=MINT_BRIGHT + (230,))

    # A subtle bottom reflection, composited so the body's alpha is preserved.
    reflection = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    reflection_draw = ImageDraw.Draw(reflection)
    reflection_draw.ellipse((320 * scale, 752 * scale, 704 * scale, 856 * scale), fill=(80, 108, 88, 35))
    reflection = reflection.filter(ImageFilter.GaussianBlur(28 * scale))
    reflection_mask = Image.new("L", (canvas_size, canvas_size), 0)
    ImageDraw.Draw(reflection_mask).polygon(body_outline, fill=255)
    canvas.alpha_composite(Image.composite(reflection, Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0)), reflection_mask))

    return canvas.resize((size, size), Image.LANCZOS)


def make_tray_template() -> Image.Image:
    size = 176
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)

    outline = mouse_outline(size / 1024 * 1.05, offset_x=-3, offset_y=4)
    draw.polygon(outline, fill=255)
    # A top notch and wheel well read as a computer mouse even at 16px.
    draw.rounded_rectangle((83, 24, 93, 48), radius=4, fill=0)
    draw.rounded_rectangle((80, 50, 96, 82), radius=8, fill=0)

    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.putalpha(mask)
    return icon.resize((44, 44), Image.LANCZOS)


def make_tray_color() -> Image.Image:
    size = 128
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(icon)
    draw.rounded_rectangle((4, 4, size - 4, size - 4), radius=30, fill=(16, 37, 26, 255))
    draw.rounded_rectangle((4, 4, size - 4, size - 4), radius=30, outline=(255, 255, 255, 24), width=2)
    outline = mouse_outline(0.14, offset_x=-7.7, offset_y=-8.4)
    draw.polygon(outline, fill=(236, 246, 232, 255))
    draw.rounded_rectangle((59, 33, 69, 54), radius=5, fill=MINT + (255,))
    draw.rounded_rectangle((63, 39, 65, 50), radius=1, fill=(16, 37, 26, 255))
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
    icon.resize((256, 256), Image.LANCZOS).save(ASSETS / "notification.png")
    icon.resize((64, 64), Image.LANCZOS).save(ASSETS / "icon-64.png")
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
