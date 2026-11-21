#!/usr/bin/env python3
"""Turns a folder of the owner's photos into a cleanyourtv theme folder.

  python scripts/make_theme.py --name STR --apps p1,p2[,...] --out DIR [--photos DIR] [--clock 12|24|system]
      [--stock-home-redirect PKG] [--app-key KEYCODE:PKG ...] [--live-tv-package PKG]
      [--power-on home|live-tv] [--key-filter true|false] [--consume-volume-keys]
  python scripts/make_theme.py --check-theme DIR      (used by push-theme: validate a theme folder only)

--apps takes 1 to 8 different apps for the dock, in order; columns becomes max(4, number of apps). --clock defaults
to system (follow the TV; the owner can change it on the TV in Launcher settings > Clock). Without --photos the
theme has no pictures: wallpaper is false and wallpapers/ is emptied of our NN.jpg files.

Writes OUT/config.json (themes/template/config.json with greeting_name, dock_apps, columns and clock_format
overridden, plus only the optional keys whose flags are given) and OUT/wallpapers/01.jpg, 02.jpg, ...: each photo
turned upright by its EXIF orientation, flattened onto black if it has transparency, cover-cropped to 1920x1080,
saved as a fresh RGB JPEG with no metadata at all (no EXIF/GPS, no comment, no ICC, no XMP) and under 300 KB.
Photos Pillow cannot open (HEIC needs a Pillow build that reads it) and other files are skipped with a warning.
Every run rebuilds the theme from scratch, so a re-run must pass every flag decided so far: one left out
is gone from config.json. config.json is never meant to be edited by hand.
Optional keys: --stock-home-redirect -> stock_home_redirect, --app-key (repeatable) -> app_keys (a list of
"KEYCODE:PKG" strings; KEYCODE is digits, KEYCODE_NAME or scan:digits), --live-tv-package -> live_tv_package,
--power-on home -> power_on_home: true or live-tv -> boot_to_live_tv: true (never both; live-tv needs
--live-tv-package), --key-filter -> key_filter (true or false), --consume-volume-keys -> consume_volume_keys: true
(the helpers repeat a held volume key themselves; needs --key-filter true).

Safety:
- No package anywhere (--apps, --app-key, --live-tv-package, --stock-home-redirect) may match
  config/forbidden-packages.txt. --stock-home-redirect may not be protected (config/protected-packages.txt) nor our
  own launcher. --app-key may not take Back, Home, Power, D-pad centre, Enter or Menu, and one key opens one app.
- OUT may not overlap PHOTOS (either inside the other), may not be a symlink, nor hold a wallpapers symlink.
  An existing non-empty OUT must be a theme this tool made (it leaves a .made-by-make_theme marker); only its own
  NN.jpg files are ever deleted. OUT inside the project must be git-ignored (use user-content/theme).
Needs Pillow (requirements.txt). Exit: 0 done, 2 bad arguments, unsafe package or folder, or no usable photo,
3 template, Pillow or a package list missing/unreadable, or OUT can't be written.
"""
import argparse
import fnmatch
import io
import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

PKG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$")
KEY_RE = re.compile(r"^(?:[0-9]+|KEYCODE_[A-Z0-9_]+|scan:[0-9]+)$")
OURS = "com.gathin.tvhome"
SIZE = (1920, 1080)
# TV_MAKE_THEME_MAX_BYTES is a test-only knob (forces the "cannot fit" path); owners never set it.
LIMIT_BYTES = 300 * 1024
MARKER = ".made-by-make_theme"
OWN_JPG = re.compile(r"^[0-9]{2,3}\.jpg$")
# Keys a remote needs for itself: never mapped to an app. Android keycodes and the matching Linux scan codes.
RESERVED_KEYS = {"KEYCODE_BACK": 4, "KEYCODE_HOME": 3, "KEYCODE_POWER": 26, "KEYCODE_DPAD_CENTER": 23,
                 "KEYCODE_ENTER": 66, "KEYCODE_NUMPAD_ENTER": 160, "KEYCODE_MENU": 82}
