"""Entry point so `unittest discover` picks up the generated script cases."""
try:
    from script_cases import ScriptCases  # noqa: F401  (tests/ is the discovery root)
except ImportError:
    from tests.script_cases import ScriptCases  # noqa: F401


import unittest as _unittest
from pathlib import Path as _Path


class CasesFileIsAscii(_unittest.TestCase):
    def test_refusal_cases_is_pure_ascii(self):
        # Non-ASCII (a literal BOM, say) decodes differently on Windows runners; keep escapes as \uXXXX.
        here = _Path(__file__).resolve().parent
        for f in [here / "refusal-cases.json"] + sorted(here.glob("cases-*.json")):
            f.read_bytes().decode("ascii")
