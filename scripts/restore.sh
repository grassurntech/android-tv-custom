#!/usr/bin/env bash
# Undoes what this tool changed on the TV. Never uninstalls anything.
#   restore.sh [--home-only | --packages-only]     (default: both, Home first)
# Only backups taken on the connected TV are used (tv-id.txt); the newest must match, else exit 13.
# Home:     the stock launcher comes from the OLDEST home-state.txt (a later install can record our own
#           launcher as "stock"). It must still be installed; it is turned back on, made Home, then OUR
#           launcher is switched off (through disable-one.sh, the only script that disables anything, which
#           refuses the current Home app; skipped if ours was never installed), the stock launcher is made
#           Home again (switching ours off drops the Home choice), then Home is read back. Only a matching
#           read-back counts as done.
# Packages: turn back on every package listed in any backup's disabled-by-us.txt that the TV currently
#           shows as disabled (each distinct package once; restored.txt is only a record), one `pm enable` at a time, newest backup first. A TV refusal stops it.
#           Our launcher and the stock launcher from home-state.txt are skipped: the Home step owns both.
#           A logged app that is on already is reported "already on"; one no longer installed is skipped.
# Exit: 0 done (or nothing to do), 2 bad arguments, 3 setup missing or a local file is unreadable or
#       can't be written (restored.txt: the TV work still completes first), 13 no usable backup or the
#       backup is from another TV, 20 TV refused or gave no trustworthy answer (or Home did not read back as
#       the stock launcher), 21 unreachable (also mid-run), 22 unauthorized; a failed Home disable passes
#       disable-one's own exit code up unchanged.
export LC_ALL=C
. "$(dirname "$0")/lib/tv-env.sh"

OUR_LAUNCHER="com.gathin.tvhome"
PKG_RE='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
COMP_RE='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+$'

# 1. Arguments.
do_home=1; do_pkgs=1
case "$#:${1:-}" in
  0:) ;;
  1:--home-only) do_pkgs=0 ;;
  1:--packages-only) do_home=0 ;;
  *)
    echo "Usage: restore.sh [--home-only | --packages-only]" >&2
    exit 2 ;;
esac

# 2. Config, then at least one usable backup (every backup file readable, else exit 3).
tv_load_env
tv_backups_readable
backups="$(tv_all_backups)"
if [ -z "$backups" ]; then
  echo "No backup found, so there is nothing to restore from. Nothing was changed. Stopping." >&2
  exit 13
fi

# 3. The TV must be reachable.
tv_reachable
rc=$?
case "$rc" in
  0)  ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac

# 4. Only backups of this TV; the newest must be one of them (sets TV_ID).
tv_check_identity "$(printf '%s\n' "$backups" | sed -n '1p')"
mine=""
while IFS= read -r folder; do
  [ -n "$folder" ] || continue
  tv_backup_id "$folder"
  [ "$TV_BACKUP_ID" = "$TV_ID" ] && mine="$mine$folder
"
done <<EOT
$backups
EOT
backups="${mine%
}"

# adb must never read the loop's stdin.
tv_run() { tv_shell "$@" </dev/null; }

# is_disabled <pkg>: 0 yes, 1 no, 2 the TV could not answer (failed, or printed something that isn't a list).
is_disabled() {
  local out
  out="$(tv_run pm list packages -d 2>/dev/null)" || return 2
  tv_list_state "$out" "$1"
}

# unreachable_exit <what>: after a failed read-back, exit 21 if the TV has gone, else return.
unreachable_exit() {
  tv_reachable >/dev/null 2>&1
  if [ "$?" -eq 21 ]; then
    echo "Can't reach the TV at $TV_IP any more. $1 Stopping." >&2
    exit 21
  fi
}