RESERVED_SCAN = {28, 96, 102, 116, 139, 158, 172, 352, 353}  # ENTER KPENTER HOME POWER MENU BACK HOMEPAGE OK SELECT
BIDI = {chr(c) for c in (0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                         0x2066, 0x2067, 0x2068, 0x2069)}  # direction controls


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
MAX_APPS = 8  # the launcher's columns key goes up to 8, and the dock is one row
EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}
REPO = Path(__file__).resolve().parent.parent
TEMPLATE = REPO / "themes" / "template" / "config.json"
FORBIDDEN_LIST = REPO / "config" / "forbidden-packages.txt"
PROTECTED_LIST = REPO / "config" / "protected-packages.txt"


def fail(code, message):
    print(message, file=sys.stderr)
    sys.exit(code)


def read_list(path):
    """Glob patterns from a package list: BOM, CR, inline '# comment' and whitespace stripped, lower-cased.
    Fails closed (exit 3) if the list is missing, unreadable or holds no pattern."""
    try:
        text = path.read_bytes().decode("utf-8-sig")
    except (OSError, UnicodeDecodeError):
        fail(3, f"Can't read the package list {path.name}. Nothing was changed.")
    patterns = []
    for line in text.split("\n"):
        line = line.replace("\r", "").split("#", 1)[0].strip().lower()
        if line:
            patterns.append(line)
    if not patterns:
        fail(3, f"The package list {path.name} has no patterns. Nothing was changed.")
    return patterns


def matches(pkg, patterns):
    pkg = pkg.lower()
    return any(fnmatch.fnmatchcase(pkg, p) for p in patterns)


def key_part(entry):
    return entry.rpartition(":")[0]


def norm_key(key):
    """A comparable form of a KEYCODE: ('k', n) for Android keycodes, ('scan', n) or ('name', NAME)."""
    if key.startswith("scan:"):
        return ("scan", int(key[5:]))
    if key.isdigit():
        return ("k", int(key))
    if key in RESERVED_KEYS:
        return ("k", RESERVED_KEYS[key])
    return ("name", key)


def bad_name(name):
    """True if the greeting name holds control, format-only, separator or unpaired characters."""
    visible = False
    for c in name:
        cat = unicodedata.category(c)
        if cat in ("Cc", "Cs", "Co", "Cn", "Zl", "Zp") or c in BIDI:
            return True
        if cat != "Cf" and not c.isspace():
            visible = True
    return not visible


def check_packages(apps, app_keys, live_tv, redirect, forbidden, protected):
    """Exit 2 if any package in the theme is unsafe."""
    pkgs = [("--apps", a) for a in apps] + [("--app-key", e.rpartition(":")[2]) for e in app_keys]
    if live_tv is not None:
        pkgs.append(("--live-tv-package", live_tv))
    if redirect is not None:
        pkgs.append(("--stock-home-redirect", redirect))
    for flag, pkg in pkgs:
        if matches(pkg, forbidden):
            fail(2, f"{flag}: {pkg} is a factory or service-menu app (config/forbidden-packages.txt). "
                    "It may never be opened. Nothing was changed.")
    if redirect is not None:
        if redirect.lower() == OURS:
            fail(2, f"--stock-home-redirect: {redirect} is our own launcher; name the TV's stock launcher instead.")
        if matches(redirect, protected):
            fail(2, f"--stock-home-redirect: {redirect} is a protected system app, not a launcher "
                    "(config/protected-packages.txt).")


