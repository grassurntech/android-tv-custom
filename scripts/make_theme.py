#!/usr/bin/env python3
"""Turns a folder of the owner's photos into a cleanyourtv theme folder.

  python scripts/make_theme.py --photos DIR --name STR --apps p1,p2,p3,p4 --clock 12|24 --out DIR
      [--stock-home-redirect PKG] [--app-key KEYCODE:PKG ...] [--live-tv-package PKG]
      [--power-on home|live-tv] [--key-filter true|false]

Writes OUT/config.json (themes/template/config.json with greeting_name, dock_apps and clock_format
overridden, plus only the optional keys whose flags are given) and OUT/wallpapers/01.jpg, 02.jpg, ...: each photo turned upright by its EXIF orientation,
cover-cropped to 1920x1080, saved as an RGB JPEG with no metadata (no GPS, no camera data) and under 300 KB.
Photos Pillow cannot open (HEIC needs a Pillow build that reads it) are skipped with a warning.
Every run rebuilds the theme from scratch, so a re-run must pass every flag decided so far: one left out
is gone from config.json. config.json is never meant to be edited by hand.
Optional keys: --stock-home-redirect -> stock_home_redirect, --app-key (repeatable) -> app_keys (a list of
"KEYCODE:PKG" strings; KEYCODE is digits, KEYCODE_NAME or scan:digits), --live-tv-package -> live_tv_package,
--power-on home -> power_on_home: true or live-tv -> boot_to_live_tv: true (never both),
--key-filter -> key_filter (true or false).
Needs Pillow (requirements.txt). Exit: 0 done, 2 bad arguments or no usable photo, 3 template or Pillow missing.
"""
import argparse
import io
import json
import os
import re
import sys
from pathlib import Path

PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
KEY_RE = re.compile(r"^(?:[0-9]+|KEYCODE_[A-Z0-9_]+|scan:[0-9]+)$")
SIZE = (1920, 1080)
# TV_MAKE_THEME_MAX_BYTES is a test-only knob (forces the "cannot fit" path); owners never set it.
LIMIT_BYTES = 300 * 1024


def _max_bytes():
    """The limit, never above 300 KB. The test knob can only lower it; junk in it is a clean exit 2."""
    raw = os.environ.get("TV_MAKE_THEME_MAX_BYTES")
    if not raw:
        return LIMIT_BYTES
    try:
        value = int(raw)
    except ValueError:
        value = 0
    if value <= 0:
        fail(2, "TV_MAKE_THEME_MAX_BYTES must be a positive whole number (it is a test-only setting)")
    return min(LIMIT_BYTES, value)


MAX_BYTES = LIMIT_BYTES  # main() lowers it if the test knob is set
MAX_PHOTOS = 100  # the launcher considers at most 100 pictures
EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}
TEMPLATE = Path(__file__).resolve().parent.parent / "themes" / "template" / "config.json"


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def parse_args(argv):
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            fail(2, f"make_theme.py: {message}")

    p = Parser(prog="make_theme.py", description="Build a cleanyourtv theme from photos.")
    p.add_argument("--photos", required=True, help="folder with the photos")
    p.add_argument("--name", required=True, help="name shown after the greeting (1 to 40 characters)")
    p.add_argument("--apps", required=True, help="exactly 4 package names, comma separated")
    p.add_argument("--clock", required=True, choices=["12", "24"])
    p.add_argument("--out", required=True, help="theme folder to write")
    p.add_argument("--stock-home-redirect", metavar="PKG", help="stock launcher package to send back to ours")
    p.add_argument("--app-key", metavar="KEYCODE:PKG", action="append", default=[],
                   help="a remote button that opens an app (repeatable)")
    p.add_argument("--live-tv-package", metavar="PKG", help="the TV's Live TV app")
    p.add_argument("--power-on", choices=["home", "live-tv"], help="what the TV shows at power-on")
    p.add_argument("--key-filter", choices=["true", "false"], help="whether the key helpers filter keys")
    args = p.parse_args(argv)
    name = args.name.strip()
    if not name or len(name) > 40 or any(ord(c) < 32 for c in name):
        fail(2, "--name must be 1 to 40 characters, with no control characters")
    args.name = name
    apps = [a.strip() for a in args.apps.split(",")]
    if len(apps) != 4 or len(set(apps)) != 4:
        fail(2, "--apps needs exactly 4 different package names, comma separated")
    for a in apps:
        if not PKG_RE.match(a):
            fail(2, f"--apps: '{a}' does not look like a package name (for example com.example.app)")
    args.apps = apps
    for flag, value in (("--stock-home-redirect", args.stock_home_redirect),
                        ("--live-tv-package", args.live_tv_package)):
        if value is not None and not PKG_RE.match(value):
            fail(2, f"{flag}: '{value}' does not look like a package name (for example com.example.app)")
    for entry in args.app_key:
        key, sep, pkg = entry.rpartition(":")
        if not sep or not KEY_RE.match(key) or not PKG_RE.match(pkg):
            fail(2, f"--app-key: '{entry}' must be KEYCODE:PKG, where KEYCODE is digits, KEYCODE_NAME or "
                    "scan:digits and PKG a package name (for example 190:com.google.android.youtube.tv)")
    return args


