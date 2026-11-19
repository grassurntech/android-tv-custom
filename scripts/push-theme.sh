#!/usr/bin/env bash
# Pushes the owner's theme (user-content/theme, made by make_theme.py) to the TV through cleanyourtv's
# own theme.sh. No arguments.
# Exit: 0 pushed, 2 bad arguments, 3 TV_IP unset, vendor not fetched or no theme made yet; otherwise
#       theme.sh's own exit code (1 push failed, 2 refused before anything was sent).
export LC_ALL=C
. "$(dirname "$0")/lib/tv-env.sh"

if [ "$#" -ne 0 ]; then
  echo "Usage: push-theme.sh (no arguments)" >&2
  exit 2
fi
tv_load_env

upstream="$REPO_ROOT/vendor/cleanyourtv/tools/theme.sh"
theme="$REPO_ROOT/user-content/theme"
if [ ! -f "$upstream" ]; then
  echo "cleanyourtv is not fetched yet. Run scripts/fetch-tools.sh first." >&2
  exit 3
fi
if [ ! -f "$theme/config.json" ]; then
  echo "No theme yet (user-content/theme/config.json). Run scripts/make_theme.py first." >&2
  exit 3
fi

# IP:port: upstream's tools/tv.py accepts it, so a custom TV_ADB_PORT reaches the TV.
TV_HOST="$SERIAL" bash "$upstream" "$theme"
exit $?