# first_field <line>: the text before the first tab, trimmed, without CR or BOM, into FIELD.
first_field() {
  FIELD="${1%$'\r'}"
  FIELD="${FIELD#$'\xef\xbb\xbf'}"
  FIELD="${FIELD%%$'\t'*}"
  _tv_trim "$FIELD"; FIELD="$TV_TRIMMED"
}

# in_restored <file> <pkg>: 0 if the pkg is already a line of that restored.txt.
in_restored() {
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    first_field "$line"
    [ "$FIELD" = "$2" ] && return 0
  done < "$1"
  return 1
}

# state_value <file> <key>: the value of the first `key=value` line, into VALUE (empty if none).
# Exits 3 if the file can't be read.
state_value() {
  local line
  VALUE=""
  if ! { : < "$1"; } 2>/dev/null; then
    echo "Can't read $1. Nothing was changed. Stopping." >&2
    exit 3
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"
    _tv_trim "$line"; line="$TV_TRIMMED"
    case "$line" in
      "$2="*) _tv_trim "${line#*=}"; VALUE="$TV_TRIMMED"; return 0 ;;
    esac
  done < "$1"
  return 1
}

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ours="$OUR_LAUNCHER"
STAY_ON="Please leave the TV switched on. Don't unplug it or restart it."

# is_installed <pkg>: 0 the TV lists it (exact line), 1 it does not, 2 the TV could not answer.
is_installed() {
  local out
  out="$(tv_run pm list packages "$1" 2>/dev/null)" || return 2
  tv_list_state "$out" "$1"
}

# find_home_state: the OLDEST backup's home-state.txt into HS (empty if none), and the newest into HS_NEW.
# The oldest records the launcher the TV came with; a later install can record our own launcher as stock.
find_home_state() {
  local folder
  HS=""; HS_NEW=""
  while IFS= read -r folder; do
    [ -n "$folder" ] || continue
    if [ -f "$folder/home-state.txt" ]; then
      HS="$folder/home-state.txt"
      [ -z "$HS_NEW" ] && HS_NEW="$HS"
    fi
  done <<EOT
$backups
EOT
  return 0
}

