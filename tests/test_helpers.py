"""Direct tests of tv_latest_backup / Get-TvLatestBackup: only a finished, valid, past-dated folder is a backup (SC-22, SC-23, SC-25)."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from script_cases import ROOT, find_bash, find_powershell, require_shell
except ImportError:
    from tests.script_cases import ROOT, find_bash, find_powershell, require_shell


BACKUP_FILES = ("packages-disabled.txt", "getprop.txt", "settings-global.txt", "settings-secure.txt",
                "settings-system.txt", "home-activity.txt")


def make_backups(base):
    """Only 2026-01-01_000000 is a usable backup; every other folder is invalid in a different way."""
    names = ("2026-01-01_000000", "2026-01-01_000000.partial", "notes",
             "9999-12-31_235959",   # SC-23: in the future
             "2026-13-01_000000",   # SC-23: no such month
             "2026-01-02_000000",   # SC-22: no settings/getprop files
             "2026-01-03_000000")   # SC-22: packages-all.txt holds no package: lines
    for name in names:
        d = Path(base) / "backups" / name
        d.mkdir(parents=True)
        (d / "packages-all.txt").write_text("Error: no package manager\n" if name == "2026-01-03_000000" else "package:a\n")
        if name != "2026-01-02_000000":
            for f in BACKUP_FILES:
                (d / f).write_text("")
    (Path(base) / "backups" / "2025-12-31_235959").mkdir()


class LatestBackup(unittest.TestCase):
    def _env(self, tmp):
        env = {k: v for k, v in os.environ.items() if k not in ("TV_IP", "TV_ADB_PORT", "TV_BACKUP_DIR", "ADB")}
        env.update(TV_IP="10.0.0.1", TV_BACKUP_DIR=str(Path(tmp) / "backups") + "/")
        return env

    def test_bash_ignores_partial(self):
        bash = require_shell("bash", find_bash())
        if not bash:
            self.skipTest("bash is not installed")
        with tempfile.TemporaryDirectory() as tmp:
            make_backups(tmp)
            out = subprocess.run([bash, "-c", f'. "{ROOT}/scripts/lib/tv-env.sh"; tv_load_env; tv_latest_backup'],
                                 env=self._env(tmp), capture_output=True, text=True).stdout.strip()
            self.assertEqual(Path(out).name, "2026-01-01_000000")

    def _warns_bash(self, backup_dir):
        bash = require_shell("bash", find_bash())
        if not bash:
            self.skipTest("bash is not installed")
        env = {k: v for k, v in os.environ.items() if k not in ("TV_IP", "TV_ADB_PORT", "TV_BACKUP_DIR", "ADB")}
        env.update(TV_IP="10.0.0.1", TV_BACKUP_DIR=backup_dir)
        err = subprocess.run([bash, "-c", f'. "{ROOT}/scripts/lib/tv-env.sh"; tv_load_env'],
                             env=env, capture_output=True, text=True).stderr
        return "Warning: TV_BACKUP_DIR" in err

    def test_bash_warns_for_repo_path_in_other_letter_case(self):
        # SC-42: same folder on a case-insensitive disk; a false warning on Linux costs nothing.
        self.assertTrue(self._warns_bash(str(ROOT).swapcase() + "/my-backups"))

    def test_bash_warns_for_symlink_into_repo(self):
        # SC-42: a symlink that points into the project is still inside it.
        with tempfile.TemporaryDirectory() as tmp:
            link = Path(tmp) / "link"
            link.symlink_to(ROOT)
            self.assertTrue(self._warns_bash(str(link / "my-backups")))
            self.assertFalse(self._warns_bash(str(link / "backups" / "tv")))

    def test_powershell_ignores_partial(self):
        ps = require_shell("powershell", find_powershell())
        if not ps:
            self.skipTest("powershell is not installed")
        with tempfile.TemporaryDirectory() as tmp:
            make_backups(tmp)
            cmd = (f"Import-Module '{ROOT}/scripts/lib/TvEnv.psm1' -Force; Import-TvEnv; Get-TvLatestBackup")
            out = subprocess.run([ps, "-NoProfile"] + (["-ExecutionPolicy", "Bypass"] if os.name == "nt" else []) + ["-Command", cmd], env=self._env(tmp),
                                 capture_output=True, text=True).stdout.strip()
            self.assertEqual(Path(out).name, "2026-01-01_000000")
