#!/usr/bin/env bash
# Undoes what this tool changed on the TV. Never uninstalls anything.
#   restore.sh [--home-only | --packages-only]     (default: both, Home first)
# Home:     turn the stock launcher back on, make it Home again, then switch OUR launcher off
#           (through disable-one.sh, the only script that disables anything).
# Packages: turn back on every package listed in any backup's disabled-by-us.txt that the TV currently
#           shows as disabled (each distinct package once; restored.txt is only a record), one `pm enable` at a time, newest backup first. A TV refusal stops it.
# Exit: 0 done (or nothing to do), 2 bad arguments, 3 setup missing or a file is unreadable,
#       13 no usable backup, 20 TV refused, 21 unreachable, 22 unauthorized; a failed Home disable
#       passes disable-one's own exit code up unchanged.
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

# 2. Config, then at least one usable backup.
tv_load_env
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

# adb must never read the loop's stdin.
tv_run() { tv_shell "$@" </dev/null; }

# is_disabled <pkg>: 0 yes, 1 no, 2 the TV could not answer.
is_disabled() {
  local out line
  out="$(tv_run pm list packages -d)" || return 2
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"; line="$TV_TRIMMED"
    [ "$line" = "package:$1" ] && return 0
  done <<EOT
$out
EOT
  return 1
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
state_value() {
  local line
  VALUE=""
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
home_done=0

# ---- Home ------------------------------------------------------------------------------------
restore_home() {
  local folder hs="" stock_pkg stock_comp rc
  while IFS= read -r folder; do
    if [ -f "$folder/home-state.txt" ]; then hs="$folder/home-state.txt"; break; fi
  done <<EOT
$backups
EOT
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

  tv_run pm enable "$stock_pkg" >/dev/null 2>&1
  is_disabled "$stock_pkg"; rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "The TV would not turn the original launcher ($stock_pkg) back on. Home was left as it was and nothing else was restored. Stopping." >&2
    exit 20
  fi
  if ! tv_run cmd package set-home-activity --user 0 "$stock_comp" >/dev/null 2>&1; then
    echo "The original launcher ($stock_pkg) is on again, but the TV would not make it the Home screen. Our launcher was left on and nothing else was restored. Stopping." >&2
    exit 20
  fi
  echo "The original launcher ($stock_pkg) is back as the Home screen."
  bash "$SCRIPT_DIR/disable-one.sh" "$ours"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Say what the TV really looks like now (disable-one may have switched it off before failing to log).
    is_disabled "$ours"
    if [ "$?" -eq 0 ]; then
      echo "The original launcher is back and our launcher ($ours) is off, but disable-one reported a problem afterwards. Packages were not restored. Stopping." >&2
    else
      echo "The original launcher is back, but our launcher ($ours) is still on. Packages were not restored. Stopping." >&2
    fi
    exit "$rc"
  fi
  home_done=1
}

# ---- Packages --------------------------------------------------------------------------------
restore_packages() {
  local folder log res line pkg now n=0 skipped=0 lineno rc seen=""
  while IFS= read -r folder; do
    log="$folder/disabled-by-us.txt"
    res="$folder/restored.txt"
    [ -f "$log" ] || continue
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
      is_disabled "$pkg"; rc=$?
      if [ "$rc" -eq 2 ]; then
        echo "The TV didn't answer when asked about $pkg. Restored $n so far. Not restored: $pkg and everything after it. Stopping." >&2
        exit 20
      fi
      if [ "$rc" -eq 0 ]; then
        tv_run pm enable "$pkg" >/dev/null 2>&1
        is_disabled "$pkg"; rc=$?
        if [ "$rc" -ne 1 ]; then
          echo "The TV refused to turn $pkg back on. Restored $n so far. Not restored: $pkg and everything after it in the log. Stopping." >&2
          exit 20
        fi
        echo "Turned $pkg back on"
      else
        echo "$pkg was already on."
        if in_restored "$res" "$pkg"; then continue; fi
      fi
      now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if ! printf '%s\t%s\n' "$pkg" "$now" >> "$res"; then
        echo "The TV DID turn $pkg back on, but $res could not be written. Restored $n so far. Stopping." >&2
        exit 20
      fi
      n=$((n + 1))
    done < "$log"
  done <<EOT
$backups
EOT
  if [ "$skipped" -gt 0 ]; then
    echo "Left our own launcher ($OUR_LAUNCHER) switched off, as intended."
  fi
  if [ "$n" -eq 0 ]; then
    echo "No apps needed turning back on."
  else
    echo "Turned $n app(s) back on."
  fi
}

if [ "$do_home" -eq 1 ]; then restore_home; fi
if [ "$do_pkgs" -eq 1 ]; then restore_packages; fi
exit 0
