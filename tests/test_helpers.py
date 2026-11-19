"""Direct tests of tv_latest_backup / Get-TvLatestBackup: a leftover .partial folder is never a backup."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    from script_cases import ROOT, find_bash, find_powershell, require_shell
except ImportError:
    from tests.script_cases import ROOT, find_bash, find_powershell, require_shell


def make_backups(base):
    for name in ("2026-01-01_000000", "2026-01-01_000000.partial", "notes"):
        d = Path(base) / "backups" / name
        d.mkdir(parents=True)
        (d / "packages-all.txt").write_text("package:a\n")
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
