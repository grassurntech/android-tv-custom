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

    def run_tool(self, apps=APPS, name="Sam", clock="12", env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--photos", str(self.photos), "--name", name,
             "--apps", apps, "--clock", clock, "--out", str(self.out)],
            capture_output=True, text=True, env=dict(os.environ, **(env or {})))

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

    def test_rejects_empty_photo_folder(self):
        r = self.run_tool()
        self.assertEqual(r.returncode, 2)
        self.assertFalse((self.out / "config.json").exists())


if __name__ == "__main__":
    unittest.main()
