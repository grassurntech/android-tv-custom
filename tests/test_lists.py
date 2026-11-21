"""The junk list must never overlap the safety lists (IN-10)."""
import fnmatch
import unittest
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "config"


def patterns(name):
    """Pattern lines the scripts use: text before any space, tab or #, lower-cased."""
    out = []
    for line in (CONFIG / name).read_text(encoding="utf-8").splitlines():
        bare = line.split("#", 1)[0].split()
        if bare:
            out.append(bare[0].lower())
    return out


class JunkListIsSafe(unittest.TestCase):
    def test_junk_list_is_seeded(self):
        self.assertGreater(len(patterns("junk-packages.txt")), 0)

    def test_junk_entries_are_plain_package_names(self):
        for pkg in patterns("junk-packages.txt"):
            self.assertNotRegex(pkg, r"[*?\[\]]", f"{pkg}: junk entries must be exact names, not globs")

    def test_no_junk_entry_is_protected_streaming_or_forbidden(self):
        for list_name in ("protected-packages.txt", "streaming-apps.txt", "forbidden-packages.txt"):
            pats = patterns(list_name)
            for pkg in patterns("junk-packages.txt"):
                hits = [p for p in pats if fnmatch.fnmatchcase(pkg, p)]
                self.assertEqual(hits, [], f"{pkg} matches {list_name}: {hits}")


if __name__ == "__main__":
    unittest.main()