# ---- Home ------------------------------------------------------------------------------------
# Order: stock launcher on, ours off, stock made Home, then read Home back. Switching ours off changes
# the set of Home apps, which makes Android drop the Home choice, so Home is set only after that.
restore_home() {
  local hs stock_pkg stock_comp rc out line comp newest_stock
  find_home_state; hs="$HS"
  if [ -z "$hs" ]; then
    echo "No home-state.txt in any backup, so the Home screen was never changed. Skipping the Home step."
    return 0
  fi
  state_value "$hs" stock_package;   stock_pkg="$VALUE"
  state_value "$hs" stock_component; stock_comp="$VALUE"
  state_value "$hs" ours;            [ -n "$VALUE" ] && ours="$VALUE"
  if ! [[ "$stock_pkg" =~ $PKG_RE ]] || ! [[ "$stock_comp" =~ $COMP_RE ]] || ! [[ "$ours" =~ $PKG_RE ]]; then
    echo "$hs is missing or has a bad stock_package, stock_component or ours line. Nothing was changed. Stopping." >&2
    exit 3
  fi
  if [ "$HS_NEW" != "$hs" ]; then
    state_value "$HS_NEW" stock_component; newest_stock="$VALUE"
    if [ "$newest_stock" != "$stock_comp" ]; then
      echo "Backups disagree about the original launcher; using the oldest record ($hs: $stock_comp), not the newest ($HS_NEW: ${newest_stock:-nothing})."
    fi
  fi

  # 1. The stock launcher must still be installed, then back on. Until it is, ours is never touched.
  is_installed "$stock_pkg"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "The TV didn't say whether the original launcher ($stock_pkg) is installed, so its state is unknown. Nothing was changed. Stopping." >&2
    exit 20
  fi
  if [ "$rc" -eq 1 ]; then
    echo "The original launcher ($stock_pkg) is no longer installed on the TV, so our launcher stays on as the Home screen. Nothing was changed. Stopping." >&2
    exit 20
  fi
  tv_run pm enable "$stock_pkg" >/dev/null 2>&1
  is_disabled "$stock_pkg"; rc=$?
  if [ "$rc" -ne 1 ]; then
    [ "$rc" -eq 2 ] && unreachable_exit "The original launcher ($stock_pkg) may or may not be on again; nothing else was changed."
    echo "The TV would not turn the original launcher ($stock_pkg) back on. Home was left as it was and nothing else was restored. Stopping." >&2
    exit 20
  fi
  echo "The original launcher ($stock_pkg) is on again."

  # 2. Our launcher off, through disable-one (skipped when it never got installed). disable-one refuses the
  # current Home app, so the stock launcher is made Home first.
  is_installed "$ours"; rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "The original launcher is on again, but the TV didn't say whether our launcher ($ours) is installed, so its state is unknown. Home was not changed and packages were not restored. Stopping." >&2
    exit 20
  fi
  if [ "$rc" -eq 1 ]; then
    echo "Our launcher ($ours) is not installed on the TV, so there is nothing to switch off."
  else
    if ! tv_run cmd package set-home-activity --user 0 "$stock_comp" >/dev/null 2>&1; then
      echo "The original launcher ($stock_pkg) is on again, but the TV would not make it the Home screen, so our launcher ($ours) was left on. Packages were not restored. Stopping." >&2
      exit 20
    fi
    bash "$SCRIPT_DIR/disable-one.sh" "$ours"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      # Say what the TV really looks like now (disable-one may have switched it off before failing to confirm).
      is_disabled "$ours"
      case "$?" in
        0) echo "The original launcher is on again and our launcher ($ours) is off, but disable-one reported a problem afterwards. Home was not confirmed and packages were not restored. $STAY_ON Stopping." >&2 ;;
        1) echo "The original launcher is on again, but our launcher ($ours) is still on, so Home was not confirmed. Packages were not restored. Stopping." >&2 ;;
        *) echo "The original launcher is on again, but the TV didn't say whether our launcher ($ours) is off, so its state is unknown. Home was not confirmed and packages were not restored. $STAY_ON Stopping." >&2 ;;
      esac
      exit "$rc"
    fi
  fi

  # 3. Make the stock launcher Home (again: switching ours off changes the set of Home apps).
  if ! tv_run cmd package set-home-activity --user 0 "$stock_comp" >/dev/null 2>&1; then
    echo "The TV would not make the original launcher ($stock_comp) the Home screen. Packages were not restored. $STAY_ON Stopping." >&2
    exit 20
  fi

  # 4. Read Home back: the last non-empty line must be the stock component.
  out="$(tv_run cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null)"
  rc=$?
  comp=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"; [ -n "$TV_TRIMMED" ] && comp="$TV_TRIMMED"
  done <<EOT
$out
EOT
  if [ "$rc" -ne 0 ] || [ "$comp" != "$stock_comp" ]; then
    echo "The TV did not confirm the original launcher as the Home screen (it says: ${comp:-nothing}). Packages were not restored. $STAY_ON Stopping." >&2
    exit 20
  fi
  echo "The original launcher ($stock_pkg) is back as the Home screen."
}

