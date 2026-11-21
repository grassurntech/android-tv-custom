"""Docs checks: CLAUDE.md's relative links exist, and no 'TBD' placeholder is left in docs/ or ARCHITECTURE.md."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class DocsTests(unittest.TestCase):
    def test_claude_md_links_exist(self):
        text = (ROOT / "CLAUDE.md").read_text(encoding="utf-8")
        links = re.findall(r"\]\(([^)\s]+)\)", text)
        checked = 0
        for link in links:
            if re.match(r"^(https?:|mailto:|#)", link):
                continue
            checked += 1
            self.assertTrue((ROOT / link.split("#")[0]).exists(), f"CLAUDE.md links to missing {link}")
        self.assertGreater(checked, 0)

    def test_no_tbd_left(self):
        files = [ROOT / "ARCHITECTURE.md"] + [p for p in (ROOT / "docs").rglob("*") if p.is_file()]
        for p in files:
            if p.suffix in (".md", ".txt"):
                self.assertNotIn("TBD", p.read_text(encoding="utf-8"), f"TBD left in {p.relative_to(ROOT)}")


if __name__ == "__main__":
    unittest.main()
