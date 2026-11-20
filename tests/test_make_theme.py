"""make_theme.py tests. Images are generated in a temp dir; needs Pillow (fails under TV_TEST_REQUIRE_PILLOW=1)."""
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "make_theme.py"
APPS = "com.a.one,com.b.two,com.c.three,com.d.four"


class MakeThemeTests(unittest.TestCase):
    def setUp(self):
        if Image is None:
            if os.environ.get("TV_TEST_REQUIRE_PILLOW") == "1":
                raise AssertionError("Pillow is required (TV_TEST_REQUIRE_PILLOW=1) but is not installed")
            self.skipTest("Pillow is not installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.photos = Path(self.tmp.name) / "photos"
        self.photos.mkdir()
        self.out = Path(self.tmp.name) / "out"

    def run_tool(self, apps=APPS, name="Sam", clock="12", env=None, extra=()):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--photos", str(self.photos), "--name", name,
             "--apps", apps, "--clock", clock, "--out", str(self.out)] + list(extra),
            capture_output=True, text=True, env=dict(os.environ, **(env or {})))

    def config(self):
        return json.loads((self.out / "config.json").read_text(encoding="utf-8"))

    def one_photo(self):
        Image.new("RGB", (640, 480), "blue").save(self.photos / "a.jpg")

    def noise(self, size=(4000, 3000)):
        return Image.frombytes("RGB", size, os.urandom(size[0] * size[1] * 3))

    def test_writes_config_with_overrides(self):
        Image.new("RGB", (800, 600), "red").save(self.photos / "a.jpg")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        cfg = json.loads((self.out / "config.json").read_text(encoding="utf-8"))
        self.assertEqual(cfg["greeting_name"], "Sam")
        self.assertEqual(len(cfg["dock_apps"]), 4)
        self.assertEqual(cfg["columns"], 4)
        self.assertEqual(cfg["clock_format"], "12")

    def test_wallpapers_1080p_under_300kb(self):
        self.noise().save(self.photos / "n.png")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        f = self.out / "wallpapers" / "01.jpg"
        self.assertLessEqual(f.stat().st_size, 307200)
        with Image.open(f) as im:
            self.assertEqual(im.size, (1920, 1080))
            self.assertEqual(im.format, "JPEG")

    def test_names_sorted_and_rerun_clears_old(self):
        for n in ("b.jpg", "a.png", "c.webp"):
            Image.new("RGB", (640, 480), "blue").save(self.photos / n)
        self.assertEqual(self.run_tool().returncode, 0)
        names = sorted(p.name for p in (self.out / "wallpapers").iterdir())
        self.assertEqual(names, ["01.jpg", "02.jpg", "03.jpg"])
        (self.photos / "b.jpg").unlink()
        (self.photos / "c.webp").unlink()
        self.assertEqual(self.run_tool().returncode, 0)
        self.assertEqual([p.name for p in (self.out / "wallpapers").iterdir()], ["01.jpg"])

    def test_exif_gps_stripped(self):
        exif = Image.Exif()
        exif[0x0110] = "TestCam"
        exif[0x8825] = {1: "N", 2: (40.0, 44.0, 54.0), 3: "W", 4: (73.0, 59.0, 9.0)}  # GPSInfo
        Image.new("RGB", (800, 600), "green").save(self.photos / "g.jpg", exif=exif)
        with Image.open(self.photos / "g.jpg") as im:
            self.assertTrue(len(im.getexif()) > 0)  # the fixture really has EXIF
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        data = (self.out / "wallpapers" / "01.jpg").read_bytes()
        self.assertNotIn(b"Exif", data)
        with Image.open(io.BytesIO(data)) as im:
            self.assertEqual(len(im.getexif()), 0)
            self.assertNotIn("exif", im.info)

    def test_exif_orientation_applied(self):
        exif = Image.Exif()
        exif[0x0112] = 6  # rotate 90 clockwise when displayed
        im = Image.new("RGB", (400, 200), "white")
        im.paste((255, 0, 0), (0, 0, 200, 200))  # left half red
        im.save(self.photos / "r.jpg", exif=exif)
        self.assertEqual(self.run_tool().returncode, 0)
        with Image.open(self.out / "wallpapers" / "01.jpg") as out:
            # upright it is 200x400 (portrait) with red on top; cover-cropped, the top stays red
            self.assertGreater(out.getpixel((960, 20))[0], 200)
            self.assertLess(out.getpixel((960, 20))[1], 80)
            self.assertGreater(out.getpixel((960, 1060))[1], 200)

    def test_skips_undecodable_file(self):
        (self.photos / "bad.jpg").write_bytes(b"not an image")
        Image.new("RGB", (640, 480), "blue").save(self.photos / "good.jpg")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0)
        self.assertIn("skipped bad.jpg", r.stderr)
        self.assertEqual(len(list((self.out / "wallpapers").iterdir())), 1)

    def test_rejects_three_apps(self):
        Image.new("RGB", (640, 480), "blue").save(self.photos / "a.jpg")
        self.assertEqual(self.run_tool(apps="com.a.one,com.b.two,com.c.three").returncode, 2)

    def test_rejects_bad_package_name(self):
        Image.new("RGB", (640, 480), "blue").save(self.photos / "a.jpg")
        self.assertEqual(self.run_tool(apps="com.a.one,com.b.two,com.c.three,nodots").returncode, 2)
        self.assertEqual(self.run_tool(apps="com.a.one,com.b.two,com.c.three,a b.c").returncode, 2)

    def test_rejects_bad_name_and_clock(self):
        Image.new("RGB", (640, 480), "blue").save(self.photos / "a.jpg")
        self.assertEqual(self.run_tool(name="").returncode, 2)
        self.assertEqual(self.run_tool(name="x" * 41).returncode, 2)
        self.assertEqual(self.run_tool(clock="13").returncode, 2)

    def test_photo_that_cannot_fit_is_skipped_then_exit_2(self):
        self.noise((800, 600)).save(self.photos / "n.png")
        r = self.run_tool(env={"TV_MAKE_THEME_MAX_BYTES": "100"})
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("skipped n.png", r.stderr)
        self.assertFalse((self.out / "config.json").exists())

    def test_size_knob_cannot_raise_the_limit(self):
        self.noise((1920, 1080)).save(self.photos / "n.png")  # per-pixel noise: far over 300 KB at q90
        r = self.run_tool(env={"TV_MAKE_THEME_MAX_BYTES": str(10**9)})
        self.assertIn(r.returncode, (0, 2), r.stderr)
        for f in (self.out / "wallpapers").glob("*.jpg"):
            self.assertLessEqual(f.stat().st_size, 307200)

    def test_size_knob_junk_is_exit_2(self):
        Image.new("RGB", (640, 480), "blue").save(self.photos / "a.jpg")
        for bad in ("abc", "0", "-5"):
            r = self.run_tool(env={"TV_MAKE_THEME_MAX_BYTES": bad})
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertNotIn("Traceback", r.stderr)

    def test_rejects_empty_photo_folder(self):
        r = self.run_tool()
        self.assertEqual(r.returncode, 2)
        self.assertFalse((self.out / "config.json").exists())


    # ---- Home and remote-key settings: the agent passes flags, it never edits config.json by hand ----

    def test_no_optional_flags_leaves_those_keys_out(self):
        self.one_photo()
        self.assertEqual(self.run_tool().returncode, 0)
        cfg = self.config()
        for key in ("stock_home_redirect", "app_keys", "live_tv_package", "power_on_home",
                    "boot_to_live_tv", "key_filter"):
            self.assertNotIn(key, cfg)

    def test_stock_home_redirect(self):
        self.one_photo()
        r = self.run_tool(extra=["--stock-home-redirect", "com.google.android.apps.tv.launcherx"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config()["stock_home_redirect"], "com.google.android.apps.tv.launcherx")
        for bad in ("launcherx", "com.x/.Main", "a b.c", ""):
            r = self.run_tool(extra=["--stock-home-redirect", bad])
            self.assertEqual(r.returncode, 2, (bad, r.stderr))
            self.assertNotIn("Traceback", r.stderr)

    def test_app_keys_repeatable_list_of_strings(self):
        self.one_photo()
        r = self.run_tool(extra=["--app-key", "190:com.google.android.youtube.tv",
                                 "--app-key", "KEYCODE_BUTTON_3:com.netflix.ninja",
                                 "--app-key", "scan:490:com.wbd.hbomax"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config()["app_keys"], ["190:com.google.android.youtube.tv",
                                                     "KEYCODE_BUTTON_3:com.netflix.ninja",
                                                     "scan:490:com.wbd.hbomax"])

    def test_app_keys_rejects_bad_entries(self):
        self.one_photo()
        for bad in ("190", "190:", ":com.a.b", "abc:com.a.b", "keycode_x:com.a.b", "scan:x:com.a.b",
                    "190:nodots", "190:com.a.b/.Main", "190:mute", "-1:com.a.b", "scan:190", "KEYCODE_:com.a.b"):
            r = self.run_tool(extra=["--app-key", bad])
            self.assertEqual(r.returncode, 2, (bad, r.stderr))
            self.assertNotIn("Traceback", r.stderr)
            self.assertFalse((self.out / "config.json").exists())

    def test_live_tv_package(self):
        self.one_photo()
        r = self.run_tool(extra=["--live-tv-package", "com.tcl.tv"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.config()["live_tv_package"], "com.tcl.tv")
        self.assertEqual(self.run_tool(extra=["--live-tv-package", "tcl"]).returncode, 2)

    def test_power_on_sets_exactly_one(self):
        self.one_photo()
        self.assertEqual(self.run_tool(extra=["--power-on", "home"]).returncode, 0)
        cfg = self.config()
        self.assertIs(cfg["power_on_home"], True)
        self.assertNotIn("boot_to_live_tv", cfg)
        self.assertEqual(self.run_tool(extra=["--power-on", "live-tv", "--live-tv-package", "com.tcl.tv"]).returncode, 0)
        cfg = self.config()
        self.assertIs(cfg["boot_to_live_tv"], True)
        self.assertNotIn("power_on_home", cfg)
        for bad in ("both", "Home", ""):
            self.assertEqual(self.run_tool(extra=["--power-on", bad]).returncode, 2, bad)

    def test_key_filter(self):
        self.one_photo()
        self.assertEqual(self.run_tool(extra=["--key-filter", "false"]).returncode, 0)
        self.assertIs(self.config()["key_filter"], False)
        self.assertEqual(self.run_tool(extra=["--key-filter", "true"]).returncode, 0)
        self.assertIs(self.config()["key_filter"], True)
        for bad in ("False", "0", "no", ""):
            self.assertEqual(self.run_tool(extra=["--key-filter", bad]).returncode, 2, bad)

    def test_rerun_rebuilds_from_scratch(self):
        """make_theme starts from the template every time: a flag left out of a re-run is gone."""
        self.one_photo()
        self.assertEqual(self.run_tool(extra=["--key-filter", "false", "--app-key", "190:com.a.b"]).returncode, 0)
        self.assertEqual(self.run_tool(extra=["--key-filter", "false"]).returncode, 0)
        cfg = self.config()
        self.assertNotIn("app_keys", cfg)
        self.assertIs(cfg["key_filter"], False)

    # ---- TH-01..06: the output folder (only our own files are ever touched) ----

    def test_TH01_out_overlapping_photos_is_refused_and_nothing_deleted(self):
        base = Path(self.tmp.name) / "X"
        wall = base / "wallpapers"
        wall.mkdir(parents=True)
        Image.new("RGB", (640, 480), "blue").save(wall / "IMG_0001.jpg")
        (wall / "notes.txt").write_text("keep")
        (wall / "video.mov").write_bytes(b"\0" * 10)
        before = sorted(p.name for p in wall.iterdir())
        for photos, out in ((wall, base), (base, wall), (base, base), (base, base / "sub")):
            r = subprocess.run([sys.executable, str(SCRIPT), "--photos", str(photos), "--name", "Sam",
                                "--apps", APPS, "--clock", "12", "--out", str(out)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, (photos, out, r.stderr))
            self.assertIn("overlap", r.stderr)
            self.assertEqual(sorted(p.name for p in wall.iterdir()), before)
        self.assertFalse((base / "config.json").exists())

    def test_TH02_wallpapers_symlink_is_refused(self):
        self.one_photo()
        secret = Path(self.tmp.name) / "secret"
        secret.mkdir()
        (secret / "taxes.pdf").write_text("x")
        (secret / "01.jpg").write_text("not ours")
        self.out.mkdir()
        (self.out / ".made-by-make_theme").write_text("x")
        os.symlink(secret, self.out / "wallpapers")
        r = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(sorted(p.name for p in secret.iterdir()), ["01.jpg", "taxes.pdf"])
        self.assertEqual((secret / "01.jpg").read_text(), "not ours")

    def test_TH02_out_symlink_is_refused(self):
        self.one_photo()
        real = Path(self.tmp.name) / "real"
        real.mkdir()
        os.symlink(real, self.out)
        r = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertEqual(list(real.iterdir()), [])

    def test_TH02_wallpaper_file_symlink_is_not_followed(self):
        self.one_photo()
        self.assertEqual(self.run_tool().returncode, 0)
        victim = Path(self.tmp.name) / "victim.txt"
        victim.write_text("precious")
        (self.out / "wallpapers" / "01.jpg").unlink()
        os.symlink(victim, self.out / "wallpapers" / "01.jpg")
        self.assertEqual(self.run_tool().returncode, 0)
        self.assertEqual(victim.read_text(), "precious")
        self.assertFalse((self.out / "wallpapers" / "01.jpg").is_symlink())

    def test_TH03_foreign_theme_folder_is_refused(self):
        self.one_photo()
        (self.out / "wallpapers").mkdir(parents=True)
        (self.out / "config.json").write_text('{"x": 1}')
        (self.out / "wallpapers" / "01.jpg").write_text("theirs")
        r = self.run_tool()
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("not a theme made by make_theme.py", r.stderr)
        self.assertEqual((self.out / "wallpapers" / "01.jpg").read_text(), "theirs")
        self.assertEqual((self.out / "config.json").read_text(), '{"x": 1}')

    def test_TH03_our_theme_keeps_other_files_and_empty_folder_is_fine(self):
        self.one_photo()
        self.out.mkdir()  # an existing empty folder is fine
        self.assertEqual(self.run_tool().returncode, 0)
        (self.out / "wallpapers" / "mine.png").write_text("other")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("left alone", r.stderr)
        self.assertEqual((self.out / "wallpapers" / "mine.png").read_text(), "other")

    def _assert_no_metadata(self, data, *needles):
        for n in needles:
            self.assertNotIn(n, data)
        self.assertNotIn(b"\xff\xfe", data[:2000])  # no JPEG COM segment
        with Image.open(io.BytesIO(data)) as im:
            for key in ("comment", "icc_profile", "xmp", "exif", "XML:com.adobe.xmp", "Comment"):
                self.assertNotIn(key, im.info)

    def test_TH04_jpeg_comment_stripped(self):
        Image.new("RGB", (800, 600), "green").save(self.photos / "c.jpg", comment=b"Home: 12 Elm St")
        with Image.open(self.photos / "c.jpg") as im:
            self.assertEqual(im.info.get("comment"), b"Home: 12 Elm St")  # the fixture really has it
        self.assertEqual(self.run_tool().returncode, 0)
        self._assert_no_metadata((self.out / "wallpapers" / "01.jpg").read_bytes(), b"Elm St")

    def test_TH04_png_text_stripped(self):
        from PIL.PngImagePlugin import PngInfo
        info = PngInfo()
        info.add_text("comment", "Home: 12 Elm St")
        info.add_text("Comment", "Phone 555-0100")
        Image.new("RGB", (800, 600), "green").save(self.photos / "t.png", pnginfo=info)
        self.assertEqual(self.run_tool().returncode, 0)
        self._assert_no_metadata((self.out / "wallpapers" / "01.jpg").read_bytes(), b"Elm St", b"555-0100")

    def test_TH04_xmp_stripped(self):
        xmp = (b'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
               b'<rdf:Description>Home: 12 Elm St</rdf:Description></rdf:RDF></x:xmpmeta>')
        Image.new("RGB", (800, 600), "green").save(self.photos / "x.jpg", xmp=xmp)
        self.assertIn(b"Elm St", (self.photos / "x.jpg").read_bytes())
        self.assertEqual(self.run_tool().returncode, 0)
        self._assert_no_metadata((self.out / "wallpapers" / "01.jpg").read_bytes(), b"Elm St", b"xmpmeta")

    def test_TH04_icc_stripped(self):
        from PIL import ImageCms
        icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        Image.new("RGB", (800, 600), "green").save(self.photos / "i.jpg", icc_profile=icc)
        with Image.open(self.photos / "i.jpg") as im:
            self.assertIn("icc_profile", im.info)
        self.assertEqual(self.run_tool().returncode, 0)
        self._assert_no_metadata((self.out / "wallpapers" / "01.jpg").read_bytes(), b"ICC_PROFILE")

    def test_TH05_out_in_repo_not_git_ignored_is_refused(self):
        self.one_photo()
        target = ROOT / "themes" / "zz-make-theme-test-out"
        self.assertFalse(target.exists())
        for env in (None, {"PATH": str(Path(self.tmp.name) / "no-git-here")}):  # git, then no git at all
            r = subprocess.run([sys.executable, str(SCRIPT), "--photos", str(self.photos), "--name", "Sam",
                                "--apps", APPS, "--clock", "12", "--out", str(target)],
                               capture_output=True, text=True, env=dict(os.environ, **(env or {})))
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn("user-content/theme", r.stderr)
            self.assertFalse(target.exists())

    def test_TH06_out_is_a_file_is_exit_3(self):
        self.one_photo()
        self.out.write_text("i am a file")
        r = self.run_tool()
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertEqual(self.out.read_text(), "i am a file")

    @unittest.skipIf(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0), "needs POSIX non-root")
    def test_TH06_unwritable_out_is_exit_3(self):
        self.one_photo()
        parent = Path(self.tmp.name) / "locked"
        parent.mkdir()
        parent.chmod(stat.S_IRUSR | stat.S_IXUSR)
        self.addCleanup(parent.chmod, stat.S_IRWXU)
        self.out = parent / "theme"
        r = self.run_tool()
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertIn("Can't write", r.stderr)

    # ---- TH-15..19: inputs ----

    def test_TH15_key_filter_false_with_app_key_warns(self):
        self.one_photo()
        r = self.run_tool(extra=["--key-filter", "false", "--app-key", "190:com.a.b"])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Warning", r.stderr)

    def test_TH16_16bit_grayscale_keeps_its_tone(self):
        Image.new("I;16", (640, 480), 32768).save(self.photos / "g16.png")
        self.assertEqual(self.run_tool().returncode, 0)
        with Image.open(self.out / "wallpapers" / "01.jpg") as im:
            r, g, b = im.getpixel((960, 540))
        self.assertTrue(110 <= r <= 145, r)

    def test_TH17_transparent_pixels_become_black(self):
        Image.new("RGBA", (640, 480), (255, 0, 0, 0)).save(self.photos / "a.png")
        self.assertEqual(self.run_tool().returncode, 0)
        with Image.open(self.out / "wallpapers" / "01.jpg") as im:
            self.assertLess(max(im.getpixel((960, 540))), 20)

    def test_TH19_other_and_hidden_files_skipped_with_warning(self):
        self.one_photo()
        Image.new("RGB", (64, 48), "blue").save(self.photos / "b.gif")
        Image.new("RGB", (64, 48), "blue").save(self.photos / "c.tif")
        Image.new("RGB", (64, 48), "blue").save(self.photos / ".hidden.jpg")
        r = self.run_tool()
        self.assertEqual(r.returncode, 0, r.stderr)
        for n in ("b.gif", "c.tif", ".hidden.jpg"):
            self.assertIn(f"skipped {n}", r.stderr)
        self.assertEqual([p.name for p in (self.out / "wallpapers").iterdir()], ["01.jpg"])


class MakeThemeArgsTests(unittest.TestCase):
    """Argument and package checks: they run before Pillow is needed, so these run without Pillow too."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name) / "out"

    def run_tool(self, apps=APPS, name="Sam", extra=(), script=SCRIPT):
        return subprocess.run(
            [sys.executable, str(script), "--photos", str(Path(self.tmp.name) / "nophotos"), "--name", name,
             "--apps", apps, "--clock", "12", "--out", str(self.out)] + list(extra),
            capture_output=True, text=True)

    def assertRefused(self, r, code=2):
        self.assertEqual(r.returncode, code, r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertFalse(self.out.exists())

    def test_TH10_forbidden_package_anywhere_is_refused(self):
        self.assertRefused(self.run_tool(apps="com.a.one,com.b.two,com.c.three,com.tcl.factory"))
        self.assertRefused(self.run_tool(apps="com.a.one,com.b.two,com.c.three,COM.TCL.FACTORY.view"))
        self.assertRefused(self.run_tool(extra=["--app-key", "190:com.tcl.factory"]))
        self.assertRefused(self.run_tool(extra=["--live-tv-package", "com.tcl.factory.view"]))
        self.assertRefused(self.run_tool(extra=["--stock-home-redirect", "com.tcl.factory.home"]))
        r = self.run_tool(extra=["--app-key", "190:com.tcl.factory"])
        self.assertIn("forbidden", r.stderr)

    def test_TH11_stock_home_redirect_protected_or_ours_is_refused(self):
        for pkg in ("com.android.tv.settings", "com.gathin.tvhome", "COM.GATHIN.TVHOME",
                    "com.google.android.setupwizard"):
            self.assertRefused(self.run_tool(extra=["--stock-home-redirect", pkg]))

    def test_TH12_reserved_remote_keys_are_refused(self):
        for key in ("KEYCODE_BACK", "4", "3", "KEYCODE_HOME", "KEYCODE_POWER", "26", "23", "KEYCODE_DPAD_CENTER",
                    "66", "KEYCODE_ENTER", "82", "KEYCODE_MENU", "004", "scan:116", "scan:158", "scan:352"):
            r = self.run_tool(extra=["--app-key", f"{key}:com.a.b"])
            self.assertRefused(r)
            self.assertIn("remote needs", r.stderr, key)

    def test_TH13_same_key_twice_is_refused(self):
        self.assertRefused(self.run_tool(extra=["--app-key", "190:com.a.b", "--app-key", "190:com.c.d"]))
        self.assertRefused(self.run_tool(extra=["--app-key", "0190:com.a.b", "--app-key", "190:com.c.d"]))
        self.assertRefused(self.run_tool(extra=["--app-key", "scan:490:com.a.b", "--app-key", "scan:490:com.c.d"]))

    def test_TH14_power_on_live_tv_needs_package(self):
        r = self.run_tool(extra=["--power-on", "live-tv"])
        self.assertRefused(r)
        self.assertIn("--live-tv-package", r.stderr)

    def test_TH18_names_with_invisible_or_control_characters_are_refused(self):
        bads = ["Sam" + chr(0x7F), "Sam" + chr(0x85), "Sam" + chr(0x202E), chr(0x200B) * 2,
                "Sam" + chr(0x2028) + "x", chr(0x200D)]
        if os.name != "nt":
            bads.append(b"Sam\xed\xa0\x80")  # a lone surrogate (CESU-8 bytes): Python sees \udcxx
        for bad in bads:
            r = subprocess.run([sys.executable, str(SCRIPT), "--photos", self.tmp.name, "--name", bad,
                                "--apps", APPS, "--clock", "12", "--out", str(self.out)],
                               capture_output=True, text=True, errors="replace")
            self.assertRefused(r)
            self.assertIn("--name", r.stderr, repr(bad))
        ok = self.run_tool(name="Zo" + chr(0xEB) + " " + chr(0x1F468) + chr(0x200D) + chr(0x1F469))  # emoji with a joiner is fine
        self.assertNotIn("--name", ok.stderr)

    def _fake_repo(self, forbidden=None, protected=None):
        repo = Path(self.tmp.name) / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy(SCRIPT, repo / "scripts" / "make_theme.py")
        (repo / "config").mkdir()
        for name, text in (("forbidden-packages.txt", forbidden), ("protected-packages.txt", protected)):
            src = ROOT / "config" / name
            if text is None:
                shutil.copy(src, repo / "config" / name)
            elif text is not False:
                (repo / "config" / name).write_bytes(text)
        return repo / "scripts" / "make_theme.py"

    def test_TH10_lists_parsed_like_the_scripts(self):
        """BOM, CRLF, inline comments and spaces are stripped; patterns are case-insensitive globs."""
        script = self._fake_repo(forbidden=b"\xef\xbb\xbf  *Spooky*  # inline comment\r\n# whole line\r\n")
        self.assertRefused(self.run_tool(apps="com.a.one,com.b.two,com.c.three,com.x.spooky", script=script))

    def test_TH10_unreadable_or_empty_list_fails_closed(self):
        for forbidden, protected in ((b"# only comments\n\n", None), (False, None), (None, b"  \n")):
            script = self._fake_repo(forbidden=forbidden, protected=protected)
            self.assertRefused(self.run_tool(script=script), code=3)
            shutil.rmtree(script.parent.parent)


class CheckThemeTests(unittest.TestCase):
    """make_theme.py --check-theme: push-theme's pre-flight (TH-30, TH-31). No Pillow needed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.theme = Path(self.tmp.name) / "theme"
        (self.theme / "wallpapers").mkdir(parents=True)
        (self.theme / "wallpapers" / "01.jpg").write_bytes(b"\xff\xd8 fake")
        (self.theme / "config.json").write_text('{"dock_apps": ["com.a.b"], "app_keys": ["190:com.c.d"]}')

    def check(self):
        return subprocess.run([sys.executable, str(SCRIPT), "--check-theme", str(self.theme)],
                              capture_output=True, text=True)

    def test_good_theme_passes(self):
        self.assertEqual(self.check().returncode, 0)

    def test_TH30_invalid_config_or_no_wallpapers_is_exit_2(self):
        (self.theme / "config.json").write_text("{not json")
        self.assertEqual(self.check().returncode, 2)
        (self.theme / "config.json").write_text("[1, 2]")
        self.assertEqual(self.check().returncode, 2)
        (self.theme / "config.json").write_text("{}")
        (self.theme / "wallpapers" / "01.jpg").unlink()
        self.assertEqual(self.check().returncode, 2)
        (self.theme / "wallpapers").rmdir()
        r = self.check()
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("Traceback", r.stderr)

    def test_TH31_forbidden_package_anywhere_is_exit_2(self):
        for cfg in ('{"live_tv_package": "com.tcl.factory.view", "boot_to_live_tv": true}',
                    '{"app_keys": ["190:com.tcl.factory"]}', '{"dock_apps": ["com.a.b", "com.tcl.servicemenu"]}',
                    '{"stock_home_redirect": "com.tcl.factory.home"}', '{"x": {"y": ["com.x.hiddenmenu"]}}'):
            (self.theme / "config.json").write_text(cfg)
            r = self.check()
            self.assertEqual(r.returncode, 2, cfg)
            self.assertIn("Nothing was pushed", r.stderr)


if __name__ == "__main__":
    unittest.main()