def parse_args(argv):
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            fail(2, f"make_theme.py: {message}")

    p = Parser(prog="make_theme.py", description="Build a cleanyourtv theme from photos.")
    p.add_argument("--photos", help="folder with the photos (leave out for a theme with no pictures yet)")
    p.add_argument("--name", required=True, help="name shown after the greeting (1 to 40 characters)")
    p.add_argument("--apps", required=True, help=f"1 to {MAX_APPS} package names, comma separated, in dock order")
    p.add_argument("--clock", choices=["12", "24", "system"], default="system",
                   help="12- or 24-hour clock, or system (default: follow the TV; changeable on the TV)")
    p.add_argument("--out", required=True, help="theme folder to write")
    p.add_argument("--stock-home-redirect", metavar="PKG", help="stock launcher package to send back to ours")
    p.add_argument("--app-key", metavar="KEYCODE:PKG", action="append", default=[],
                   help="a remote button that opens an app (repeatable)")
    p.add_argument("--live-tv-package", metavar="PKG", help="the TV's Live TV app")
    p.add_argument("--power-on", choices=["home", "live-tv"], help="what the TV shows at power-on")
    p.add_argument("--key-filter", choices=["true", "false"], help="whether the key helpers filter keys")
    p.add_argument("--consume-volume-keys", action="store_true",
                   help="the key helpers repeat a held volume key themselves (needs --key-filter true)")
    args = p.parse_args(argv)
    name = args.name.strip()
    if not name or len(name) > 40 or bad_name(args.name):
        fail(2, "--name must be 1 to 40 visible characters, with no control or direction-changing characters")
    args.name = name
    apps = [a.strip() for a in args.apps.split(",")]
    if not 1 <= len(apps) <= MAX_APPS or len(set(apps)) != len(apps):
        fail(2, f"--apps needs 1 to {MAX_APPS} different package names, comma separated")
    for a in apps:
        if not PKG_RE.match(a):
            fail(2, f"--apps: '{a}' does not look like a package name (for example com.example.app)")
    args.apps = apps
    for flag, value in (("--stock-home-redirect", args.stock_home_redirect),
                        ("--live-tv-package", args.live_tv_package)):
        if value is not None and not PKG_RE.match(value):
            fail(2, f"{flag}: '{value}' does not look like a package name (for example com.example.app)")
    seen = {}
    for entry in args.app_key:
        key, sep, pkg = entry.rpartition(":")
        if not sep or not KEY_RE.match(key) or not PKG_RE.match(pkg):
            fail(2, f"--app-key: '{entry}' must be KEYCODE:PKG, where KEYCODE is digits, KEYCODE_NAME or "
                    "scan:digits and PKG a package name (for example 190:com.google.android.youtube.tv)")
        nk = norm_key(key)
        if (nk[0] == "k" and nk[1] in RESERVED_KEYS.values()) or (nk[0] == "scan" and nk[1] in RESERVED_SCAN):
            fail(2, f"--app-key: '{key}' is Back, Home, Power, OK/Enter or Menu, which the remote needs for "
                    "itself. Pick another button.")
        if nk in seen:
            fail(2, f"--app-key: the button '{key}' is given twice ({seen[nk]} and {entry}). One button opens one app.")
        seen[nk] = entry
    if args.power_on == "live-tv" and args.live_tv_package is None:
        fail(2, "--power-on live-tv needs --live-tv-package (the TV's Live TV app)")
    if args.consume_volume_keys and args.key_filter != "true":
        fail(2, "--consume-volume-keys needs --key-filter true (the helpers only see volume keys while filtering)")
    if args.key_filter == "false" and args.app_key:
        print("Warning: --key-filter false with --app-key: the app buttons may not work while key filtering is off",
              file=sys.stderr)
    check_packages(apps, args.app_key, args.live_tv_package, args.stock_home_redirect,
                   read_list(FORBIDDEN_LIST), read_list(PROTECTED_LIST))
    return args


def _inside(a, b):
    """True if path a is b or inside b (both resolved)."""
    return a == b or b in a.parents


