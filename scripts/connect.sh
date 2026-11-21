#!/usr/bin/env bash
# Connects to the TV over adb. Exit: 0 connected, 21 unreachable, 22 unauthorized, 3 setup missing.
# connect.sh --check-off (Phase 7): checks debugging is now OFF. Exit 0 = off (the TV no longer answers),
# 23 = still on (the TV answered, whether or not it trusts this computer), 3 = setup missing.
. "$(dirname "$0")/lib/tv-env.sh"

mode=connect
if [ "$#" -eq 1 ] && [ "$1" = "--check-off" ]; then
  mode=check-off
elif [ "$#" -gt 0 ]; then
  echo "Usage: connect.sh [--check-off]" >&2
  exit 2
fi
tv_load_env
tv_reachable
rc=$?
if [ "$mode" = "check-off" ]; then
  case "$rc" in
    21) echo "Debugging is OFF: the TV no longer answers this computer. Done."; exit 0 ;;
    0|22) echo "Debugging is still ON: the TV still answers over Wi-Fi. Ask the owner to turn off Network debugging (and Wireless debugging) in Settings > System > Developer options. Do not press Allow." >&2; exit 23 ;;
    *)  exit "$rc" ;;
  esac
fi
case "$rc" in
  0)  echo "Connected to the TV"; exit 0 ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac
