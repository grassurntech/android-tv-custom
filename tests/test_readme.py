"""README checks: anchors resolve (GitHub slug rules), relative links exist, mock-up is 1920x1080 and <= 500 KB.
The mock-up check needs Pillow (fails under TV_TEST_REQUIRE_PILLOW=1, otherwise skips)."""
import os
import re
import unittest
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    Image = None

ROOT = Path(__file__).resolve().parent.parent
README = ROOT / "README.md"
MOCKUP = ROOT / "docs" / "images" / "home-mockup.png"


def slug(heading):
    s = re.sub(r"`", "", heading.strip().lower())
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def prose():
    """README text with fenced code blocks removed."""
    return re.sub(r"```.*?```", "", README.read_text(encoding="utf-8"), flags=re.S)


class ReadmeTests(unittest.TestCase):
    def test_anchors_resolve(self):
        text = prose()
        slugs = {slug(m.group(1)) for m in re.finditer(r"^#{1,6}\s+(.+)$", text, flags=re.M)}
        anchors = re.findall(r"\]\(#([^)]+)\)", text)
        self.assertTrue(anchors)
        for a in anchors:
            self.assertIn(a, slugs, f"anchor #{a} has no heading")

    def test_relative_links_exist(self):
        links = re.findall(r"\]\(([^)\s]+)\)", prose())
        checked = 0
        for link in links:
            if re.match(r"^(https?:|mailto:|#)", link):
                continue
            checked += 1
            self.assertTrue((ROOT / link.split("#")[0]).exists(), f"missing file for link {link}")
        self.assertGreater(checked, 0)

    def test_mockup(self):
        self.assertTrue(MOCKUP.is_file())
        self.assertLessEqual(MOCKUP.stat().st_size, 500 * 1024)
        if Image is None:
            if os.environ.get("TV_TEST_REQUIRE_PILLOW") == "1":
                raise AssertionError("Pillow is required (TV_TEST_REQUIRE_PILLOW=1) but is not installed")
            self.skipTest("Pillow is not installed")
        with Image.open(MOCKUP) as im:
            self.assertEqual(im.size, (1920, 1080))


if __name__ == "__main__":
    unittest.main()