def encode(img):
    """JPEG bytes under MAX_BYTES. Steps quality down, then softens a little; ValueError if none fits."""
    from PIL import ImageFilter

    work = img
    for blur in (0, 1, 2, 3, 4, 6, 8):
        if blur:
            work = img.filter(ImageFilter.GaussianBlur(blur))
        for quality in range(90, 19, -5):
            buf = io.BytesIO()
            work.save(buf, "JPEG", quality=quality, optimize=True)  # no exif/icc passed: none written
            data = buf.getvalue()
            if len(data) <= MAX_BYTES:
                return data
    raise ValueError("cannot fit 300 KB")


def main(argv):
    global MAX_BYTES
    args = parse_args(argv)
    MAX_BYTES = _max_bytes()
    try:
        from PIL import Image, ImageOps
    except ImportError:
        fail(3, "Pillow is missing. Run: python -m pip install -r requirements.txt")

    photos = Path(args.photos)
    if not photos.is_dir():
        fail(2, f"--photos: '{args.photos}' is not a folder")
    files = sorted((f for f in photos.iterdir()
                    if f.is_file() and not f.name.startswith(".") and f.suffix.lower() in EXTENSIONS),
                   key=lambda f: f.name.lower())

    outputs = []
    for f in files:
        if len(outputs) >= MAX_PHOTOS:
            print(f"Warning: only the first {MAX_PHOTOS} photos are used", file=sys.stderr)
            break
        try:
            with Image.open(f) as im:
                im = ImageOps.exif_transpose(im)
                im = im.convert("RGB")
                im = ImageOps.fit(im, SIZE, Image.LANCZOS, centering=(0.5, 0.5))
            outputs.append(encode(im))
        except Exception as exc:  # unreadable, truncated, unsupported: skip it
            print(f"Warning: skipped {f.name} ({type(exc).__name__})", file=sys.stderr)
    if not outputs:
        fail(2, "No usable photos (JPEG, PNG, WebP) found in the photos folder")

    try:
        config = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        fail(3, "Missing or unreadable themes/template/config.json")
    config["greeting_name"] = args.name
    config["dock_apps"] = args.apps
    config["clock_format"] = args.clock
    for key in ("stock_home_redirect", "app_keys", "live_tv_package", "power_on_home", "boot_to_live_tv",
                "key_filter"):
        config.pop(key, None)  # only what this run's flags say
    if args.stock_home_redirect is not None:
        config["stock_home_redirect"] = args.stock_home_redirect
    if args.app_key:
        config["app_keys"] = list(args.app_key)
    if args.live_tv_package is not None:
        config["live_tv_package"] = args.live_tv_package
    if args.power_on == "home":
        config["power_on_home"] = True
    elif args.power_on == "live-tv":
        config["boot_to_live_tv"] = True
    if args.key_filter is not None:
        config["key_filter"] = args.key_filter == "true"

    out = Path(args.out)
    wall = out / "wallpapers"
    wall.mkdir(parents=True, exist_ok=True)
    for old in wall.iterdir():  # re-runs replace the collection
        if old.is_file():
            old.unlink()
    for i, data in enumerate(outputs, 1):
        (wall / f"{i:02d}.jpg").write_bytes(data)
    (out / "config.json").write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(outputs)} wallpapers and config.json to {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
