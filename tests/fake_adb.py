#!/usr/bin/env python3
"""adb stand-in for tests. Never talks to a device.

Reads JSON state from $FAKE_ADB_STATE, appends each call (argv joined by spaces) as one
line to $FAKE_ADB_LOG, and writes state changes back.

State keys:
  state     "device" | "unauthorized" | "offline"
  packages  [str]  installed packages
  disabled  [str]  disabled packages
  refuse    [str]  packages whose disable/enable has no effect
  home      str    current home activity component
  getprop   str    text printed by `getprop`
"""
import json
import os
import shlex
import sys

DEFAULTS = {"state": "device", "packages": [], "disabled": [], "refuse": [], "home": "", "getprop": ""}


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
    if len(cmd) == 1:  # `adb shell "pm list packages"` arrives as one string
        cmd = shlex.split(cmd[0])

    if cmd[:3] == ["pm", "list", "packages"]:
        flag = cmd[3] if len(cmd) > 3 else None
        disabled = set(state["disabled"])
        for p in state["packages"]:
            if flag == "-d" and p not in disabled:
                continue
            if flag == "-e" and p in disabled:
                continue
            print(f"package:{p}")
    elif cmd[:4] == ["pm", "disable-user", "--user", "0"] and len(cmd) == 5:
        pkg = cmd[4]
        if pkg not in state["refuse"] and pkg in state["packages"] and pkg not in state["disabled"]:
            state["disabled"].append(pkg)
            save(state)
        print(f"Package {pkg} new state: disabled-user")
    elif cmd[:2] == ["pm", "enable"] and len(cmd) == 3:
        pkg = cmd[2]
        if pkg not in state["refuse"] and pkg in state["disabled"]:
            state["disabled"].remove(pkg)
            save(state)
        print(f"Package {pkg} new state: enabled")
    elif cmd == ["getprop"]:
        print(state["getprop"])
    elif cmd[:2] == ["settings", "list"] and len(cmd) == 3 and cmd[2] in ("global", "secure", "system"):
        print(f"fake_{cmd[2]}_setting=1")
    elif cmd[:3] == ["cmd", "package", "resolve-activity"] and cmd[-1].endswith("HOME"):
        print("priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true")
        print(state["home"])
    elif cmd[:4] == ["cmd", "package", "set-home-activity", "--user"] and len(cmd) == 6 and cmd[4] == "0":
        state["home"] = cmd[5]
        save(state)
    else:
        fail(f"fake adb: unsupported: {' '.join(args)}", 2)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
