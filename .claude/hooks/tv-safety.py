#!/usr/bin/env python3
"""
TV safety guardrail: a Claude Code PreToolUse hook for the Bash and PowerShell tools.

It blocks commands that could change a user's TV in a way `pm enable` can't undo,
touch protected packages, open factory/service menus, read `.env`, skip git hooks,
or send user content (photos, backups, screenshots) off the computer.
See "Rule: TV safety" in CLAUDE.md.

How it works
  1. A small bash-like lexer splits the command into simple commands. It removes
     quotes the way the shell does, splits only on unquoted ; & && || | and newlines,
     reads heredoc bodies, and parses $( ), backticks and <( ) recursively.
  2. Each host command has its prefixes stripped (sudo, env, timeout, nohup, ...)
     and is checked by name: adb, fastboot, git, upload tools, interpreters.
  3. For `adb shell` / `adb exec-out` the device-side text is lexed again and every
     device command must be on an ALLOWLIST (see DEVICE_* below).
  4. Fail closed: if a command mentions adb/pm/am/cmd/fastboot/su and uses
     something that can't be read statically (eval, sh -c, $VAR as a command,
     piping into a shell, running a script it can't see), it is blocked.

Our own scripts (bash scripts/*.sh, pwsh scripts/*.ps1, files under tests/) are allowed
when git tracks them and they match HEAD; they enforce the same rules themselves. New or
edited files there get the same content check as any other script.

Exit 2 = block (stderr is shown to Claude). Exit 0 = allow. Any error = exit 2.
"""
import fnmatch
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get("CLAUDE_PROJECT_DIR") or Path(__file__).resolve().parents[2])
BACKUP_DIR = ROOT / os.environ.get("TV_BACKUP_DIR", "backups")
BACKUP_NAME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{6}$")
PKG_RE = r"[a-z][\w]*(?:\.[\w]+)+"
PRIVATE_DIRS = {"photos", "backups", "screenshots", "user-content"}
MAX_DEPTH = 8


class Blocked(Exception):
    pass


def block(reason):
    raise Blocked(reason)


# ── Config lists ──────────────────────────────────────────────────────────────

def load_patterns(name):
    """Same parsing as the scripts: BOM stripped, any line ending, first token, cut at '#'."""
    path = ROOT / "config" / name
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")) or b"\x00" in raw:
        return None
    text = raw.decode("utf-8", errors="replace").lstrip("﻿")
    out = []
    for line in re.split(r"\r\n|\r|\n", text):
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        tok = parts[0].split("#", 1)[0].strip().lower()
        if tok:
            out.append(tok)
    return out or None


def matches(pkg, patterns):
    return any(fnmatch.fnmatch(pkg.lower(), p) for p in patterns)


# ── Lexer ─────────────────────────────────────────────────────────────────────

class Word:
    def __init__(self, text, expanded=False, quoted=False, glob=False):
        self.text = text          # value after quote removal ($VAR etc. kept verbatim)
        self.expanded = expanded  # contains $VAR, $( ), backticks: not statically known
        self.quoted = quoted
        self.glob = glob          # has an UNQUOTED * ? [ (quoted text is never globbed)

    def __repr__(self):
        return f"Word({self.text!r}{', exp' if self.expanded else ''})"


class Command:
    def __init__(self):
        self.words = []
        self.redirs = []          # (op, Word)
        self.stdin = []           # heredoc bodies and here-strings
        self.piped_in = False
        self.func_def = False


class Script:
    def __init__(self):
        self.commands = []
        self.subs = []            # nested Scripts from $( ), backticks, <( )


SEPARATORS = (";;", ";&", "&&", "||", "|&", ";", "&", "|", "\n")
REDIR_OPS = ("<<<", "<<-", "&>>", "<<", ">>", ">&", "<&", ">|", "<>", "&>", "<", ">")


