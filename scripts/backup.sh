#!/usr/bin/env bash
# Backs up the TV's package lists, properties and settings to TV_BACKUP_DIR/<YYYY-MM-DD_HHMMSS>/.
# Read-only on the TV. Prints the backup folder as the last stdout line.
# Exit: 0 done, 2 bad arguments, 3 setup missing, 20 TV refused / empty result, 21 unreachable, 22 unauthorized.
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
mkdir -p "$partial" || exit 20

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

if [ ! -s "$partial/packages-all.txt" ]; then
  echo "The TV returned an empty package list; no backup was kept." >&2
  exit 20
fi

mv "$partial" "$final" || exit 20
done_ok=1
echo "Backup saved"
printf '%s\n' "$final"
