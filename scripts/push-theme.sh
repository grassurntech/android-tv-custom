#!/usr/bin/env bash
# Pushes the owner's theme (user-content/theme, made by make_theme.py) to the TV through cleanyourtv's
# own theme.sh. No arguments. Before anything is sent it checks the theme with make_theme.py --check-theme:
# config.json must parse, wallpapers/ must hold at least one .jpg, and no package named anywhere in config.json
# may match config/forbidden-packages.txt.
# Exit: 0 pushed, 2 bad arguments or a theme that fails the check (nothing pushed), 3 TV_IP unset, vendor not
#       fetched, no theme made yet, Python missing or a package list unreadable; otherwise theme.sh's own exit
#       code (1 push failed, 2 refused before anything was sent).
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

# Check the theme before anything is sent (same rules as make_theme.py, so one implementation).
py=""
for c in "$REPO_ROOT/.venv/bin/python" python3 python; do
  if command -v "$c" >/dev/null 2>&1; then py="$c"; break; fi
done
if [ -z "$py" ]; then
  echo "Python is needed to check the theme. Install it (see README), then run this again." >&2
  exit 3
fi
"$py" "$REPO_ROOT/scripts/make_theme.py" --check-theme "$theme" >/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
  [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ] || rc=3
  exit "$rc"
fi

# IP:port: upstream's tools/tv.py accepts it, so a custom TV_ADB_PORT reaches the TV.
TV_HOST="$SERIAL" bash "$upstream" "$theme"
exit $?
