"""fetch-tools tests that need a real (local) git repo, so they live outside refusal-cases.json.

The fixture is a temp git repo with tag v3.5.0. It never touches the network (FETCH_OFFLINE=1).
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

try:
    import script_cases as sc
except ImportError:
    from tests import script_cases as sc

GIT_ENV = {
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
}
PIN_DIFFERENT = "d11bd68c9ac45b2fb38480941586d17930137e9d"  # the real pin, which the fixture's tag is not at
MISSING_GIT_TOOLS = ("dirname", "uname", "tr", "rm", "mkdir", "cat", "sed")


def git(cwd, *args):
    env = dict(os.environ, **GIT_ENV)
    out = subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", *args],
                         cwd=cwd, env=env, capture_output=True, text=True, check=True)
    return out.stdout.strip()


class FetchToolsTests(unittest.TestCase):
    def setUp(self):
        if shutil.which("git") is None:
            self.skipTest("git is not installed")
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        src = self.tmp / "fixture src"
        src.mkdir()
        git(src, "init", "-q")
        (src / "a.txt").write_text("one\n")
        git(src, "add", "-A")
        git(src, "commit", "-q", "-m", "first")
        (src / "a.txt").write_text("two\n")
        git(src, "commit", "-q", "-am", "second")
        git(src, "tag", "v3.5.0")
        self.tag_commit = git(src, "rev-parse", "HEAD")
        self.url = src.as_uri()

    def make_repo(self, name):
        repo = self.tmp / name / "tv repo"  # a space in the path
        repo.mkdir(parents=True)
        for d in ("scripts", "config"):
            shutil.copytree(sc.ROOT / d, repo / d)
        return repo

    def run_impl(self, impl, repo, env_extra=None, path=None):
        ext, argv = sc.implementations()[impl]
        sc.require_shell(impl, argv)
        if argv is None:
            self.skipTest(f"{impl} is not installed")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CLEANYOURTV_", "FETCH_"))}
        env.update(GIT_ENV)
        env.update(CLEANYOURTV_URL=self.url, FETCH_OFFLINE="1")
        env.update(env_extra or {})
        if path is not None:
            for k in [k for k in env if k.upper() == "PATH"]:  # Windows spells it "Path"
                del env[k]
            env["PATH"] = path
        return subprocess.run(argv + [str(repo / "scripts" / ("fetch-tools" + ext))], cwd=repo, env=env,
                              capture_output=True, text=True, timeout=sc.TIMEOUT_SECS)

    def impls(self):
        return ("bash", "powershell")

    def test_F1_wrong_commit_is_refused_and_deleted(self):
        for impl in self.impls():
            with self.subTest(impl=impl):
                repo = self.make_repo("f1" + impl)
                p = self.run_impl(impl, repo)  # the pin in config/upstream.env is not the fixture's commit
                self.assertEqual(p.returncode, 30, p.stdout + p.stderr)
                self.assertFalse((repo / "vendor" / "cleanyourtv").exists())
                self.assertIn("pinned", p.stderr)

    def test_F2_matching_pin_succeeds_and_rerun_is_idempotent(self):
        for impl in self.impls():
            with self.subTest(impl=impl):
                repo = self.make_repo("f2" + impl)
                env = {"CLEANYOURTV_COMMIT": self.tag_commit}
                p = self.run_impl(impl, repo, env)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertEqual(git(repo / "vendor" / "cleanyourtv", "rev-parse", "HEAD"), self.tag_commit)
                p = self.run_impl(impl, repo, env)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_F3_missing_git_is_exit_3(self):
        for impl in self.impls():
            with self.subTest(impl=impl):
                repo = self.make_repo("f3" + impl)
                empty = self.tmp / ("nogit" + impl)
                empty.mkdir()
                if impl == "bash":  # the script still needs a few basic tools, just not git
                    for tool in MISSING_GIT_TOOLS:
                        found = shutil.which(tool)
                        if found:
                            (empty / tool).symlink_to(found)
                p = self.run_impl(impl, repo, path=str(empty))
                self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
                self.assertIn("Git", p.stderr)
                self.assertFalse((repo / "vendor").exists())

    def test_F4_existing_wrong_commit_is_deleted(self):
        for impl in self.impls():
            with self.subTest(impl=impl):
                repo = self.make_repo("f4" + impl)
                self.assertEqual(self.run_impl(impl, repo, {"CLEANYOURTV_COMMIT": self.tag_commit}).returncode, 0)
                p = self.run_impl(impl, repo, {"CLEANYOURTV_COMMIT": PIN_DIFFERENT})  # now the pin says otherwise
                self.assertEqual(p.returncode, 30, p.stdout + p.stderr)
                self.assertFalse((repo / "vendor" / "cleanyourtv").exists())

    def _tamper_case(self, tag, tamper):
        for impl in self.impls():
            with self.subTest(impl=impl):
                repo = self.make_repo(tag + impl)
                env = {"CLEANYOURTV_COMMIT": self.tag_commit}
                self.assertEqual(self.run_impl(impl, repo, env).returncode, 0)
                tamper(repo / "vendor" / "cleanyourtv")
                p = self.run_impl(impl, repo, env)
                self.assertEqual(p.returncode, 30, p.stdout + p.stderr)
                self.assertFalse((repo / "vendor" / "cleanyourtv").exists())

    def test_F7_edited_tracked_file_is_refused(self):
        self._tamper_case("f7", lambda v: (v / "a.txt").write_text("tampered\n"))

    def test_F8_untracked_file_is_refused(self):
        self._tamper_case("f8", lambda v: (v / "extra.py").write_text("print(1)\n"))

    def test_F5_unreachable_url_is_exit_3(self):
        for impl in self.impls():
            with self.subTest(impl=impl):
                repo = self.make_repo("f5" + impl)
                p = self.run_impl(impl, repo, {"CLEANYOURTV_URL": (self.tmp / "nope").as_uri()})
                self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
                self.assertFalse((repo / "vendor" / "cleanyourtv").exists())

    def test_F6_arguments_are_refused(self):
        repo = self.make_repo("f6")
        ext, argv = sc.implementations()["bash"]
        if argv is None:
            self.skipTest("bash is not installed")
        p = subprocess.run(argv + [str(repo / "scripts" / "fetch-tools.sh"), "x"], cwd=repo,
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 2)


if __name__ == "__main__":
    unittest.main()
