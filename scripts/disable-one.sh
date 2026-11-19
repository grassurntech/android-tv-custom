#!/usr/bin/env bash
# Turns off ONE package on the TV with `pm disable-user --user 0 <package>`. Never uninstalls.
# This is the only way product code may disable a package; every safety check lives here.
# Exit: 0 done (or already off), 2 bad arguments, 3 setup missing, 10 protected, 11 streaming app,
#       12 forbidden, 13 no usable backup, 14 not in the backup, 20 TV refused, 21 unreachable,
#       22 unauthorized.
export LC_ALL=C
. "$(dirname "$0")/lib/tv-env.sh"

# 1. Exactly one argument, shaped like a package name (no globs, no spaces, no shell characters).
if [ "$#" -ne 1 ]; then
  echo "Usage: disable-one.sh <package.name>   (exactly one package)" >&2
  exit 2
fi
pkg="$1"
if ! [[ "$pkg" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$ ]]; then
  echo "That doesn't look like a package name: $pkg. Nothing was changed. Stopping." >&2
  exit 2
fi

# 2. Config, then the three safety lists must exist.
tv_load_env
for list in protected-packages.txt streaming-apps.txt forbidden-packages.txt; do
  if [ ! -f "$REPO_ROOT/config/$list" ]; then
    echo "Missing config/$list. Nothing was changed. Stopping." >&2
    exit 3
  fi
done

# 3. Never touch protected, streaming or forbidden packages.
if tv_matches "$pkg" "$REPO_ROOT/config/protected-packages.txt"; then
  echo "$pkg is protected (it keeps the TV working as a TV). Nothing was changed. Stopping." >&2
  exit 10
fi
if tv_matches "$pkg" "$REPO_ROOT/config/streaming-apps.txt"; then
  echo "$pkg is a streaming app. Turn it off yourself in TV Settings if you want to. Nothing was changed. Stopping." >&2
  exit 11
fi
if tv_matches "$pkg" "$REPO_ROOT/config/forbidden-packages.txt"; then
  echo "$pkg is a factory or service app that must never be touched. Nothing was changed. Stopping." >&2
  exit 12
fi

# 4. A backup must exist before the first change.
backup="$(tv_latest_backup)"
if [ -z "$backup" ]; then
  echo "No backup found. Run scripts/backup first. Nothing was changed. Stopping." >&2
  exit 13
fi

# 5. The package must be in that backup's package list, or be one we installed ourselves.
# list_has <file> <pkg>: exact, case-sensitive match of a line, ignoring CR, spaces and a package: prefix.
list_has() {
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"   # UTF-8 BOM
    _tv_trim "$line"; line="$TV_TRIMMED"
    line="${line#package:}"
    [ "$line" = "$2" ] && return 0
  done < "$1"
  return 1
}
known=0
if list_has "$backup/packages-all.txt" "$pkg"; then known=1; fi
if [ "$known" -eq 0 ]; then
  for f in "$TV_BACKUP_DIR"/*/installed-by-us.txt; do
    if list_has "$f" "$pkg"; then known=1; break; fi
  done
fi
if [ "$known" -eq 0 ]; then
  echo "$pkg is not in the backup and was not installed by us. Nothing was changed. Stopping." >&2
  exit 14
fi

# 6. The TV must be reachable.
tv_reachable
rc=$?
case "$rc" in
  0)  ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac

# is_disabled <pkg>: 0 yes, 1 no, 2 the TV could not answer.
is_disabled() {
  local out line
  out="$(tv_shell pm list packages -d)" || return 2
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"; line="$TV_TRIMMED"
    [ "$line" = "package:$1" ] && return 0
  done <<EOT
$out
EOT
  return 1
}

# 7. Already off: nothing to do, nothing to log.
is_disabled "$pkg"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "$pkg is already off. Nothing to do."
  exit 0
fi
if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ]; then
  echo "The TV didn't answer when asked about $pkg. Nothing was changed. Stopping." >&2
  exit 20
fi

# 8. The one and only change. No retries.
tv_shell pm disable-user --user 0 "$pkg" >/dev/null 2>&1

# 9. Check it really is off, then record it for the undo.
is_disabled "$pkg"; rc=$?
if [ "$rc" -eq 2 ]; then
  echo "The TV didn't confirm whether $pkg was turned off. Check before doing anything else. Stopping." >&2
  exit 20
fi
if [ "$rc" -ne 0 ]; then
  echo "The TV refused to turn off $pkg. Nothing was changed. Stopping." >&2
  exit 20
fi
if ! printf '%s\t%s\n' "$pkg" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$backup/disabled-by-us.txt"; then
  echo "$pkg is off, but the undo log $backup/disabled-by-us.txt could not be written. Re-enable it with: adb shell pm enable $pkg" >&2
  exit 20
fi
echo "Turned off $pkg"
exit 0