def _git_ignored(path):
    """True/False from git check-ignore; None if git can't say (not installed, not a git checkout)."""
    try:
        r = subprocess.run(["git", "-C", str(REPO), "check-ignore", "-q", "--", str(path)],
                           capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode == 0:
        return True
    if r.returncode == 1:
        return False
    return None


def check_out(args):
    """Refuse unsafe output folders before any photo is read. Returns the resolved output path."""
    out = Path(args.out)
    if os.path.islink(out):
        fail(2, f"--out: '{args.out}' is a symbolic link. Give a real folder (for example user-content/theme).")
    if os.path.islink(out / "wallpapers"):
        fail(2, f"--out: '{args.out}/wallpapers' is a symbolic link. Nothing was changed.")
    if out.exists() and not out.is_dir():
        fail(3, f"--out: '{args.out}' is a file, not a folder. Give a folder (for example user-content/theme).")
    out_r = out.resolve()
    photos_r = Path(args.photos).resolve() if args.photos is not None else None
    if photos_r is not None and (_inside(out_r, photos_r) or _inside(photos_r, out_r)):
        fail(2, "--out and --photos overlap (one is inside the other). Write the theme to its own folder, "
                "for example user-content/theme. Nothing was changed.")
    try:
        non_empty = out.is_dir() and any(out.iterdir())
    except OSError as exc:
        fail(3, f"--out: can't read '{args.out}' ({exc.strerror or type(exc).__name__}). Choose another folder.")
    if non_empty and not (out / MARKER).is_file():
        fail(2, f"--out: '{args.out}' already holds files and is not a theme made by make_theme.py. "
                "Choose an empty or new folder (for example user-content/theme). Nothing was changed.")
    if _inside(out_r, REPO.resolve()):
        ignored = _git_ignored(out_r)
        if ignored is None:
            ignored = _inside(out_r, (REPO / "user-content").resolve())
        if not ignored:
            fail(2, f"--out: '{args.out}' is inside the project but not git-ignored, so the owner's name and "
                    "photos could be committed. Use user-content/theme. Nothing was changed.")
    return out_r


def load_image(f):
    """Open a photo and return a flattened, upright RGB image."""
    from PIL import Image, ImageOps

    with Image.open(f) as im:
        im = ImageOps.exif_transpose(im)
        if im.mode in ("I;16", "I;16L", "I;16B", "I;16N", "I"):
            im = im.convert("I").point(lambda v: v * (1 / 256)).convert("L")  # 16-bit range down to 8-bit
        if im.mode in ("RGBA", "LA", "PA", "La", "RGBa") or (im.mode == "P" and "transparency" in im.info):
            im = im.convert("RGBA")
            black = Image.new("RGBA", im.size, (0, 0, 0, 255))
            im = Image.alpha_composite(black, im)
        im = im.convert("RGB")
        return ImageOps.fit(im, SIZE, Image.LANCZOS, centering=(0.5, 0.5))


def encode(img):
    """JPEG bytes under MAX_BYTES. Steps quality down, then softens a little; ValueError if none fits.
    The pixels are copied into a brand-new image first, so no metadata (comment, ICC, XMP, EXIF) can follow."""
    from PIL import Image, ImageFilter

    clean = Image.frombytes("RGB", img.size, img.convert("RGB").tobytes())
    clean.info = {}
    work = clean
    for blur in (0, 1, 2, 3, 4, 6, 8):
        if blur:
            work = clean.filter(ImageFilter.GaussianBlur(blur))
            work.info = {}
        for quality in range(90, 19, -5):
            buf = io.BytesIO()
            work.save(buf, "JPEG", quality=quality, optimize=True)  # no exif/icc/comment/xmp passed
            data = buf.getvalue()
            if len(data) <= MAX_BYTES:
                return data
    raise ValueError("cannot fit 300 KB")


def write_theme(out, outputs, config):
    """Write the theme. Only our own NN.jpg files are ever deleted. OSError goes to the caller."""
    wall = out / "wallpapers"
    out.mkdir(parents=True, exist_ok=True)
    marker = out / MARKER
    if not marker.exists():
        marker.write_text("Made by scripts/make_theme.py. Its NN.jpg wallpapers are replaced on every run.\n",
                          encoding="utf-8")
    if os.path.islink(wall):
        fail(2, f"'{wall}' is a symbolic link. Nothing was changed.")
    wall.mkdir(exist_ok=True)
    others = []
    for old in wall.iterdir():  # re-runs replace the collection, and only that
        if OWN_JPG.match(old.name) and (old.is_symlink() or old.is_file()):
            old.unlink()
        else:
            others.append(old.name)
    if others:
        print(f"Warning: left alone in {wall} (not made by make_theme.py): {', '.join(sorted(others))}",
              file=sys.stderr)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    for i, data in enumerate(outputs, 1):
        fd = os.open(wall / f"{i:02d}.jpg", flags, 0o644)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
    tmp = out / "config.json.tmp"
    tmp.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, out / "config.json")