# ---- Packages --------------------------------------------------------------------------------
restore_packages() {
  local folder log res line pkg now n=0 skipped=0 lineno rc seen="" stock="" left_stock=0
  # The stock launcher belongs to the Home step: switching it on while ours is Home can drop the Home choice.
  find_home_state
  if [ -n "$HS" ]; then
    state_value "$HS" stock_package; stock="$VALUE"
    if ! [[ "$stock" =~ $PKG_RE ]]; then
      echo "$HS is missing or has a bad stock_package line. Nothing was changed. Stopping." >&2
      exit 3
    fi
  fi
  while IFS= read -r folder; do
    log="$folder/disabled-by-us.txt"
    res="$folder/restored.txt"
    [ -f "$log" ] || continue
    if ! { : < "$log"; } 2>/dev/null; then
      echo "Can't read the undo log $log. Restored $n so far. Stopping." >&2
      exit 3
    fi
    lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
      lineno=$((lineno + 1))
      first_field "$line"; pkg="$FIELD"
      [ -z "$pkg" ] && continue
      if ! [[ "$pkg" =~ $PKG_RE ]]; then
        echo "Line $lineno of $log is not a package name. Restored $n so far; stopping before changing anything else." >&2
        exit 3
      fi
      # Each distinct package once. The TV's state decides, not restored.txt (which is only a record).
      case "$seen" in *"
$pkg
"*) continue ;; esac
      seen="$seen
$pkg
"
      # Our own launcher stays switched off (it is never re-enabled by a restore).
      if [ "$pkg" = "$OUR_LAUNCHER" ] || [ "$pkg" = "$ours" ]; then
        skipped=$((skipped + 1)); continue
      fi
      if [ -n "$stock" ] && [ "$pkg" = "$stock" ]; then
        left_stock=1; continue
      fi
      is_disabled "$pkg"; rc=$?
      if [ "$rc" -eq 2 ]; then
        echo "The TV didn't answer when asked about $pkg. Restored $n so far. Not restored: $pkg and everything after it. Stopping." >&2
        exit 20
      fi
      if [ "$rc" -eq 0 ]; then
        tv_run pm enable "$pkg" >/dev/null 2>&1
        is_disabled "$pkg"; rc=$?
        if [ "$rc" -eq 2 ]; then
          unreachable_exit "$pkg may or may not be on again. Restored $n so far; run restore again once the TV is back."
          echo "The TV didn't confirm whether $pkg is back on. Restored $n so far. Not restored: $pkg and everything after it in the log. Stopping." >&2
          exit 20
        fi
        if [ "$rc" -ne 1 ]; then
          echo "The TV refused to turn $pkg back on. Restored $n so far. Not restored: $pkg and everything after it in the log. Stopping." >&2
          exit 20
        fi
        echo "Turned $pkg back on"
      else
        is_installed "$pkg"; rc=$?
        if [ "$rc" -eq 2 ]; then
          echo "The TV didn't answer when asked about $pkg. Restored $n so far. Not restored: $pkg and everything after it. Stopping." >&2
          exit 20
        fi
        if [ "$rc" -eq 1 ]; then
          echo "$pkg is no longer installed on the TV, so there is nothing to turn back on."
          continue
        fi
        echo "$pkg was already on."
        if in_restored "$res" "$pkg"; then continue; fi
      fi
      n=$((n + 1))
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if ! { printf '%s\t%s\n' "$pkg" "$now" >> "$res"; } 2>/dev/null; then
        # Only a record: keep going with the TV work and report the file problem at the end (exit 3).
        echo "Couldn't write $res (only a record; $pkg is on). Carrying on." >&2
        rec_fail=1
      fi
    done < "$log"
  done <<EOT
$backups
EOT
  if [ "$skipped" -gt 0 ]; then
    echo "Left our own launcher ($OUR_LAUNCHER) switched off, as intended."
  fi
  if [ "$left_stock" -eq 1 ] && [ "$do_home" -eq 0 ]; then
    echo "The original launcher ($stock) is handled by the Home step, so --packages-only did not change it."
  fi
  if [ "$n" -eq 0 ]; then
    echo "No apps needed turning back on."
  else
    echo "Turned $n app(s) back on."
  fi
}

rec_fail=0
if [ "$do_home" -eq 1 ]; then restore_home; fi
if [ "$do_pkgs" -eq 1 ]; then restore_packages; fi
if [ "$rec_fail" -ne 0 ]; then
  echo "The TV restore finished, but the record file restored.txt could not be written. Fix its permissions; running restore again is safe." >&2
  exit 3
fi
exit 0
