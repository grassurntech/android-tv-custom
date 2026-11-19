"""make_theme.py tests. Images are generated in a temp dir; needs Pillow (fails under TV_TEST_REQUIRE_PILLOW=1)."""
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "make_theme.py"
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
        self.assertEqual(self.run_tool(extra=["--power-on", "live-tv"]).returncode, 0)
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


if __name__ == "__main__":
    unittest.main()
