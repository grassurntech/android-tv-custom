"""Runs tests/refusal-cases.json against every available implementation of each script.

Each (case, implementation) pair is its own test method, so failures are named. An
implementation whose shell is not installed is skipped (reported as skipped, never
silently passed). With zero cases the module defines no tests and passes.

Case schema (see the plan): script, name, args, env (null = unset), files, tv, bin, expect.
"""
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FAKE_ADB = HERE / "fake_adb.py"
CASES_FILE = HERE / "refusal-cases.json"
IS_WINDOWS = os.name == "nt"
TIMEOUT_SECS = 60
CONFIG_ENV = ("TV_IP", "TV_ADB_PORT", "TV_BACKUP_DIR", "ADB")  # never inherited from the dev's shell


def find_bash():
    return None if IS_WINDOWS else shutil.which("bash")


def find_powershell():
    if IS_WINDOWS:
        return shutil.which("pwsh") or shutil.which("powershell")
    return shutil.which("pwsh")


def implementations():
    """name -> (extension, argv prefix) or None when not installed."""
    bash = find_bash()
    ps = find_powershell()
    ps_argv = None
    if ps:
        ps_argv = [ps, "-NoProfile"] + (["-ExecutionPolicy", "Bypass"] if IS_WINDOWS else []) + ["-File"]
    return {"bash": (".sh", [bash] if bash else None), "powershell": (".ps1", ps_argv)}


def write_shim(bindir, name, python_argv_line, stdout="", exit_code=None):
    """Create a command shim: POSIX sh (or .cmd on Windows). Stubs log to $FAKE_BIN_LOG."""
    if python_argv_line is not None:  # the adb shim
        if IS_WINDOWS:
            (bindir / f"{name}.cmd").write_text(f'@echo off\r\n{python_argv_line} %*\r\n', newline="")
        else:
            path = bindir / name
            path.write_text(f'#!/bin/sh\nexec {python_argv_line} "$@"\n')
            path.chmod(0o755)
        return
    out = bindir / f"{name}.out"
    out.write_text(stdout)
    if IS_WINDOWS:
        (bindir / f"{name}.cmd").write_text(
            f'@echo off\r\necho {name} %* >>"%FAKE_BIN_LOG%"\r\ntype "{out}"\r\nexit /b {exit_code}\r\n', newline="")
    else:
        path = bindir / name
        path.write_text(f'#!/bin/sh\necho "{name} $*" >> "$FAKE_BIN_LOG"\ncat {shlex.quote(str(out))}\nexit {exit_code}\n')
        path.chmod(0o755)


def read_lines(path):
    return path.read_text().splitlines() if path.exists() else []


def run_case(case, impl_name, ext, argv_prefix, tmp):
    """Run one case; returns (CompletedProcess, adb_lines, bin_lines, repo_dir)."""
    tmp = Path(tmp)
    repo = tmp / "tv repo"
    repo.mkdir()
    for d in ("scripts", "config"):
        if (ROOT / d).is_dir():
            shutil.copytree(ROOT / d, repo / d)
        else:
            (repo / d).mkdir()
    for rel, text in case.get("files", {}).items():
        target = repo / rel
        if text is None:  # null removes a file copied from the repo (e.g. a config list)
            target.unlink()
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8", newline="\n")
        if rel.endswith(".sh"):
            target.chmod(target.stat().st_mode | 0o111)

    bindir = tmp / "fake bin" / "shims"  # a space in the path catches unquoted $ADB
    bindir.mkdir(parents=True)
    write_shim(bindir, "adb", f'"{sys.executable}" "{FAKE_ADB}"')
    for name, spec in case.get("bin", {}).items():
        write_shim(bindir, name, None, spec.get("stdout", ""), spec.get("exit", 0))

    state_file, adb_log, bin_log = tmp / "state.json", tmp / "adb.log", tmp / "bin.log"
    state_file.write_text(json.dumps(case.get("tv", {})))
    adb_log.write_text("")
    bin_log.write_text("")

    env = {k: v for k, v in os.environ.items() if k not in CONFIG_ENV}
    env["PATH"] = str(bindir) + os.pathsep + env.get("PATH", "")
    env["ADB"] = str(bindir / ("adb.cmd" if IS_WINDOWS else "adb"))
    env.update(FAKE_ADB_STATE=str(state_file), FAKE_ADB_LOG=str(adb_log), FAKE_BIN_LOG=str(bin_log))
    for k, v in case.get("env", {}).items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v

    script = repo / "scripts" / (case["script"] + ext)
    proc = subprocess.run(argv_prefix + [str(script)] + list(case.get("args", [])), cwd=repo, env=env,
                          capture_output=True, text=True, timeout=TIMEOUT_SECS)
    return proc, read_lines(adb_log), read_lines(bin_log), repo


