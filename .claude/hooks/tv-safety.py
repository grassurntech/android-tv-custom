#!/usr/bin/env python3
"""
TV safety guardrail: a Claude Code PreToolUse hook for Bash.

Blocks any command that could change a user's TV in a way `pm enable` can't undo,
touches protected packages, opens factory/service menus, or sends user content off
the computer. See "Rule: TV safety" in CLAUDE.md.

Only real invocations are checked: each shell segment whose command word is
adb / fastboot / an upload tool. Text inside heredocs, echo, grep, etc. is ignored.
The hook can't see inside scripts, so product scripts must enforce the same rules.

Exit 2 = block (stderr is shown to Claude). Exit 0 = allow.
"""
import fnmatch
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(os.environ.get("CLAUDE_PROJECT_DIR", Path(__file__).resolve().parents[2]))
BACKUP_DIR = ROOT / os.environ.get("TV_BACKUP_DIR", "backups")
UPLOAD_TOOLS = {"curl", "wget", "scp", "rsync", "sftp", "ftp", "gh", "aws", "gsutil", "rclone", "nc"}
PKG_RE = r"[a-z][\w]*(?:\.[\w]+)+"


def load_patterns(name):
    path = ROOT / "config" / name
    if not path.exists():
        return None
    return [l.strip().lower() for l in path.read_text().splitlines()
            if l.strip() and not l.lstrip().startswith("#")]


def block(reason):
    print(f"⛔ TV safety rule: {reason}\nSee 'Rule: TV safety' in CLAUDE.md. "
          "Do not work around this. Stop and tell the user.", file=sys.stderr)
    sys.exit(2)


def matches(pkg, patterns):
    return any(fnmatch.fnmatch(pkg.lower(), p) for p in patterns)


def segments(cmd):
    # Drop heredoc bodies: their text is data being written, not commands.
    cmd = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n.*?\n\s*\1\s*(\n|$)", "\n", cmd, flags=re.S)
    for seg in re.split(r"\n|;|&&|\|\||\||\$\(|`", cmd):
        words = re.sub(r"[\"'\\]", " ", seg).lower().split()
        while words and (re.match(r"^\w+=", words[0]) or words[0] in {"sudo", "env", "exec", "time", "(", "{", "then", "do", "else"}):
            words = words[1:]
        if words:
            yield Path(words[0]).name, " ".join(words)


def check_adb(text, protected, forbidden, streaming):
    # text is the whole segment starting with "adb ..."
    if re.search(r"^adb\s+(-\S+\s+\S+\s+)*(root|unroot|sideload|disable-verity|enable-verity|remount)\b", text):
        block("no root, no flashing, no system remounts.")
    if re.search(r"\breboot\s+(bootloader|recovery|fastboot|sideload|edl|download)", text):
        block("rebooting into bootloader/recovery is a flashing path and is forbidden.")
    if re.search(r"(^|\s)su(\s|$)", text) or "magisk" in text:
        block("no root: `su`/Magisk are forbidden.")
    if re.search(r"\b(wipe|factory_reset|master_clear)\b", text):
        block("wipes and factory resets are forbidden.")
    if re.search(r"\b(pm|cmd\s+package)\s+uninstall\b|^adb\s+(-\S+\s+\S+\s+)*uninstall\b", text):
        block("never uninstall. Use `pm disable-user --user 0 <package>` so `pm enable` can undo it.")
    if re.search(r"\b(pm|cmd\s+package)\s+(clear|hide|suspend|reset-permissions|set-installer)\b", text):
        block("only `pm disable-user` is allowed; clear/hide/suspend can't be undone with `pm enable`.")
    if re.search(r"\b(pm|cmd\s+package)\s+disable(\s|$)", text):
        block("use `pm disable-user --user 0 <package>`, not `pm disable`.")

    # Never open factory / service menus, even to look.
    if re.search(r"\b(am|monkey|cmd\s+activity|input)\b", text):
        for tok in re.findall(PKG_RE, text):
            if matches(tok, forbidden):
                block(f"`{tok}` looks like a factory/service-menu app. Never open it, even to look.")

    if re.search(r"\b(pm|cmd\s+package)\s+disable-user\b", text):
        if re.search(r"\b(xargs|for|while)\b", text) or text.count("disable-user") > 1:
            block("one package at a time. No loops, xargs or batches of disable-user.")
        m = re.search(r"disable-user\s+((?:--?\S+\s+\S+\s+)*)(\S+)\s*(.*)$", text)
        if not m or "--user 0" not in m.group(1):
            block("disable must be exactly `pm disable-user --user 0 <package>`.")
        pkg, rest = m.group(2), m.group(3)
        if not re.fullmatch(PKG_RE, pkg):
            block("name the package literally (no variables or wildcards) so it can be checked.")
        if rest and not re.match(r"^(2?>|>)", rest):
            block("one package at a time.")
        if matches(pkg, protected):
            block(f"`{pkg}` is protected (it keeps the TV working). Never disable it.")
        if matches(pkg, streaming):
            block(f"`{pkg}` is a streaming app. Owners turn these off themselves in TV Settings.")
        if not BACKUP_DIR.exists() or not any(BACKUP_DIR.rglob("packages-all.txt")):
            block(f"no backup found in {BACKUP_DIR.name}/. Back up the package list, disabled list, "
                  "getprop and settings before the first change.")


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    if data.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (data.get("tool_input") or {}).get("command", "")

    segs = list(segments(cmd))
    loopy = any(w in {"for", "while", "until", "xargs", "parallel"} for w, _ in segs)
    if loopy and any("disable-user" in t and "adb" in t for _, t in segs):
        block("one package at a time. No loops, xargs or batches of disable-user.")

    protected = forbidden = streaming = None
    for word, text in segs:
        if word in UPLOAD_TOOLS and re.search(r"(^|[\s/=@])(photos|backups|screenshots|user-content)(/|\s|$)", text):
            block("photos, backups and screenshots must never be uploaded anywhere.")
        if word == "fastboot":
            block("no flashing: fastboot is forbidden.")
        if word == "adb":
            if protected is None:
                protected = load_patterns("protected-packages.txt")
                forbidden = load_patterns("forbidden-packages.txt")
                streaming = load_patterns("streaming-apps.txt")
                if protected is None or forbidden is None or streaming is None:
                    block("config/protected-packages.txt, forbidden-packages.txt or streaming-apps.txt is missing, "
                          "so TV commands can't be checked.")
            check_adb(text, protected, forbidden, streaming)
    sys.exit(0)


if __name__ == "__main__":
    main()
