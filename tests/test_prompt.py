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

    # --- Fix round 1: the safe Home flow (controller rulings R-A to R-D) ------------------------

    def paragraphs(self):
        return [p for p in re.split(r"\n\s*\n", self.text) if p.strip()]

    def test_home_invariant(self):
        # R-A: never reboot or end a turn unless Home is ours or the recorded stock launcher.
        self.assertRegex(self.low, r"never reboot")
        self.has("stock_component")
        self.has("cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME")
        for bad in ("setupwraith", "recoveryactivity", "fallbackhome"):
            self.has(bad)
        self.assertRegex(self.low, r"restore(\.sh)?`? --home-only`?[^.]{0,40}immediately|immediately[^.]{0,80}--home-only")

    def test_every_reboot_is_gated_by_the_home_check(self):
        gated = 0
        for para in self.paragraphs():
            if re.search(r"run `reboot`", para, re.I):
                gated += 1
                self.assertRegex(para, re.compile(r"home check", re.I), f"reboot without the Home check: {para[:120]}")
        self.assertGreaterEqual(gated, 2, "Phases 5 and 6 each restart the TV once")

    def test_google_tv_keeps_stock_launcher(self):
        # R-B: keep launcherx, redirect it, never point stock_home_redirect at the wizard.
        self.assertRegex(self.low, r"launcherx[^.]{0,200}\b(keep|kept|stays)|\b(keep|kept|stays)\b[^.]{0,200}launcherx")
        self.assertRegex(self.low, r"(never|do not|don't) run `?disable-one`? on (it|the stock launcher)")
        for s in self.sentences:
            low = s.lower()
            if "stock_home_redirect" in low:
                self.assertNotRegex(low, r"took home|setupwraith|wizard", f"stock_home_redirect must name the stock launcher: {s}")
        self.assertRegex(self.low, r"stock_home_redirect[^.]{0,120}(stock launcher|stock_package)")
        self.assertRegex(self.low, r"task 12")

    def test_disable_one_never_looped(self):
        self.assertRegex(self.low, r"never[^.]{0,80}\bloop")
        self.has("xargs")
        self.assertRegex(self.low, r"one\s+`?disable-one`?\s+per\s+(tool call|command)")

    def test_exit_code_fixes(self):
        self.assertRegex(self.text, r"(?m)^\|\s*1[^|\n]*\|[^\n]*install-launcher[^\n]*restore --home-only")
        self.assertRegex(self.low, r"`?restore`? (ends|stops|exits) with any (code other than 0|non-zero)")
        self.assertRegex(self.low, r"in phase 7[^.]{0,120}21|21[^.]{0,120}phase 7")
        self.assertRegex(self.low, r"push-theme[^|\n]{0,200}\|[^\n]*(stop|no retry)")

    def test_live_tv_package(self):
        self.has("live_tv_package")
        self.has("wm_set_resumed_activity")

    def test_minor_fixes(self):
        for s in self.sentences:
            if "dumpsys wifi" in s.lower():
                self.assertIn("cname=", s, f"dumpsys wifi only for the cname= check: {s}")
        self.assertRegex(self.text, r"getevent -lt -c \d+")
        self.assertNotRegex(self.text, r"(?m)^#+ Read-only commands")
        self.assertRegex(self.low, r"(terminal|powershell)[^.]{0,200}\bcd\b")

    # --- Fix round 2: safe end states, no ungated power cycle ------------------------------------

    def section(self, start, end):
        a = re.search(start, self.text, re.M).start()
        b = re.search(end, self.text[a + 1:], re.M).start() + a + 1
        return re.sub(r"[ \t]*\n[ \t]*", " ", self.text[a:b])  # one line, so wrapped phrases still match

    def test_stop_rule_keeps_the_tv_on(self):
        self.assertNotRegex(self.low, r"never end (a|your) turn")
        check = self.section(r"^### The Home check", r"^### ").lower()
        self.assertRegex(check, r"still wrong")
        self.assertRegex(check, r"any code other than 0")
        self.assertRegex(check, r"can't be reached|cannot be reached")
        self.assertIn("please leave the tv switched on", check)
        self.assertIn("don't unplug it or restart it", check)
        self.assertIn("summary.md", check)
        self.assertRegex(check, r"issue")
        self.assertRegex(check, r"restore --packages-only")

    def test_no_unconditional_power_cycle(self):
        for s in self.sentences:
            if re.search(r"unplug", s, re.I):
                self.assertRegex(s, re.compile(r"\b(only|never|don't|do not|not)\b", re.I),
                                 f"power cycle suggested without a condition: {s}")
        wrong = self.section(r"^## If something goes wrong", r"\Z|^## ").lower()
        self.assertRegex(wrong, r"what does the tv screen show")
        self.assertRegex(wrong, r"every minute|once a minute")
        self.assertRegex(wrong, r"only if[^.]{0,200}(normal|picture)")

    def test_phase3_stops_on_a_non_launcher_home(self):
        p3 = self.section(r"^## Phase 3", r"^## Phase 4").lower()
        for word in ("`android`", "setupwraith", "recoveryactivity", "fallbackhome"):
            self.assertIn(word, p3)
        self.assertRegex(p3, r"stop[^.]{0,40}change nothing|change nothing[^.]{0,40}stop|nothing was changed")

    def test_restore_branches_then_stop(self):
        p67 = self.section(r"^\*\*6\.7", r"^\*\*6\.8").lower()
        self.assertRegex(p67, r"restore --home-only`? immediately, then stop")

    # --- Final fix wave: theme flags, privacy-safe sharing, gated restarts ------------------------

    def test_theme_settings_are_make_theme_flags_never_hand_edits(self):
        # .claude/settings.json denies Read of user-content/**, so the agent must never be told to edit it.
        for bad in ("edit user-content", "open user-content/theme/config.json", "to `user-content/theme/config.json`",
                    "to user-content/theme/config.json", "add back the extra keys", "must be added again"):
            self.assertNotIn(bad, self.low, f"PROMPT.md tells the agent to hand-edit the theme: {bad}")
        verb = re.compile(r"\b(add|edit|open|read|change|modify|cat)\b", re.I)
        for s in self.sentences:
            if "user-content/" in s and verb.search(s):
                self.assertRegex(s, NEGATION, f"a sentence seems to tell the agent to open or edit user-content/: {s}")
        for flag in ("--stock-home-redirect", "--app-key", "--live-tv-package", "--power-on home",
                     "--power-on live-tv", "--key-filter"):
            self.has(flag)
        p62 = self.section(r"^\*\*6\.2", r"^\*\*6\.3").lower()
        self.assertRegex(p62, r"from scratch")
        self.assertRegex(p62, r"(full|every|whole)[^.]{0,40}(set|list) of flags|every flag")
        self.assertRegex(p62, r"never open or edit anything in `user-content/`")
        p7 = self.section(r"^## Phase 7", r"^---").lower()
        self.assertRegex(p7, r"make_theme`? again[^.]{0,120}(every|full)[^.]{0,40}flag")

    def test_only_share_md_is_ever_shared(self):
        check = self.section(r"^### The Home check", r"^### ").lower()
        self.assertIn("share.md", check)
        self.assertRegex(check, r"paste `share\.md`")
        self.assertRegex(check, r"never paste `summary\.md`")
        for word in ("model", "android version", "step", "exit code"):
            self.assertIn(word, check)
        self.assertRegex(check, r"no ip address, serial number, folder path, names? or photos")
        for s in self.sentences:
            low = s.lower()
            if "paste" in low and "summary.md" in low:
                self.assertRegex(low, NEGATION, f"SUMMARY.md must never be pasted anywhere: {s}")
        rules = self.section(r"^### Rules you never break", r"^### ").lower()
        self.assertRegex(rules, r"exception[^.]{0,80}share\.md")

    def test_stop_rule_without_a_backup_folder(self):
        check = self.section(r"^### The Home check", r"^### ")
        self.assertIn("backups/no-backup-<YYYY-MM-DD_HHMMSS>/", check)
        self.assertRegex(check.lower(), r"never[^.]{0,60}(repo root|top level of the project|project folder itself)")

    def test_phase5_decline_follows_the_stop_rule(self):
        check = self.section(r"^### The Home check", r"^### ").lower()
        self.assertRegex(check, r"--packages-only[^.]*\.[^.]{0,40}(declines|says no)[^.]{0,80}stop rule")

    def test_phase7_restart_is_gated_by_the_home_check(self):
        p7 = self.section(r"^## Phase 7", r"^---").lower()
        self.assertIn("do the home check first; only if it passes", p7)
        for s in re.split(r"(?<=[.!?])\s+", p7):
            if re.search(r"\brestart\b", s) and "ask them" in s:
                self.assertRegex(s, r"only if", f"Phase 7 restart without the Home check gate: {s}")

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
