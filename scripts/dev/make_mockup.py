#!/usr/bin/env python3
"""Draws docs/images/home-mockup.png: a 1920x1080 mock-up of the finished home screen.

  .venv/bin/python scripts/dev/make_mockup.py [--out PATH]

Everything is drawn in code (a calm gradient sky with soft hills, a clock, a greeting and four app tiles
with generic labels). No photos, no real names, no brand logos. Uses only Pillow's built-in font, so it
runs on any OS. Needs Pillow (requirements.txt).
"""
import argparse
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    sys.stderr.write("Pillow is required: pip install -r requirements.txt\n")
    sys.exit(3)

W, H = 1920, 1080
DEFAULT_OUT = Path(__file__).resolve().parent.parent.parent / "docs" / "images" / "home-mockup.png"


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def sky():
    top, mid, low = (38, 52, 104), (176, 98, 120), (244, 170, 130)
    img = Image.new("RGB", (W, H))
    px = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H * 0.75)
        px.line([(0, y), (W, y)], fill=lerp(top, mid, t / 0.6) if t < 0.6 else lerp(mid, low, min((t - 0.6) / 0.4, 1)))
    return img


def hills(img):
    import math
    layers = [(640, 90, 0.0030, 0.0, (92, 80, 120)), (760, 70, 0.0045, 1.7, (62, 60, 100)),
              (880, 55, 0.0060, 3.1, (36, 40, 78))]
    for base, amp, freq, phase, colour in layers:
        pts = [(x, base + amp * math.sin(x * freq + phase) + amp * 0.4 * math.sin(x * freq * 2.3 + phase)) for x in range(0, W + 8, 8)]
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon(pts + [(W, H), (0, H)], fill=colour + (255,))
        img.paste(layer.filter(ImageFilter.GaussianBlur(2)), (0, 0), layer.filter(ImageFilter.GaussianBlur(2)))


def text_center(draw, cx, cy, s, font, fill):
    draw.text((cx, cy), s, font=font, fill=fill, anchor="mm")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    out = Path(ap.parse_args().out)

    img = sky()
    # soft sun glow (blurred greyscale mask, so no dark halo), then the hills in front of it
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).ellipse([1330, 440, 1610, 720], fill=170)
    img = Image.composite(Image.new("RGB", (W, H), (255, 222, 170)), img, mask.filter(ImageFilter.GaussianBlur(55)))
    hills(img)
    img = img.convert("RGBA")

    d = ImageDraw.Draw(img, "RGBA")
    white = (255, 255, 255, 255)
    d.text((960, 190), "10:42", font=ImageFont.load_default(size=190), fill=white, anchor="mm")
    d.text((960, 330), "Good evening, Sam", font=ImageFont.load_default(size=56), fill=(255, 255, 255, 230), anchor="mm")

    # dark scrim under the tiles for contrast, then four rounded tiles
    tile_w, tile_h, gap = 300, 200, 60
    total = 4 * tile_w + 3 * gap
    x0, y0 = (W - total) // 2, 800
    labels = [("Streaming", (214, 92, 96)), ("Movies", (92, 140, 214)), ("Music", (110, 190, 140)), ("Videos", (226, 170, 80))]
    label_font = ImageFont.load_default(size=40)
    for i, (label, colour) in enumerate(labels):
        x = x0 + i * (tile_w + gap)
        d.rounded_rectangle([x, y0, x + tile_w, y0 + tile_h], radius=36, fill=(20, 24, 48, 170), outline=(255, 255, 255, 90), width=2)
        d.ellipse([x + tile_w // 2 - 40, y0 + 34, x + tile_w // 2 + 40, y0 + 114], fill=colour + (255,))
        text_center(d, x + tile_w // 2, y0 + 156, label, label_font, white)

    out.parent.mkdir(parents=True, exist_ok=True)
    img.convert("RGB").save(out, "PNG", optimize=True)
    print(f"wrote {out} ({out.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
