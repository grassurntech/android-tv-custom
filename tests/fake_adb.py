#!/usr/bin/env python3
"""adb stand-in for tests. Never talks to a device.

Reads JSON state from $FAKE_ADB_STATE, appends each call (argv joined by spaces) as one
line to $FAKE_ADB_LOG, and writes state changes back.

State keys:
  state     "device" | "unauthorized" | "offline"
  packages  [str]  installed packages
  disabled  [str]  disabled packages
  refuse    [str]  packages whose disable/enable has no effect
  home      str    current home activity component (set-home-activity changes it)
  resolve_home  str  if set, what resolve-activity HOME prints instead of `home` (a TV that ignores set-home)
  refuse_home   bool set-home-activity fails and changes nothing
  fail_list_filter bool `pm list packages <name>` fails (the TV cannot answer)
  getprop   str    text printed by `getprop`
  fail_list_disabled bool  `pm list packages -d` fails with exit 1 (the TV cannot answer)
  list_junk         bool  every `pm list packages ...` prints an error line and exits 0
  offline_after     int   once this many adb calls have been made, the TV acts offline
  calls             int   adb calls made so far (kept by this script)
  props             {str: str}  values for `getprop <key>` (a missing key prints an empty line)
  junk_after_change bool  once a `pm disable-user` or `pm enable` has run, act as list_junk
  stderr_noise      str   if set, every shell command also prints this to stderr (exit code unchanged)
  secure            {str: str}  `settings get/put secure <key>` (a missing key prints "null")
  ignore_settings   bool  `settings put` exits 0 but changes nothing (firmware that drops the write)
  appops            [str]  each `cmd appops set ...` and `appops write-settings` call is accepted and logged here
"""
import json
import os
import shlex
import sys

DEFAULTS = {"state": "device", "packages": [], "disabled": [], "refuse": [], "home": "", "getprop": "",
            "resolve_home": None, "refuse_home": False, "fail_list_filter": False,
            "fail_list_disabled": False, "list_junk": False, "offline_after": None, "calls": 0,
            "props": {}, "junk_after_change": False, "stderr_noise": "", "secure": {},
            "ignore_settings": False, "appops": []}


def load():
    path = os.environ["FAKE_ADB_STATE"]
    try:
        with open(path) as f:
            return dict(DEFAULTS, **json.load(f))
    except FileNotFoundError:
        return dict(DEFAULTS)


def save(state):
    with open(os.environ["FAKE_ADB_STATE"], "w") as f:
        json.dump(state, f)


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def main(argv):
    with open(os.environ["FAKE_ADB_LOG"], "a") as f:
        f.write(" ".join(argv) + "\n")
    state = load()
    args = list(argv)

    if args and args[0] == "connect":
        print(f"connected to {args[1] if len(args) > 1 else ''}")
        return 0

    if len(args) >= 2 and args[0] == "-s":
        args = args[2:]

    if state["offline_after"] is not None:
        state["calls"] += 1
        if state["calls"] > state["offline_after"]:
            state["state"] = "offline"
        save(state)

    if state["state"] == "offline":
        fail("error: device offline")
    if state["state"] == "unauthorized":
        fail("error: device unauthorized.\nThis adb server's $ADB_VENDOR_KEYS is not set")

    if args == ["get-state"]:
        print("device")
        return 0

    if not args or args[0] != "shell":
        fail(f"fake adb: unsupported: {' '.join(args)}", 2)
    cmd = args[1:]
    if state["stderr_noise"]:
        print(state["stderr_noise"], file=sys.stderr)
    if len(cmd) == 1:  # `adb shell "pm list packages"` arrives as one string
        cmd = shlex.split(cmd[0])

    if cmd[:3] == ["pm", "list", "packages"]:
        if state["list_junk"]:
            print("Error: could not access the Package Manager. Is the system running?")
            return 0
        flag = cmd[3] if len(cmd) > 3 else None
        if flag == "-d" and state["fail_list_disabled"]:
            fail("Error: could not access the Package Manager.")
        name_filter = None
        if flag is not None and not flag.startswith("-"):  # `pm list packages <text>`: substring filter
            name_filter, flag = flag, None
            if state["fail_list_filter"]:
                fail("Error: could not access the Package Manager.")
        disabled = set(state["disabled"])
        for p in state["packages"]:
            if name_filter is not None and name_filter not in p:
                continue
            if flag == "-d" and p not in disabled:
                continue
            if flag == "-e" and p in disabled:
                continue
            print(f"package:{p}")
    elif cmd[:4] == ["pm", "disable-user", "--user", "0"] and len(cmd) == 5:
        pkg = cmd[4]
        if pkg not in state["refuse"] and pkg in state["packages"] and pkg not in state["disabled"]:
            state["disabled"].append(pkg)
        if state["junk_after_change"]:
            state["list_junk"] = True
        save(state)
        print(f"Package {pkg} new state: disabled-user")
    elif cmd[:2] == ["pm", "enable"] and len(cmd) == 3:
        pkg = cmd[2]
        if pkg not in state["refuse"] and pkg in state["disabled"]:
            state["disabled"].remove(pkg)
        if state["junk_after_change"]:
            state["list_junk"] = True
        save(state)
        print(f"Package {pkg} new state: enabled")
    elif cmd == ["getprop"]:
        print(state["getprop"])
    elif cmd[:1] == ["getprop"] and len(cmd) == 2:
        print(state["props"].get(cmd[1], ""))
    elif cmd[:2] == ["settings", "list"] and len(cmd) == 3 and cmd[2] in ("global", "secure", "system"):
        print(f"fake_{cmd[2]}_setting=1")
    elif cmd[:3] == ["settings", "get", "secure"] and len(cmd) == 4:
        print(state["secure"].get(cmd[3], "null"))
    elif cmd[:3] == ["settings", "put", "secure"] and len(cmd) in (4, 5):
        if not state["ignore_settings"]:
            state["secure"][cmd[3]] = cmd[4] if len(cmd) == 5 else ""
            save(state)
    elif (cmd[:3] == ["cmd", "appops", "set"] and len(cmd) == 6) or cmd == ["appops", "write-settings"]:
        state["appops"].append(" ".join(cmd))
        save(state)
    elif cmd[:3] == ["cmd", "package", "resolve-activity"] and cmd[-1].endswith("HOME"):
        print("priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true")
        print(state["resolve_home"] if state["resolve_home"] is not None else state["home"])
    elif cmd[:4] == ["cmd", "package", "set-home-activity", "--user"] and len(cmd) == 6 and cmd[4] == "0":
        if state["refuse_home"]:
            fail("Error: could not set the home activity.")
        state["home"] = cmd[5]
        save(state)
    else:
        fail(f"fake adb: unsupported: {' '.join(args)}", 2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