class Lexer:
    def __init__(self, src, pwsh=False, depth=0):
        self.src, self.n, self.pwsh, self.depth = src, len(src), pwsh, depth
        if depth > MAX_DEPTH:
            block("command is nested too deeply to check.")

    def parse(self, i=0, stop_at_paren=False):
        """Lex from i. Returns (Script, end_index). Stops at an unmatched ')' if asked."""
        s, src, n = Script(), self.src, self.n
        cmd, buf = Command(), None
        pending_redir, heredocs, paren = None, [], 0
        esc = "`" if self.pwsh else "\\"

        def new_buf():
            return {"chars": [], "exp": False, "quoted": False, "glob": False}

        def finish_word():
            nonlocal buf, pending_redir
            if buf is None:
                return
            w = Word("".join(buf["chars"]), buf["exp"], buf["quoted"], buf["glob"])
            buf = None
            if pending_redir:
                op, pending_redir = pending_redir, None
                if op in ("<<", "<<-"):
                    heredocs.append((cmd, w.text, op == "<<-"))
                elif op == "<<<":
                    cmd.stdin.append(w.text)
                cmd.redirs.append((op, w))
            else:
                cmd.words.append(w)

        def end_command(op):
            nonlocal cmd
            finish_word()
            if cmd.words or cmd.redirs or cmd.func_def:
                s.commands.append(cmd)
            nxt = Command()
            nxt.piped_in = op in ("|", "|&")
            cmd = nxt

        def read_heredocs(i):
            for hcmd, delim, strip in heredocs:
                body = []
                while i < n:
                    j = src.find("\n", i)
                    line = src[i:] if j < 0 else src[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    body.append(line)
                hcmd.stdin.append("\n".join(body))
            heredocs.clear()
            return i

        while i < n:
            c = src[i]
            # escapes / line continuation
            if c == esc:
                if i + 1 < n and src[i + 1] == "\n":
                    i += 2
                    continue
                buf = buf or new_buf()
                if i + 1 < n:
                    buf["chars"].append(src[i + 1])
                buf["quoted"] = True
                i += 2
                continue
            if c in " \t\r":
                finish_word()
                i += 1
                continue
            if c == "#" and buf is None:
                while i < n and src[i] != "\n":
                    i += 1
                continue
            if c == "'":
                buf = buf or new_buf()
                j = src.find("'", i + 1)
                j = n if j < 0 else j
                buf["chars"].append(src[i + 1:j])
                buf["quoted"] = True
                i = j + 1
                continue
            if c == '"':
                buf = buf or new_buf()
                buf["quoted"] = True
                i = self._double_quoted(i + 1, buf, s)
                continue
            if c == "$":
                buf = buf or new_buf()
                i = self._dollar(i, buf, s)
                continue
            if c == "`" and not self.pwsh:
                buf = buf or new_buf()
                i = self._backtick(i, buf, s)
                continue
            if c in "<>" and i + 1 < n and src[i + 1] == "(":
                # process substitution <( ) / >( )
                finish_word()
                sub, end = Lexer(src, self.pwsh, self.depth + 1).parse(i + 2, stop_at_paren=True)
                s.subs.append(sub)
                cmd.words.append(Word(src[i:end + 1], expanded=True))
                i = end + 1
                continue
            if c == "(":
                if buf is not None and "".join(buf["chars"]).endswith("="):
                    # array assignment a=( ... )
                    j = src.find(")", i)
                    j = n if j < 0 else j
                    buf["chars"].append(src[i:j + 1])
                    i = j + 1
                    continue
                if buf is not None or cmd.words:
                    finish_word()
                    cmd.func_def = True       # name() { ... }: the body is lexed as normal commands
                    k = src.find(")", i)
                    i = n if k < 0 else k + 1
                    end_command(";")
                    continue
                end_command("(")
                paren += 1
                i += 1
                continue
            if c == ")":
                end_command(")")
                if paren == 0 and stop_at_paren:
                    return s, i
                paren = max(0, paren - 1)
                i += 1
                continue
            # redirections (with an optional fd number in front)
            if c in "<>" or (c == "&" and i + 1 < n and src[i + 1] == ">"):
                if buf is not None and "".join(buf["chars"]).isdigit() and not buf["quoted"]:
                    buf = None
                finish_word()
                op = next(o for o in REDIR_OPS if src.startswith(o, i))
                pending_redir = op
                i += len(op)
                continue
            sep = next((o for o in SEPARATORS if src.startswith(o, i)), None)
            if sep:
                end_command(sep)
                i += len(sep)
                if sep == "\n" and heredocs:
                    i = read_heredocs(i)
                continue
            buf = buf or new_buf()
            buf["chars"].append(c)
            buf["glob"] = buf["glob"] or c in "*?["
            i += 1
        end_command(None)
        return s, n

    def _double_quoted(self, i, buf, s):
        src, n = self.src, self.n
        esc = "`" if self.pwsh else "\\"
        while i < n and src[i] != '"':
            c = src[i]
            if c == esc and i + 1 < n:
                nxt = src[i + 1]
                if self.pwsh or nxt in '$`"\\\n':
                    if nxt != "\n":
                        buf["chars"].append(nxt)
                    i += 2
                    continue
                buf["chars"].append(c)
                i += 1
                continue
            if c == "$":
                i = self._dollar(i, buf, s)
                continue
            if c == "`" and not self.pwsh:
                i = self._backtick(i, buf, s)
                continue
            buf["chars"].append(c)
            i += 1
        return i + 1

    def _dollar(self, i, buf, s):
        src, n = self.src, self.n
        buf["exp"] = True
        if src.startswith("$((", i):
            j = src.find("))", i)
            j = n if j < 0 else j + 2
            buf["chars"].append(src[i:j])
            return j
        if src.startswith("$(", i):
            sub, end = Lexer(src, self.pwsh, self.depth + 1).parse(i + 2, stop_at_paren=True)
            s.subs.append(sub)
            buf["chars"].append(src[i:end + 1])
            return end + 1
        if src.startswith("${", i):
            j = src.find("}", i)
            j = n if j < 0 else j + 1
            buf["chars"].append(src[i:j])
            return j
        if src.startswith("$'", i) or src.startswith('$"', i):
            q = src[i + 1]
            j = src.find(q, i + 2)
            j = n if j < 0 else j
            buf["chars"].append(src[i + 2:j])     # ANSI-C text: kept raw, marked unresolved
            return j + 1
        m = re.match(r"\$([A-Za-z_][\w:]*|[0-9@*#?$!-])", src[i:])
        if m:
            buf["chars"].append(m.group(0))
            return i + len(m.group(0))
        buf["exp"] = False
        buf["chars"].append("$")
        return i + 1

    def _backtick(self, i, buf, s):
        src, n = self.src, self.n
        j = i + 1
        while j < n and src[j] != "`":
            j += 2 if src[j] == "\\" else 1
        inner = src[i + 1:min(j, n)]
        s.subs.append(Lexer(inner, self.pwsh, self.depth + 1).parse()[0])
        buf["exp"] = True
        buf["chars"].append(src[i:j + 1])
        return j + 1


def lex(text, pwsh=False, depth=0):
    return Lexer(text, pwsh, depth).parse()[0]


# ── Helpers ───────────────────────────────────────────────────────────────────

def cmd_name(text):
    name = re.split(r"[/\\]", text)[-1].lower()
    return name[:-4] if name.endswith(".exe") else name


def is_assignment(text):
    return re.match(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=", text) is not None


def has_glob(text):
    return any(c in text for c in "*?[")


# `.env` used as a file inside code or a script: quoted or path-like ('.env', "./.env", x/.env),
# or after a reading command. Prose such as "set it in .env" does not match.
ENV_FILE_RE = re.compile(
    r"([\"'/]|\b(?:cat|source|less|more|head|tail|cp|mv|scp|base64|xxd|strings|\.)\s+\S*?)"
    r"\.env(?!\.example\b)(?![\w-])")


def mentions_env_file(text, globs=True):
    """True if `text` names .env (or .env.local etc.). Glob patterns count only when `globs`
    is set, i.e. the word had an unquoted * ? [ that the shell would expand."""
    for piece in re.split(r"[\s=@:,;'\"<>|()]+", text):
        base = re.split(r"[/\\]", piece)[-1]
        if base == ".env" or (base.startswith(".env.") and base != ".env.example"):
            return True
        # Globs: only ones that name it (.env*, .e*, *.env). Plain `*` skips dotfiles in the shell.
        if (globs and has_glob(base) and (base.startswith(".") or "env" in base.lower())
                and fnmatch.fnmatch(".env", base)):
            return True
    return False


def refs_private(text):
    low = text.lower()
    if "tv_backup_dir" in low:
        return True
    if os.path.isabs(str(BACKUP_DIR)) and str(BACKUP_DIR).lower().rstrip("/") in low:
        return True
    for piece in re.split(r"[\s=@,;]+|:(?!//)", low):
        for comp in re.split(r"[/\\]", piece):
            if comp in PRIVATE_DIRS:
                return True
            if has_glob(comp) and any(fnmatch.fnmatch(p, comp) for p in PRIVATE_DIRS):
                return True
    return False


def flatten(cmd):
    """Raw text with quotes and backslashes removed, so p"m" reads as pm."""
    return re.sub(r"[\"'\\`]", "", re.sub(r"\\\n", "", cmd))


SENSITIVE_RE = re.compile(
    r"(?<![\w.-])(adb(\.exe)?|fastboot)(?![\w-])"
    r"|(?<![\w.-])pm\s+(list|path|dump|enable|disable[\w-]*|uninstall[\w-]*|install[\w-]*|clear|hide|"
    r"unhide|suspend|unsuspend|grant|revoke|reset-permissions|set-[\w-]+|archive|trim-caches|compile|"
    r"default-state|create-user|remove-user|resolve-activity|query-[\w-]+)\b"
    r"|(?<![\w.-])am\s+(start[\w-]*|force-stop|crash|broadcast|kill[\w-]*|instrument|stop-app|"
    r"set-[\w-]+|switch-user|monitor)\b"
    r"|(?<![\w.-])cmd\s+(package|activity|overlay|input_method|bluetooth_manager|role|appops|wifi|"
    r"settings|statusbar|device_policy|connectivity|power|deviceidle|user|notification|uimode|"
    r"display|window|hdmi_control|tv_input|-l)\b"
    r"|(?<![\w.-])su\s+(-|root\b|0\b|shell\b)"
    r"|(?<![\w.-])(monkey|dpm|appops|setprop|svc)\s",
    re.I)

FAIL_CLOSED_MSG = ("can't check this statically ({what}) and the command mentions adb/pm/am/cmd/fastboot/su. "
                   "Run each TV command directly as one literal `adb ...` call, or use scripts/*.sh.")


# ── Context shared across one hook call ───────────────────────────────────────

class Ctx:
    def __init__(self, raw, pwsh):
        self.pwsh = pwsh
        self.sensitive = bool(SENSITIVE_RE.search(flatten(raw)))
        self.disable_count = 0
        self.loop = False
        self.upload = False
        self.private_ref = False
        self.written = set()
        self.digit_keys = 0
        self.settings_key = False
        self._lists = None

    def lists(self):
        if self._lists is None:
            lists = tuple(load_patterns(f) for f in
                          ("protected-packages.txt", "forbidden-packages.txt", "streaming-apps.txt"))
            if any(x is None for x in lists):
                block("config/protected-packages.txt, forbidden-packages.txt or streaming-apps.txt is "
                      "missing or unreadable, so TV commands can't be checked.")
            self._lists = lists
        return self._lists

    def opaque(self, what):
        if self.sensitive:
            block(FAIL_CLOSED_MSG.format(what=what))


# ── Prefix stripping (sudo, env, timeout, if/while, ...) ──────────────────────

# wrapper -> (options that take a value, number of positionals to skip)
WRAPPERS = {
    "command": (set(), 0), "builtin": (set(), 0), "exec": ({"-a"}, 0), "nohup": (set(), 0),
    "time": (set(), 0), "nice": ({"-n", "--adjustment"}, 0), "stdbuf": ({"-i", "-o", "-e"}, 0),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, 1),
    "sudo": ({"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R"}, 0),
    "doas": ({"-u", "-C"}, 0), "env": ({"-u", "--unset", "-C", "--chdir"}, 0),
    "caffeinate": ({"-t", "-w"}, 0), "ionice": ({"-c", "-n", "-p"}, 0),
}
KEYWORDS = {"if", "then", "else", "elif", "do", "!", "{", "}", "fi", "done", "esac", "in"}
LOOP_KEYWORDS = {"while", "until"}
LOOP_HEADERS = {"for", "select", "case"}
BATCH_WRAPPERS = {"xargs": {"-n", "-L", "-l", "-P", "-s", "-I", "-d", "-E", "-a", "--max-args",
                            "--max-procs", "--delimiter", "--arg-file", "--replace"},
                  "parallel": {"-j", "--jobs", "-S", "--sshlogin"},
                  "watch": {"-n", "--interval", "-d"}}


def skip_options(words, i, value_opts, stop_at_positional=True):
    while i < len(words):
        t = words[i].text
        if t == "--":
            return i + 1
        if not t.startswith("-") or t == "-":
            return i
        base = t.split("=", 1)[0]
        i += 1
        if base in value_opts and "=" not in t:
            i += 1  # value in the next word; attached forms (-n1, --opt=x) need no skip
    return i


def strip_prefixes(words, ctx, device=False):
    """Returns (words, batch) with wrappers removed. batch=True if run once per input item."""
    batch = False
    while words:
        t = words[0].text
        low = t.lower()
        if is_assignment(t):
            if "hookspath" in low:
                block("don't change git's hooks path; the pre-commit secret check must stay on.")
            words = words[1:]
            continue
        if low in KEYWORDS:
            words = words[1:]
            continue
        if low in LOOP_KEYWORDS:
            if device:
                block("no loops on the TV. One literal command per call.")
            ctx.loop = True
            words = words[1:]
            continue
        if low in LOOP_HEADERS:
            if device:
                block("no loops on the TV. One literal command per call.")
            if low != "case":
                ctx.loop = True
            return [], batch
        if low == "function":
            ctx.opaque("function definition")
            return [], batch
        name = cmd_name(t)
        if name in WRAPPERS and not device:
            if name == "command" and any(w.text in ("-v", "-V") for w in words[1:3]):
                return [], batch
            if name == "env" and any(w.text.startswith(("-S", "--split-string")) for w in words[1:]):
                ctx.opaque("env -S")
            opts, positional = WRAPPERS[name]
            i = skip_options(words, 1, opts)
            if name == "env":
                while i < len(words) and is_assignment(words[i].text):
                    i += 1
            i = min(i + positional, len(words))
            words = words[i:]
            continue
        if name in ("exec", "command", "nohup", "time", "nice") and device:
            words = words[1:]
            continue
        if name in BATCH_WRAPPERS and not device:
            i = skip_options(words, 1, BATCH_WRAPPERS[name])
            rest = words[i:]
            if name == "parallel":
                cut = next((k for k, w in enumerate(rest) if w.text in (":::", "::::")), len(rest))
                rest = rest[:cut]
            if name == "watch":
                ctx.opaque("watch runs its command through sh -c")
            words, batch = rest, True
            continue
        break
    return words, batch


# ── Host-side checks ──────────────────────────────────────────────────────────

TEXT_OPTS = {"-m", "--message", "--title", "-t", "--body", "-b", "--notes", "--subject"}
UPLOAD_TOOLS = {"curl", "wget", "scp", "rsync", "sftp", "ftp", "gh", "aws", "gsutil", "rclone",
                "nc", "ncat", "netcat", "socat", "ssh", "telnet", "lftp", "s3cmd", "az", "gcloud"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "busybox"}
INTERPRETERS = SHELLS | {"python", "python2", "python3", "node", "deno", "bun", "perl", "ruby", "php",
                         "pwsh", "powershell", "osascript", "lua", "tclsh", "awk", "gawk", "mawk",
                         "nawk", "expect", "su", "eval", "source", ".", "alias", "iex",
                         "invoke-expression", "start-process", "invoke-command", "icm", "saps",
                         "script", "tmux", "screen", "ssh", "make", "npx", "npm", "osascript"}
SCRIPT_EXTS = (".sh", ".bash", ".zsh", ".py", ".js", ".mjs", ".pl", ".rb", ".ps1", ".php", ".lua")


def text_option_values(name, words):
    """Indexes of words that are free text (commit messages, PR titles), not file arguments."""
    skip = set()
    if name not in ("git", "gh"):
        return skip
    for k, w in enumerate(words):
        t = w.text
        if t in TEXT_OPTS and k + 1 < len(words):
            skip.add(k + 1)
        elif t.startswith(("--message=", "--title=", "--body=", "--notes=")):
            skip.add(k)
        elif name == "git" and re.fullmatch(r"-[a-zA-Z]*m", t) and k + 1 < len(words):
            skip.add(k + 1)
        elif name == "git" and re.match(r"^-[a-zA-Z]*m.+", t):
            skip.add(k)
    return skip


_GIT_CLEAN = {}


def git_clean(rel):
    """True only if git tracks `rel` and it matches HEAD. Any git problem counts as not clean."""
    if rel not in _GIT_CLEAN:
        def git(*a):
            return subprocess.run(["git", "-C", str(ROOT), *a], capture_output=True, timeout=10).returncode
        try:
            _GIT_CLEAN[rel] = (git("ls-files", "--error-unmatch", "--", rel) == 0
                               and git("diff", "--quiet", "HEAD", "--", rel) == 0)
        except (OSError, subprocess.SubprocessError):
            _GIT_CLEAN[rel] = False
    return _GIT_CLEAN[rel]


def repo_script(text):
    """True for one of our own committed scripts or tests (they enforce the rules themselves).

    The file must sit under scripts/ or tests/, be tracked by git and match HEAD. A file that
    is new or edited there (for example written by the Write tool, which this hook never sees)
    gets the same content check as any other script.
    """
    p = text.replace("\\", "/")
    if os.path.isabs(p):
        try:
            p = str(Path(p).resolve().relative_to(ROOT.resolve()))
        except (ValueError, OSError):
            return False
    while p.startswith("./"):
        p = p[2:]
    if not p.startswith(("scripts/", "tests/")) or ".." in p.split("/"):
        return False
    return git_clean(p)


def file_is_sensitive(path_text):
    """Peek at a script file Claude asks to run, to catch write-then-run across calls."""
    base = re.split(r"[/\\]", path_text)[-1]
    if base.startswith(".env") or refs_private(path_text):
        return False
    p = Path(path_text) if os.path.isabs(path_text) else ROOT / path_text
    try:
        if not p.is_file() or p.stat().st_size > 1_000_000:
            return False
        data = p.read_bytes()
    except OSError:
        return False
    if not (data.startswith(b"#!") or base.lower().endswith(SCRIPT_EXTS)):
        return False
    text = flatten(data.decode("utf-8", errors="ignore"))
    return bool(SENSITIVE_RE.search(text) or ENV_FILE_RE.search(text))


def analyse_script(script, ctx, depth=0):
    if depth > MAX_DEPTH:
        block("command is nested too deeply to check.")
    for cmd in script.commands:
        analyse_host_command(cmd, ctx)
    for sub in script.subs:
        analyse_script(sub, ctx, depth + 1)


def analyse_host_command(cmd, ctx, batch=False):
    if cmd.func_def:
        ctx.opaque("function definition")
    for op, target in cmd.redirs:
        if op in ("<<", "<<-", "<<<"):
            continue
        if mentions_env_file(target.text, target.glob):
            block("never read or write `.env`. It holds this user's secrets.")
        if refs_private(target.text):
            ctx.private_ref = True
        if op in (">", ">>", ">|", "&>", "&>>"):
            ctx.written.add(target.text)

    for w in cmd.words:
        if is_assignment(w.text) and refs_private(w.text):
            ctx.private_ref = True
    words, wrapped = strip_prefixes(cmd.words, ctx)
    batch = batch or wrapped
    if not words:
        return
    first = words[0]
    name = cmd_name(first.text)
    args = words[1:]

    if first.expanded:
        ctx.opaque("a variable or $( ) as the command name")

    # .env and private-folder references (skip free-text options like commit messages)
    skip = text_option_values(name, args)
    for k, w in enumerate(args):
        if k in skip:
            continue
        if (name not in ("echo", "printf") and not w.text.startswith("--exclude")
                and mentions_env_file(w.text, w.glob)):
            block("never read or write `.env`. It holds this user's secrets.")
        if "://" not in w.text and refs_private(w.text):
            ctx.private_ref = True
    if mentions_env_file(first.text, first.glob):
        block("never read or write `.env`. It holds this user's secrets.")
    if name in ("grep", "egrep", "fgrep", "rg") and recursive_over_root(name, args):
        block("a recursive search of the whole project would read `.env`. Search a subfolder, "
              "add --exclude=.env, or use `git grep` (it skips untracked files like .env).")

    if name == "adb":
        check_adb(args, cmd, ctx, batch)
    elif name == "fastboot":
        block("no flashing: fastboot is forbidden.")
    elif name == "git":
        check_git(args, ctx)
    elif name == "find":
        check_find(args, cmd, ctx)
    elif name in UPLOAD_TOOLS or (name.startswith("python") and _module(args) == "http.server"):
        ctx.upload = True
        if name in INTERPRETERS:
            check_interpreter(name, args, cmd, ctx)
    elif name in INTERPRETERS or re.fullmatch(r"python\d[\d.]*", name):
        check_interpreter(name, args, cmd, ctx)
    elif ("/" in first.text or "\\" in first.text) and not repo_script(first.text):
        if file_is_sensitive(first.text):
            block(FAIL_CLOSED_MSG.format(what=f"`{first.text}` is a script that drives the TV or reads .env"))
        ctx.opaque(f"running `{first.text}`, which this hook can't read")
    elif repo_script(first.text) and first.text in ctx.written:
        ctx.opaque("writing a script and running it in the same call")


def recursive_over_root(name, args):
    """grep -r (or rg --hidden) over the project root, without excluding .env."""
    texts = [w.text for w in args]
    if name == "rg":
        recursive = any(t in ("--hidden", "-uu", "-uuu", "--no-ignore") for t in texts)
    else:
        recursive = any(t in ("--recursive", "--dereference-recursive")
                        or re.fullmatch(r"-[a-zA-Z]*[rR][a-zA-Z]*", t) for t in texts)
    if not recursive:
        return False
    if any(re.match(r"--exclude=['\"]?(\.env|\.\*|\*\.env|\.env\*)", t) or t in ("-g", "--glob")
           for t in texts):
        return False
    roots = {".", "./", "*", ".*", str(ROOT), str(ROOT) + "/"}
    pattern_opts = ("-e", "-f", "--regexp", "--file")
    positional = [t for k, t in enumerate(texts)
                  if not t.startswith("-") and not (k and texts[k - 1] in pattern_opts)]
    paths = positional if any(t in pattern_opts for t in texts) else positional[1:]
    return not paths or any(p in roots for p in paths)


def _module(args):
    for k, w in enumerate(args):
        if w.text == "-m" and k + 1 < len(args):
            return args[k + 1].text
    return None


def check_interpreter(name, args, cmd, ctx):
    """A shell or language runtime. Fine for our own scripts; opaque otherwise."""
    if any(ENV_FILE_RE.search(body) for body in cmd.stdin):
        block("never read or write `.env`. It holds this user's secrets.")
    if name in ("source", "."):
        target = args[0].text if args else ""
        if repo_script(target) and target not in ctx.written:
            return
        if target and file_is_sensitive(target):
            block(FAIL_CLOSED_MSG.format(what=f"sourcing `{target}`"))
        ctx.opaque(f"sourcing `{target}`")
        return
    if name.startswith("python") and _module(args) and not cmd.stdin and not cmd.piped_in:
        return  # python -m <module>
    inline = {"-c", "-e", "-E", "-p", "-r", "--eval", "--print", "-command", "-encodedcommand", "-ec",
              "-enc", "/c"}
    positional = None
    for k, w in enumerate(args):
        t = w.text
        if t.lower() in inline or (name in SHELLS and re.fullmatch(r"-[a-z]*c[a-z]*", t)):
            ctx.opaque(f"`{name} {t}` inline code")
            return
        if t.lower() in ("-file", "-f") and name in ("pwsh", "powershell") and k + 1 < len(args):
            positional = args[k + 1]
            break
        if not t.startswith("-"):
            positional = w
            break
    if name in ("awk", "gawk", "mawk", "nawk", "eval", "alias", "iex", "invoke-expression",
                "start-process", "invoke-command", "icm", "saps", "script", "tmux", "screen", "ssh",
                "su", "make", "npx", "npm", "expect"):
        ctx.opaque(f"`{name}`")
        return
    if positional is None or positional.text == "-":
        if cmd.stdin or cmd.piped_in or positional is not None:
            ctx.opaque(f"code fed to `{name}` on stdin")
        return
    if positional.expanded:
        ctx.opaque(f"`{name}` running a path held in a variable")
        return
    if repo_script(positional.text) and positional.text not in ctx.written:
        return
    if file_is_sensitive(positional.text):
        block(FAIL_CLOSED_MSG.format(what=f"`{name} {positional.text}` runs a script that drives the TV"))
    if positional.text in ctx.written:
        ctx.opaque(f"`{name} {positional.text}` runs a script written in the same call")
    ctx.opaque(f"`{name} {positional.text}`")


def check_find(args, cmd, ctx):
    k = 0
    while k < len(args):
        if args[k].text in ("-exec", "-execdir", "-ok", "-okdir"):
            j = k + 1
            while j < len(args) and args[j].text not in (";", "+"):
                j += 1
            inner = Command()
            inner.words = args[k + 1:j]
            analyse_host_command(inner, ctx, batch=True)
            k = j
        k += 1


def check_git(args, ctx):
    k = 0
    while k < len(args) and args[k].text.startswith("-"):
        t = args[k].text
        val = None
        if t in ("-c", "--config-env") and k + 1 < len(args):
            val = args[k + 1].text
            k += 1
        elif t.startswith(("-c", "--config-env=")) and len(t) > 2:
            val = t.split("=", 1)[1] if t.startswith("--") else t[2:]
        elif t in ("-C", "--git-dir", "--work-tree", "--namespace") and k + 1 < len(args):
            k += 1
        if val is not None:
            low = val.lower()
            if "core.hookspath" in low:
                block("don't change git's hooks path; the pre-commit secret check must stay on.")
            if low.startswith("alias.") and "=!" in low:
                ctx.opaque("a git alias that runs a shell command")
        k += 1
    if k >= len(args):
        return
    sub, rest = args[k].text, args[k + 1:]
    skip = text_option_values("git", rest)
    flags = [w.text for i, w in enumerate(rest) if i not in skip]
    if "--no-verify" in flags:
        block("never skip git hooks (--no-verify). The pre-commit check keeps secrets and photos out.")
    if sub == "commit":
        for f in flags:
            if re.fullmatch(r"-[a-zA-Z]+", f):
                cluster = re.split(r"[mFCct]", f[1:], maxsplit=1)[0]
                if "n" in cluster:
                    block("never skip git hooks (`git commit -n`). The pre-commit check must run.")
    if sub == "config" and any("core.hookspath" in f.lower() for f in flags):
        vals = [f for f in flags if not f.startswith("-") and "hookspath" not in f.lower()]
        reading = any(f in ("--get", "--list", "-l", "--get-all") for f in flags)
        if not reading and vals != ["scripts/hooks"]:
            block("git's hooks path must stay `scripts/hooks` so the pre-commit secret check runs.")
    if sub == "add" and any(re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", f) or f == "--force" for f in flags):
        paths = [f for f in flags if not f.startswith("-")]
        if any(f in ("-A", "--all") for f in flags) or not paths:
            block("`git add -f` with no explicit file list could add ignored photos, backups or .env.")
        for p in paths:
            if refs_private(p) or mentions_env_file(p) or has_glob(p) or p.rstrip("/") in (".", "", ":/"):
                block(f"`git add -f {p}` would commit ignored private files (photos, backups, .env).")


# ── adb ───────────────────────────────────────────────────────────────────────

ADB_NOVALUE = {"-a", "-d", "-e", "--exit-on-write-error"}
ADB_VALUE = {"-s", "-t", "-H", "-P", "-L", "--one-device"}
ADB_HOST_OK = {"devices", "connect", "disconnect", "version", "--version", "help", "--help",
               "start-server", "kill-server", "reconnect", "get-state", "get-serialno", "get-devpath",
               "pair", "mdns", "bugreport", "pull", "push", "features", "host-features", "jdwp",
               "track-devices", "attach", "detach"}
ADB_EXPANSION_OK = {"connect", "disconnect", "pair", "pull", "push", "logcat", "devices", "get-state",
                    "bugreport"}
REBOOT_TARGETS_BAD = {"bootloader", "recovery", "fastboot", "sideload", "sideload-auto-reboot",
                      "edl", "download", "dfu"}


def check_adb(args, cmd, ctx, batch):
    i = 0
    while i < len(args):
        t = args[i].text
        if t in ADB_NOVALUE:
            i += 1
        elif t in ADB_VALUE:
            i += 2
        elif t[:2] in ADB_VALUE and len(t) > 2:
            i += 1
        elif t.startswith("-") and t not in ("--version", "--help"):
            block(f"unknown adb option `{t}`, so the command can't be checked.")
        else:
            break
    rest = args[i:]
    while rest and rest[0].text.lower().startswith("wait-for-"):
        rest = rest[1:]
    if not rest:
        return
    sub, sargs = rest[0].text.lower(), rest[1:]
    if rest[0].expanded:
        block("name the adb subcommand literally so it can be checked.")
    if sub not in ADB_EXPANSION_OK and any(w.expanded for w in sargs):
        block("adb arguments use a variable or $( ), so they can't be checked. "
              "Write the command out literally.")

    if sub in ("root", "unroot", "sideload", "disable-verity", "enable-verity", "remount"):
        block("no root, no flashing, no system remounts.")
    if sub in ("reboot-bootloader", "flash", "flashall"):
        block("rebooting into bootloader/recovery is a flashing path and is forbidden.")
    if sub == "uninstall":
        block("never uninstall. Use `pm disable-user --user 0 <package>` so `pm enable` can undo it.")
    if sub in ("install", "install-multiple", "install-multi-package"):
        block("don't install apps directly. The launcher is installed by scripts/install-launcher.sh.")
    if sub == "reboot":
        if sargs:
            block("rebooting into bootloader/recovery is a flashing path and is forbidden. "
                  "Only a plain `adb reboot` is allowed.")
        return
    if sub == "logcat":
        if any(w.text in ("-c", "--clear") or re.fullmatch(r"-[a-zA-Z]*c", w.text) for w in sargs):
            block("don't clear the TV's logs (`logcat -c`). Read-only logcat is fine.")
        return
    if sub in ("shell", "exec-out"):
        j = 0
        while j < len(sargs) and sargs[j].text.startswith("-"):  # adb shell -t / -T / -n / -x / -e C
            opt = sargs[j].text
            j += 2 if opt == "-e" else 1
            if opt == "--":
                break
        device = sargs[j:]
        if not device:
            block("`adb shell` with no command (interactive, or reading commands from stdin) "
                  "can't be checked. Pass one literal command.")
        analyse_device(" ".join(w.text for w in device), ctx, batch)
        return
    if sub in ADB_HOST_OK:
        return
    block(f"`adb {sub}` isn't on the list of adb commands Claude may run.")


# ── Device side (text after `adb shell`) ──────────────────────────────────────

DEVICE_READ_ONLY = {
    "dumpsys", "getprop", "getevent", "sync", "id", "echo", "printf", "ls", "cat", "grep", "egrep",
    "fgrep", "cut", "sort", "uniq", "head", "tail", "wc", "tr", "true", "false", "whoami", "uname",
    "ps", "df", "du", "date", "getenforce", "sleep", "which", "test", "[", "[[", "screencap",
    "uptime", "pidof", "stat", "basename", "dirname", "pwd", "printenv", "md5sum", "sha1sum",
    "sha256sum", "cd", "exit",
}
PM_READ_ONLY = {"list", "path", "dump", "help", "resolve-activity", "query-activities",
                "query-services", "query-receivers", "get-install-location", "list-users"}
AM_EXTRA_2 = {"--es", "-e", "--ei", "--el", "--ef", "--eu", "--ecn", "--eia", "--eial", "--ela",
              "--elal", "--efa", "--efal", "--esa", "--esal", "--ez", "--ed", "--eda"}
INPUT_SOURCES = {"keyboard", "dpad", "gamepad", "touchscreen", "touchpad", "mouse", "stylus",
                 "trackball", "joystick", "touchnavigation", "rotaryencoder"}


def analyse_device(text, ctx, batch):
    script = lex(text, pwsh=False, depth=1)
    if script.subs:
        block("device-side $( ) or backticks can't be checked. Write the command out literally.")
    for c in script.commands:
        if c.func_def:
            block("no shell functions on the TV. One literal command per call.")
        words, _ = strip_prefixes(c.words, ctx, device=True)
        if not words:
            continue
        if words[0].expanded:
            block("device-side command name uses a variable, so it can't be checked.")
        for w in words:
            if re.search(r"wipe|factory_reset|master_clear", w.text, re.I):
                block("wipes and factory resets are forbidden.")
        name = cmd_name(words[0].text)
        args = words[1:]
        check_device_command(name, args, c, ctx, batch)
    if ctx.settings_key and ctx.digit_keys:
        block("Settings key followed by digit keys looks like a service-menu code. Never open it.")
    if ctx.digit_keys >= 3:
        block("a sequence of digit keys looks like a service-menu code. Never open it.")


def check_device_command(name, args, c, ctx, batch):
    low = [w.text.lower() for w in args]
    if name in ("su", "magisk") or "magisk" in low:
        block("no root: `su`/Magisk are forbidden.")
    if name == "pm":
        return check_pm(args, ctx, batch)
    if name == "cmd":
        if low[:1] == ["package"]:
            return check_pm(args[1:], ctx, batch)
        if low == ["-l"]:
            return
        block(f"`cmd {low[0] if low else ''}` isn't on the list of TV commands Claude may run.")
    if name == "am":
        return check_am(args, ctx)
    if name == "monkey":
        if "-p" not in low:
            block("`monkey` without `-p <package>` can open any app, including service menus.")
        return check_packages_literal(args, ctx, forbidden_only=True)
    if name == "input":
        return check_input(args, ctx)
    if name == "settings":
        rest = [x for x in low if not x.startswith("--user")]
        rest = [x for k, x in enumerate(rest) if not (k > 0 and rest[k - 1] == "--user")]
        if rest[:1] in (["get"], ["list"]):
            return
        block("only `settings get` and `settings list` are allowed. Changing TV settings isn't.")
    if name == "content":
        if low[:1] == ["query"]:
            return check_packages_literal(args, ctx, forbidden_only=True)
        block("only `content query` is allowed on the TV.")
    if name == "wm":
        if low in (["size"], ["density"]):
            return
        block("only `wm size` and `wm density` (read-only) are allowed.")
    if name == "reboot":
        if args:
            block("rebooting into bootloader/recovery is a flashing path and is forbidden. "
                  "Only a plain `reboot` is allowed.")
        return
    if name == "logcat":
        if any(x in ("-c", "--clear") or re.fullmatch(r"-[a-z]*c", x) for x in low):
            block("don't clear the TV's logs (`logcat -c`). Read-only logcat is fine.")
        return
    if name in DEVICE_READ_ONLY:
        return
    block(f"`{name}` isn't on the list of TV commands Claude may run (allowlist: pm list/path/enable/"
          "disable-user, dumpsys, getprop, settings get/list, am start, input keyevent, logcat, getevent, ...).")


def check_packages_literal(args, ctx, forbidden_only=False, skip=()):
    _, forbidden, _ = ctx.lists()
    for k, w in enumerate(args):
        if k in skip:
            continue
        t = w.text.lower()
        if w.expanded or ("$" in t):
            block("name the package literally (no variables) so it can be checked.")
        if has_glob(t):
            block("name the package literally (no wildcards) so it can be checked.")
        for tok in re.findall(PKG_RE, t) + [t]:
            if matches(tok, forbidden):
                block(f"`{tok}` looks like a factory/service-menu app. Never open it, even to look.")


def check_pm(args, ctx, batch):
    protected, forbidden, streaming = ctx.lists()
    if not args:
        return
    verb = args[0].text.lower()
    rest = args[1:]
    if verb in PM_READ_ONLY:
        return
    if verb == "enable":
        return check_packages_literal(rest, ctx, forbidden_only=True)
    if verb == "disable-user":
        return check_disable(rest, ctx, batch, protected, streaming)
    if verb.startswith("uninstall"):
        block("never uninstall. Use `pm disable-user --user 0 <package>` so `pm enable` can undo it.")
    if verb in ("clear", "hide", "suspend", "reset-permissions", "set-installer", "disable",
                "disable-until-used"):
        block("only `pm disable-user --user 0 <package>` is allowed; "
              f"`pm {verb}` is not something `pm enable` cleanly undoes.")
    block(f"`pm {verb}` isn't on the allowlist (list, path, dump, enable, disable-user).")


def check_disable(rest, ctx, batch, protected, streaming):
    if batch or ctx.loop:
        block("one package at a time. No loops, xargs or batches of disable-user.")
    ctx.disable_count += 1
    if ctx.disable_count > 1:
        block("one package at a time: one disable-user per Bash call.")
    texts = [w.text.lower() for w in rest]
    if any(w.expanded or "$" in w.text for w in rest):
        block("name the package literally (no variables or wildcards) so it can be checked.")
    if texts[:2] != ["--user", "0"]:
        block("disable must be exactly `pm disable-user --user 0 <package>`.")
    if len(texts) != 3:
        block("disable must be exactly `pm disable-user --user 0 <package>`: one package at a time.")
    pkg = texts[2]
    if has_glob(pkg) or not re.fullmatch(PKG_RE, pkg):
        block("name the package literally (no variables, wildcards or components) so it can be checked.")
    if matches(pkg, protected):
        block(f"`{pkg}` is protected (it keeps the TV working). Never disable it.")
    if matches(pkg, streaming):
        block(f"`{pkg}` is a streaming app. Owners turn these off themselves in TV Settings.")
    if not has_real_backup():
        block(f"no backup found in {BACKUP_DIR.name}/. Back up the package list, disabled list, "
              "getprop and settings before the first change (bash scripts/backup.sh).")


def has_real_backup():
    """A backups/<YYYY-MM-DD_HHMMSS>/packages-all.txt with at least one `package:` line."""
    try:
        for d in BACKUP_DIR.iterdir():
            f = d / "packages-all.txt"
            if not (d.is_dir() and BACKUP_NAME_RE.match(d.name) and f.is_file()):
                continue
            with f.open(errors="ignore") as fh:
                if any(line.startswith("package:") for line in fh):
                    return True
    except OSError:
        return False
    return False


def check_am(args, ctx):
    if not args:
        return
    verb = args[0].text.lower()
    rest = args[1:]
    if verb in ("start", "start-activity"):
        skip = set()
        k = 0
        while k < len(rest):
            t = rest[k].text
            if t in ("-d", "--data") or t.startswith("--data="):
                block("deep links (`am start -d`) can open hidden menus. Not allowed.")
            if t in AM_EXTRA_2:
                skip.update({k + 1, k + 2})
                k += 3
                continue
            if t == "--esn":
                skip.add(k + 1)
            k += 1
        return check_packages_literal(rest, ctx, forbidden_only=True, skip=skip)
    block(f"`am {verb}` isn't on the allowlist (only `am start` / `am start-activity`).")


def check_input(args, ctx):
    k = 0
    while k < len(args) and (args[k].text.lower() in INPUT_SOURCES or args[k].text == "-d"):
        k += 2 if args[k].text == "-d" else 1
    if k >= len(args):
        return
    verb, rest = args[k].text.lower(), [w.text for w in args[k + 1:]]
    if verb == "keyevent":
        for code in rest:
            u = code.upper()
            if u.startswith("-"):
                continue
            if u in ("KEYCODE_SETTINGS", "176"):
                ctx.settings_key = True
            if (re.fullmatch(r"KEYCODE_(NUMPAD_)?[0-9]", u) or re.fullmatch(r"[0-9]", u)
                    or (u.isdigit() and (7 <= int(u) <= 16 or 144 <= int(u) <= 153))):
                ctx.digit_keys += 1
        return
    block(f"`input {verb}` isn't allowed; only `input keyevent` (no service-menu digit codes).")


# ── Entry point ───────────────────────────────────────────────────────────────

# The one documented way to create the settings file (PROMPT.md Phase 2): copy .env.example
# with the owner's TV IP filled in. Allowed only in exactly this shape and only while .env
# doesn't exist, so nothing can read or overwrite an existing .env this way.
_IP = r"[0-9A-Za-z.:-]+"
ENV_CREATE_BASH = re.compile(
    r"\s*sed\s+(['\"])s/\^TV_IP=\.\*/TV_IP=" + _IP + r"/\1\s+(\./)?\.env\.example\s*>\s*(\./)?\.env\s*")
ENV_CREATE_PWSH = re.compile(
    r"\s*\(\s*Get-Content\s+(\.[/\\])?\.env\.example\s*\)\s+-replace\s+'\^TV_IP=\.\*'\s*,\s*'TV_IP="
    + _IP + r"'\s*\|\s*Set-Content\s+(\.[/\\])?\.env\s*", re.I)


def is_env_creation(command, pwsh):
    """True for the documented create-.env command. Blocks it if .env already exists."""
    if not (ENV_CREATE_PWSH if pwsh else ENV_CREATE_BASH).fullmatch(command):
        return False
    if os.path.lexists(ROOT / ".env"):
        block("`.env` already exists. Never overwrite it; the owner edits it themselves.")
    return True


def check(command, pwsh=False):
    if is_env_creation(command, pwsh):
        return
    ctx = Ctx(command, pwsh)
    script = lex(command, pwsh=pwsh)
    analyse_script(script, ctx)
    if ctx.loop and ctx.disable_count:
        block("one package at a time. No loops, xargs or batches of disable-user.")
    if ctx.upload and ctx.private_ref:
        block("photos, backups and screenshots must never be uploaded anywhere.")


def main():
    try:
        data = json.loads(sys.stdin.read())
        if not isinstance(data, dict):
            raise ValueError("hook input is not a JSON object")
        tool = data.get("tool_name")
        if tool not in ("Bash", "PowerShell"):
            return 0
        tool_input = data.get("tool_input")
        if not isinstance(tool_input, dict) or not isinstance(tool_input.get("command"), str):
            raise ValueError("tool_input.command is missing or not a string")
        check(tool_input["command"], pwsh=(tool == "PowerShell"))
        return 0
    except Blocked as e:
        reason = str(e)
    except Exception as e:  # fail closed on anything unexpected
        reason = f"the safety hook couldn't check this command ({type(e).__name__}: {e})."
    print(f"⛔ TV safety rule: {reason}\nSee 'Rule: TV safety' in CLAUDE.md. "
          "Do not work around this. Stop and tell the user.", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
