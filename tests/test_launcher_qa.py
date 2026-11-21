"""Launcher checks the JSON case format can't express (file modes). Uses the same runner as script_cases.py."""
import os
import stat
import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from script_cases import implementations, run_case  # noqa: E402

STUB_SH = ('#!/usr/bin/env bash\n: > "$HOST_KEY_DIR/debug.keystore"\n'
           'd="$(dirname "$0")/../launcher/app/build/outputs/apk/release"\nmkdir -p "$d"\n'
           'printf "PK fake apk\\n" > "$d/app-release.apk"\nexit 0\n')


class LauncherQA(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "POSIX file modes")
    def test_TH43_keystore_folder_700_and_files_600(self):
        ext, argv = implementations()["bash"]
        if argv is None:
            self.skipTest("bash is not installed")
        case = {"script": "build-launcher", "args": [], "env": {}, "bin": {"docker": {"exit": 0}},
                "files": {"vendor/cleanyourtv/tools/docker-build.sh": STUB_SH}}
        with tempfile.TemporaryDirectory() as tmp:
            proc = run_case(case, "bash", ext, argv, tmp)[0]  # (proc, ..., repo, ...): only proc is relied on
            repo = Path(tmp) / "tv repo"
            self.assertEqual(proc.returncode, 0, proc.stderr)
            keydir = repo / "user-content" / "keystore"
            self.assertEqual(stat.S_IMODE(keydir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((keydir / "debug.keystore").stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
