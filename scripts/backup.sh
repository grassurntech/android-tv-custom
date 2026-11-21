#!/usr/bin/env bash
# Backs up the TV's package lists, properties and settings to TV_BACKUP_DIR/<YYYY-MM-DD_HHMMSS>/.
# Read-only on the TV. Prints the backup folder as the last stdout line. Also records which TV it is
# (tv-id.txt) so disable-one and restore never use one TV's backup on another.
# Exit: 0 done, 2 bad arguments, 3 setup missing or the backup folder can't be written,
#       20 TV refused / empty or error result (no folder kept), 21 unreachable, 22 unauthorized.
. "$(dirname "$0")/lib/tv-env.sh"

if [ "$#" -gt 0 ]; then
  echo "Usage: backup.sh (no arguments)" >&2
  exit 2
fi
tv_load_env
tv_reachable
rc=$?
case "$rc" in
  0)  ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac

final="$TV_BACKUP_DIR/$(date +%Y-%m-%d_%H%M%S)"
partial="$final.partial"
done_ok=0
cleanup() {
  if [ "$done_ok" -ne 1 ]; then rm -rf "$partial"; fi
}
trap cleanup EXIT
trap 'exit 20' INT TERM

if [ -e "$final" ] || [ -e "$partial" ]; then
  echo "A backup for this second already exists: $final. Wait a moment and run again." >&2
  done_ok=1   # do not delete a folder that is not ours
  exit 20
fi
if ! mkdir -p "$partial" 2>/dev/null; then
  echo "Can't create the backup folder $partial. Check TV_BACKUP_DIR and its permissions." >&2
  done_ok=1   # nothing of ours to clean up
  exit 3
fi

# capture <file> <cmd...>: run on the TV, raw output into the partial folder.
capture() {
  local file="$1"; shift
  if ! tv_shell "$@" > "$partial/$file"; then
    echo "The TV refused or failed: $*" >&2
    exit 20
  fi
}

capture packages-disabled.txt pm list packages -d
capture getprop.txt getprop
capture settings-global.txt settings list global
capture settings-secure.txt settings list secure
capture settings-system.txt settings list system
capture home-activity.txt cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
capture packages-all.txt pm list packages   # last: its presence marks a complete capture

# list_ok <file> <need_one>: every non-empty line is a package: line (and, with need_one=1, there is one).
list_ok() {
  local content
  content="$(cat "$1")" || return 1
  tv_list_state "$content" "-"
  [ "$?" -eq 2 ] && return 1
  if [ "$2" -eq 1 ]; then
    LC_ALL=C grep -q '^[[:space:]]*package:' "$1" || return 1
  fi
  return 0
}
if ! list_ok "$partial/packages-all.txt" 1; then
  echo "The TV returned an empty package list or an error message instead of one; no backup was kept." >&2
  exit 20
fi
if ! list_ok "$partial/packages-disabled.txt" 0; then
  echo "The TV returned an error message instead of its list of switched-off apps; no backup was kept." >&2
  exit 20
fi

if ! tv_identity; then
  echo "The TV didn't say which TV it is; no backup was kept." >&2
  exit 20
fi
if ! printf '%s\n' "$TV_ID" > "$partial/tv-id.txt"; then
  echo "Can't write $partial/tv-id.txt; no backup was kept." >&2
  exit 3
fi

if ! mv "$partial" "$final"; then
  echo "Can't finish the backup folder $final." >&2
  exit 3
fi
done_ok=1
echo "Backup saved"
printf '%s\n' "$final"
