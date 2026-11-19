"""PROMPT.md tests: the one prompt an owner pastes must name the real scripts, keep the safety rules,
and never tell the agent to do what only the scripts may do. Checks are case-insensitive but real."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPT = ROOT / "PROMPT.md"
SCRIPTS = ["connect", "backup", "disable-one", "restore", "fetch-tools",
           "build-launcher", "install-launcher", "push-theme"]
EXIT_CODES = ["0", "2", "3", "10", "11", "12", "13", "14", "20", "21", "22", "30"]
NEGATION = re.compile(r"\b(never|not|don't|do not|no)\b", re.I)


class PromptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = PROMPT.read_text(encoding="utf-8") if PROMPT.exists() else ""
        cls.low = cls.text.lower()
        cls.lines = cls.text.splitlines()
        # Sentences, with wrapped lines joined, so a prohibition must sit in the same sentence as the command.
        flat = re.sub(r"\s+", " ", cls.text)
        cls.sentences = [s for s in re.split(r"[.!?]\**(?:\s+|$)|\s\|\s|^#+ ", flat) if s.strip()]

    def setUp(self):
        self.assertTrue(PROMPT.exists(), "PROMPT.md is missing")

    def has(self, phrase):
        self.assertIn(phrase.lower(), self.low, f"PROMPT.md should mention: {phrase}")

    # --- The brief's required assertions -------------------------------------------------------

    def test_names_every_script_for_both_systems(self):
        for name in SCRIPTS:
            for ext in ("sh", "ps1"):
                pattern = rf"scripts[/\\]{re.escape(name)}\.{ext}\b"
                self.assertRegex(self.text, pattern, f"missing scripts/{name}.{ext}")

    def test_core_safety_phrases(self):
        self.has("never uninstall")
        self.has("one package at a time")

    def test_stop_next_to_refuse(self):
        near = re.compile(r"refus\w*[^.\n]{0,80}\bstop|\bstop\w*[^.\n]{0,80}refus", re.I)
        self.assertRegex(self.text, near, "'stop' should sit next to 'refuse' in one sentence")

    def test_names_release(self):
        self.assertRegex(self.text, r"\bv1\.0\b")

    def test_names_restore(self):
        self.assertRegex(self.text, r"bash scripts/restore\.sh\b")
        self.assertRegex(self.text, r"powershell -NoProfile -ExecutionPolicy Bypass -File scripts\\restore\.ps1")
        self.assertRegex(self.text, r"restore\.(sh|ps1) --home-only")

    # --- What the prompt must cover ------------------------------------------------------------

    def test_phases_zero_to_seven_in_order(self):
        positions = []
        for n in range(8):
            m = re.search(rf"^#+ .*phase {n}\b", self.text, re.I | re.M)
            self.assertIsNotNone(m, f"missing a heading for phase {n}")
            positions.append(m.start())
        self.assertEqual(positions, sorted(positions), "phases must appear in order 0 to 7")

    def test_asks_before_moving_on(self):
        # one sentence (it may wrap across lines): summarise, then wait for the owner's yes
        self.assertRegex(self.low, r"summary[^.]{0,160}\byes\b|\byes\b[^.]{0,160}summary")

    def test_exit_code_table(self):
        rows = re.findall(r"^\|\s*`?(\d+)`?[^|\n]*\|", self.text, re.M)
        for code in EXIT_CODES:
            self.assertIn(code, rows, f"exit code {code} has no row in the exit-code table")
        # disable-one's special case: the TV turned the app off, but the undo log failed
        self.assertRegex(self.low, r"did turn[^\n]{0,200}log|log[^\n]{0,200}did turn")

    def test_streaming_apps_kept(self):
        for app in ("netflix", "prime", "disney+", "youtube"):
            self.has(app)
        self.assertRegex(self.low, r"settings\s*(→|->|>)\s*apps")
        self.has("continue watching")
        self.assertRegex(self.low, r"ads inside[^.\n]{0,80}(can't|cannot)")

    def test_cleanup_sources_and_guesses(self):
        self.has("config/junk-packages.txt")
        self.has("debloat.txt")
        self.has("my guess")
        self.has("dumpsys package")
        self.assertRegex(self.low, r"every 3 packages|every three packages")

    def test_home_screen_steps(self):
        self.assertIn(".venv/bin/python scripts/make_theme.py", self.text)
        self.assertIn(r".venv\Scripts\python scripts\make_theme.py", self.text)
        for flag in ("--photos", "--name", "--apps", "--clock", "--out"):
            self.has(flag)
        self.has("user-content/theme")
        self.has("heic")
        self.has("sips -s format jpeg")
        self.has("home-state.txt")
        self.has("stock_package")

    def test_setup_wizard_rule(self):
        self.has("setupwraith")
        self.assertRegex(self.low, r"setup wizard[^\n]{0,120}never[^\n]{0,40}disable")
        self.has("stock_home_redirect")
        self.has("home_key_service=1")

    def test_remote_buttons_and_power_on(self):
        self.has("app_keys")
        self.has("key-repeat")
        self.has("power_on_home")
        self.has("boot_to_live_tv")
        self.assertRegex(self.low, r"never set both")

    def test_upstream_lessons(self):
        self.assertRegex(self.low, r"second[^.\n]{0,80}allow debugging")
        self.has("15 seconds")
        self.assertRegex(self.low, r"\bsync\b")
        self.assertRegex(self.low, r"factory|service menu")
        self.assertRegex(self.low, r"wi-fi")

    def test_finish(self):
        self.has("SUMMARY.md")
        self.has("network debugging")
        self.has("usb debugging")
        self.assertRegex(self.low, r"confirm[^.\n]{0,80}off|off[^.\n]{0,80}confirm")

    def test_privacy(self):
        self.assertRegex(self.low, r"never upload")
        self.assertRegex(self.low, r"never commit")

    def test_env_setup_by_copy(self):
        self.has(".env.example")
        self.has("TV_IP")

    # --- What the prompt must never tell the agent to do ---------------------------------------

    def test_never_reads_env(self):
        self.assertRegex(self.low, r"never read `?\.env`?")
        for sentence in self.sentences:
            low = sentence.lower()
            if ".env" in low.replace(".env.example", "") and re.search(r"\b(read|cat|open|show|print)\b", low):
                self.assertRegex(low, NEGATION, f"a sentence seems to tell the agent to read .env: {sentence}")

    def test_direct_package_commands_only_as_prohibitions(self):
        risky = re.compile(r"pm (disable-user|uninstall|clear|hide|suspend|enable)\b|\broot\b|fastboot", re.I)
        for sentence in self.sentences:
            if risky.search(sentence):
                self.assertRegex(sentence, NEGATION, f"risky command not phrased as a prohibition: {sentence}")

    def test_referenced_scripts_exist(self):
        for name, ext in set(re.findall(r"scripts[/\\]([a-z_-]+)\.(sh|ps1|py)\b", self.text)):
            self.assertTrue((ROOT / "scripts" / f"{name}.{ext}").exists(), f"PROMPT.md names a missing script: {name}.{ext}")

    def test_restore_flags_are_real(self):
        for flag in re.findall(r"restore\.(?:sh|ps1) (--[a-z-]+)", self.text):
            self.assertIn(flag, ("--home-only", "--packages-only"))

    def test_length(self):
        self.assertLessEqual(len(self.lines), 470, "PROMPT.md should stay under about 450 lines")


if __name__ == "__main__":
    unittest.main()