def check_theme(folder):
    """push-theme's pre-flight: config.json parses to an object, wallpapers/ holds a .jpg unless the theme says
    "wallpaper": false (no photos yet), and no forbidden package."""
    folder = Path(folder)
    try:
        config = json.loads((folder / "config.json").read_bytes().decode("utf-8-sig"))
    except FileNotFoundError:
        fail(2, f"The theme has no config.json ({folder}). Run make_theme.py again. Nothing was pushed.")
    except (OSError, ValueError):
        fail(2, f"The theme's config.json is not valid ({folder}). Run make_theme.py again. Nothing was pushed.")
    if not isinstance(config, dict):
        fail(2, "The theme's config.json is not valid. Run make_theme.py again. Nothing was pushed.")
    wall = folder / "wallpapers"
    if os.path.islink(wall):
        fail(2, "The theme's wallpapers folder is a symbolic link. Run make_theme.py again. Nothing was pushed.")
    if config.get("wallpaper") is not False and (not wall.is_dir() or not any(
            f.suffix.lower() == ".jpg" and f.is_file() for f in wall.iterdir())):
        fail(2, "The theme has no wallpapers (wallpapers/*.jpg). Run make_theme.py again. Nothing was pushed.")
    forbidden = read_list(FORBIDDEN_LIST)

    def strings(v):
        if isinstance(v, str):
            yield v
        elif isinstance(v, dict):
            for k, x in v.items():
                yield from strings(x)
        elif isinstance(v, list):
            for x in v:
                yield from strings(x)

    for s in strings(config):
        for cand in {s.strip(), s.rpartition(":")[2].strip()}:
            if PKG_RE.match(cand) and matches(cand, forbidden):
                fail(2, f"The theme names {cand}, a factory or service-menu app (config/forbidden-packages.txt). "
                        "Nothing was pushed.")
    print(f"Theme OK: {folder}")
    return 0


def main(argv):
    global MAX_BYTES
    if argv[:1] == ["--check-theme"]:
        if len(argv) != 2:
            fail(2, "Usage: make_theme.py --check-theme DIR")
        return check_theme(argv[1])
    args = parse_args(argv)
    MAX_BYTES = _max_bytes()
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        fail(3, "Pillow is missing. Run: python -m pip install -r requirements.txt")

    photos = Path(args.photos) if args.photos is not None else None
    if photos is not None and not photos.is_dir():
        fail(2, f"--photos: '{args.photos}' is not a folder")
    out = check_out(args)
    files = []
    for f in sorted(photos.iterdir() if photos is not None else [], key=lambda f: f.name.lower()):
        if not f.is_file():
            continue
        if f.name.startswith("."):
            print(f"Warning: skipped {f.name} (hidden file)", file=sys.stderr)
        elif f.suffix.lower() not in EXTENSIONS:
            print(f"Warning: skipped {f.name} (not a JPEG, PNG, WebP or HEIC photo)", file=sys.stderr)
        else:
            files.append(f)

    outputs = []
    for f in files:
        if len(outputs) >= MAX_PHOTOS:
            print(f"Warning: only the first {MAX_PHOTOS} photos are used", file=sys.stderr)
            break
        try:
            outputs.append(encode(load_image(f)))
        except Exception as exc:  # unreadable, truncated, unsupported: skip it
            print(f"Warning: skipped {f.name} ({type(exc).__name__})", file=sys.stderr)
    if photos is not None and not outputs:
        fail(2, "No usable photos (JPEG, PNG, WebP) found in the photos folder")

    try:
        config = json.loads(TEMPLATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        fail(3, "Missing or unreadable themes/template/config.json")
    config["greeting_name"] = args.name
    config["dock_apps"] = args.apps
    config["columns"] = max(int(config.get("columns", 4)), len(args.apps))
    config["clock_format"] = args.clock
    if not outputs:
        config["wallpaper"] = False  # no photos yet: plain background, nothing to rotate
        config.pop("wallpaper_rotation_minutes", None)
    for key in ("stock_home_redirect", "app_keys", "live_tv_package", "power_on_home", "boot_to_live_tv",
                "key_filter", "consume_volume_keys"):
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
    if args.consume_volume_keys:
        config["consume_volume_keys"] = True

    try:
        write_theme(out, outputs, config)
    except OSError as exc:
        fail(3, f"Can't write the theme to {args.out} ({exc.strerror or type(exc).__name__}). "
                "Check the folder exists and can be written, or choose another --out.")
    print(f"Wrote {len(outputs)} wallpapers and config.json to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