def _matches(repo, rel):
    """A path under the repo; '*' globs (for timestamped folders)."""
    return sorted(repo.glob(rel)) if "*" in rel else ([repo / rel] if (repo / rel).exists() else [])


def _resolve(repo, rel):
    found = _matches(repo, rel)
    return found[0] if found else repo / rel


def check_expect(test, expect, proc, adb_lines, bin_lines, repo):
    ctx = (f"\nexit={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\n"
           f"adb calls:\n" + "\n".join(adb_lines) + "\nbin calls:\n" + "\n".join(bin_lines))
    if "exit" in expect:
        test.assertEqual(proc.returncode, expect["exit"], ctx)
    for sub in expect.get("adb_calls_include", []):
        test.assertTrue(any(sub in l for l in adb_lines), f"no adb call contains {sub!r}{ctx}")
    for sub in expect.get("adb_calls_exclude", []):
        test.assertFalse(any(sub in l for l in adb_lines), f"an adb call contains {sub!r}{ctx}")
    pos = 0  # each substring must appear on a later call than the one before it
    for sub in expect.get("adb_calls_in_order", []):
        idx = next((i for i in range(pos, len(adb_lines)) if sub in adb_lines[i]), None)
        test.assertIsNotNone(idx, f"adb call {sub!r} missing or out of order{ctx}")
        pos = idx + 1
    for sub, n in expect.get("adb_call_count", {}).items():
        got = sum(1 for l in adb_lines if sub in l)
        test.assertEqual(got, n, f"adb calls containing {sub!r}: {got}, expected {n}{ctx}")
    for sub in expect.get("bin_calls_include", []):
        test.assertTrue(any(sub in l for l in bin_lines), f"no stub call contains {sub!r}{ctx}")
    for rel, wanted in expect.get("files_contain", {}).items():
        path = _resolve(repo, rel)
        test.assertTrue(path.exists(), f"{rel} was not written{ctx}")
        have = [l.rstrip("\r") for l in path.read_text().splitlines()]
        for line in wanted:
            test.assertIn(line, have, f"{rel} lacks line {line!r}{ctx}")
    for rel, pattern in expect.get("files_match", {}).items():
        path = _resolve(repo, rel)
        test.assertTrue(path.exists(), f"{rel} was not written{ctx}")
        # exact bytes: UTF-8 without BOM, LF endings; the whole file must match
        test.assertRegex(path.read_bytes().decode("utf-8"), "^(?:" + pattern + ")\\Z", f"{rel} content is wrong{ctx}")
    for rel in expect.get("files_absent", []):
        test.assertEqual(_matches(repo, rel), [], f"{rel} exists but should not{ctx}")
    if "stdout_last_line_matches" in expect:
        lines = [l for l in proc.stdout.splitlines() if l.strip()]
        test.assertTrue(lines, f"no stdout{ctx}")
        test.assertRegex(lines[-1].strip(), expect["stdout_last_line_matches"], ctx)
        test.assertTrue(Path(lines[-1].strip()).is_dir(), f"last stdout line is not an existing folder{ctx}")
    if "stderr_contains" in expect:
        test.assertIn(expect["stderr_contains"], proc.stderr, ctx)


def load_cases():
    return json.loads(CASES_FILE.read_text())


class ScriptCases(unittest.TestCase):
    """Test methods are generated below, one per (case, implementation)."""


def _make_test(case, impl_name):
    def test(self):
        ext, argv_prefix = implementations()[impl_name]
        if argv_prefix is None:
            self.skipTest(f"{impl_name} is not installed")
        with tempfile.TemporaryDirectory() as tmp:
            proc, adb_lines, bin_lines, repo = run_case(case, impl_name, ext, argv_prefix, tmp)
            check_expect(self, case["expect"], proc, adb_lines, bin_lines, repo)
    return test


def _safe(text):
    return "".join(c if c.isalnum() else "_" for c in text)


for _i, _case in enumerate(load_cases()):
    for _impl in ("bash", "powershell"):
        _name = f"test_{_i:03d}_{_safe(_case['script'])}_{_safe(_case['name'])}__{_impl}"
        setattr(ScriptCases, _name, _make_test(_case, _impl))
