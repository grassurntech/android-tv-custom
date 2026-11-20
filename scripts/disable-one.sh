#!/usr/bin/env bash
# Turns off ONE package on the TV with `pm disable-user --user 0 <package>`. Never uninstalls.
# This is the only way product code may disable a package; every safety check lives here.
# Exit: 0 done (or already off), 2 bad arguments, 3 setup missing or a local file can't be read/written
#       (a safety list that is missing, unreadable, UTF-16 or empty; an unreadable backup file; an undo log
#       that can't be written: all checked before any change), 10 protected (or the TV's current Home app),
#       11 streaming app, 12 forbidden, 13 no usable backup or the backup is from another TV,
#       14 not in the backup, 20 TV refused or didn't answer, 21 unreachable, 22 unauthorized.
# The undo log (disabled-by-us.txt) is written BEFORE the change, so a change can never go unrecorded.
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

# 2. Config, then the three safety lists must exist, be readable and hold patterns (else exit 3).
tv_load_env
for list in protected-packages.txt streaming-apps.txt forbidden-packages.txt; do
  _tv_list_patterns "$REPO_ROOT/config/$list"
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

# 4. A backup must exist before the first change (every backup file readable, else exit 3).
tv_backups_readable
backups="$(tv_all_backups)"
backup="$(printf '%s\n' "$backups" | sed -n '1p')"
if [ -z "$backup" ]; then
  echo "No backup found. Run scripts/backup first. Nothing was changed. Stopping." >&2
  exit 13
fi

# 5. The TV must be reachable.
tv_reachable
rc=$?
case "$rc" in
  0)  ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac

# 6. The backup must come from this TV (sets TV_ID).
tv_check_identity "$backup"

# 7. The package must be in that backup's package list, or be one we installed ourselves (recorded in a
# usable backup of this same TV).
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
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    tv_backup_id "$folder"
    [ "$TV_BACKUP_ID" = "$TV_ID" ] || continue
    if list_has "$folder/installed-by-us.txt" "$pkg"; then known=1; break; fi
  done <<EOT
$backups
EOT
fi
if [ "$known" -eq 0 ]; then
  echo "$pkg is not in the backup and was not installed by us. Nothing was changed. Stopping." >&2
  exit 14
fi

# 8. Never switch off the app the TV currently uses as its Home screen (the TV would be left with none).
COMP_RE='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)*/[A-Za-z0-9_.$]+$'
home_out="$(tv_shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME </dev/null 2>/dev/null)"
rc=$?
home_comp=""
while IFS= read -r line; do
  line="${line%$'\r'}"
  _tv_trim "$line"; [ -n "$TV_TRIMMED" ] && home_comp="$TV_TRIMMED"
done <<EOT
$home_out
EOT
if [ "$rc" -ne 0 ] || ! [[ "$home_comp" =~ $COMP_RE ]]; then
  echo "The TV didn't say which app is its Home screen, so $pkg was left alone. Nothing was changed. Stopping." >&2
  exit 20
fi
if [ "${home_comp%%/*}" = "$pkg" ]; then
  echo "$pkg is the TV's current Home app, so it stays on. Nothing was changed. Stopping." >&2
  exit 10
fi

# is_disabled <pkg>: 0 yes, 1 no, 2 the TV could not answer (failed, or printed something that isn't a list).
is_disabled() {
  local out
  out="$(tv_shell pm list packages -d </dev/null 2>/dev/null)" || return 2
  tv_list_state "$out" "$1"
}

# 9. Already off: nothing to do, nothing to log. No trustworthy answer: stop before changing anything.
is_disabled "$pkg"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "$pkg is already off. Nothing to do."
  exit 0
fi
if [ "$rc" -ne 1 ]; then
  echo "The TV didn't answer when asked about $pkg. Nothing was changed. Stopping." >&2
  exit 20
fi

# 10. Write-ahead: record the package in the undo log BEFORE the change (append only). If that fails,
# nothing is sent to the TV.
log="$backup/disabled-by-us.txt"
log_existed=0
[ -e "$log" ] && log_existed=1
entry="$pkg"$'\t'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sep=""
if [ -f "$log" ] && [ -s "$log" ] && [ -n "$(tail -c 1 "$log" 2>/dev/null)" ]; then sep=$'\n'; fi
if ! { printf '%s%s\n' "$sep" "$entry" >> "$log"; } 2>/dev/null; then
  echo "Can't write the undo log $log. Nothing was changed. Stopping." >&2
  exit 3
fi

# unlog: take our own entry back out (only when the TV clearly did not change anything). Best effort:
# a stale entry is harmless, because restore reports a logged app that is still on as "already on".
unlog() {
  local tmp="$log.tmp.$$" line removed=0
  {
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$removed" -eq 0 ] && [ "${line%$'\r'}" = "$entry" ]; then removed=1; continue; fi
      [ -z "$line" ] && continue
      printf '%s\n' "$line"
    done < "$log"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$log" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  # A log this run created and that now holds nothing (no other run's records) goes again.
  if [ "$log_existed" -eq 0 ] && [ ! -s "$log" ]; then rm -f "$log"; fi
  return 0
}

# 11. The one and only change. No retries.
tv_shell pm disable-user --user 0 "$pkg" </dev/null >/dev/null 2>&1

# 12. Read it back.
is_disabled "$pkg"; rc=$?
if [ "$rc" -eq 0 ]; then
  echo "Turned off $pkg"
  exit 0
fi
if [ "$rc" -eq 1 ]; then
  if unlog; then
    echo "The TV refused to turn off $pkg. Nothing was changed. Stopping." >&2
  else
    echo "The TV refused to turn off $pkg, so nothing was changed on the TV (its line stays in $log; restore will report it as already on). Stopping." >&2
  fi
  exit 20
fi
echo "The TV didn't confirm whether $pkg was turned off, so it MAY be off. It is in the undo list ($log), so scripts/restore will turn it back on. Check before doing anything else. Stopping." >&2
exit 20
