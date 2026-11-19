#!/usr/bin/env bash
# Connects to the TV over adb. Exit: 0 connected, 21 unreachable, 22 unauthorized, 3 setup missing.
. "$(dirname "$0")/lib/tv-env.sh"

if [ "$#" -gt 0 ]; then
  echo "Usage: connect.sh (no arguments)" >&2
  exit 2
fi
tv_load_env
tv_reachable
rc=$?
case "$rc" in
  0)  echo "Connected to the TV"; exit 0 ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac
