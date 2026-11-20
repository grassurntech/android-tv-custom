#!/usr/bin/env bash
# Installs the built cleanyourtv launcher (com.gathin.tvhome) on the TV through upstream's
# build-and-install.sh, with SKIP_BUILD=1 and STOCK_LAUNCHER=none: upstream never disables anything here.
# The stock launcher is switched off later, separately, with scripts/disable-one.
# Before installing it records what Home is now in home-state.txt (stock_package=, stock_component=, ours=) and,
# after a good install, lists our package in installed-by-us.txt, both in the newest backup folder (the one
# disable-one and restore read). An existing home-state.txt is never overwritten: the stock values must survive.
# If ANY backup already has a home-state.txt (a second session), Home is not read or recorded again: by then it
# may already be our launcher, and the first record is the original stock launcher.
# If upstream fails, it still asks the TV whether our package got installed and, if so, lists it, so restore
# can always switch it off; if the TV can't answer (filtered and unfiltered package lists both fail) it lists it
# anyway, with a warning. Upstream's exit code is passed up either way.
# Optional, only when set in the environment: HOME_KEY_SERVICE and INPUT_KEY_SERVICE, each 0 or 1 (anything else
# is exit 2); 1 is passed to upstream, 0 or unset is not. RESTORE_KEY_SERVICES is not supported in v1: upstream
# always gets 0. Upstream gets TV_HOST=<TV_IP>:<TV_ADB_PORT>.
# Exit: 0 installed, 2 bad arguments or a key-service switch that isn't 0/1, 3 setup missing (TV_IP, vendor or
#       its venv not fetched, APK missing or empty, Home already ours with no recorded stock launcher, Home
#       ambiguous, or Home isn't a normal launcher: the chooser, a setup/provisioning/recovery screen,
#       FallbackHome, or a protected or forbidden package), 13 no usable backup, 20 Home could not be read,
#       21 unreachable, 22 unauthorized; otherwise upstream's own exit code.
export LC_ALL=C
. "$(dirname "$0")/lib/tv-env.sh"

OURS="com.gathin.tvhome"
PKG_RE='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'
COMP_RE='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+$'

if [ "$#" -ne 0 ]; then
  echo "Usage: install-launcher.sh (no arguments)" >&2
  exit 2
fi
tv_load_env
# Checked after tv_load_env, which may set them from the owner's settings file.
for var in HOME_KEY_SERVICE INPUT_KEY_SERVICE; do
  eval "val=\"\${$var:-}\""
  case "$val" in
    ''|0|1) ;;
    *) echo "$var must be 0 or 1 (it is '$val'). Nothing was changed." >&2; exit 2 ;;
  esac
  [ "$val" = "1" ] || unset "$var"   # upstream treats any non-empty value as on
done

backup="$(tv_latest_backup)"
if [ -z "$backup" ]; then
  echo "No backup found. Run scripts/backup first. Nothing was changed. Stopping." >&2
  exit 13
fi

launcher="$REPO_ROOT/vendor/cleanyourtv/launcher"
if [ ! -f "$launcher/build-and-install.sh" ] || [ ! -d "$REPO_ROOT/vendor/cleanyourtv/tools/venv" ]; then
  echo "cleanyourtv is not fetched yet (or its Python environment is missing). Run scripts/fetch-tools.sh first." >&2
  exit 3
fi
if [ ! -s "$launcher/app/build/outputs/apk/release/app-release.apk" ]; then
  echo "The launcher is not built yet (no APK, or an empty one). Run scripts/build-launcher.sh first." >&2
  exit 3
fi

tv_reachable
rc=$?
case "$rc" in
  0)  ;;
  22) echo "Accept 'Allow debugging?' on the TV, then run this again" >&2; exit 22 ;;
  21) echo "Can't reach the TV at $TV_IP" >&2; exit 21 ;;
  *)  exit "$rc" ;;
esac

# Is there a home-state.txt already (in the newest backup, or in any older one)?
state="$backup/home-state.txt"
recorded=""
while IFS= read -r folder; do
  [ -n "$folder" ] || continue
  [ -f "$folder/home-state.txt" ] && recorded="$folder/home-state.txt"   # newest first: the last hit is the oldest
done <<EOT
$(tv_all_backups)
EOT

# not_a_launcher <component>: 0 if Home is something that must never be recorded as the launcher to restore to.
not_a_launcher() {
  local low pkg
  low="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  pkg="${low%%/*}"
  case "$pkg:$low" in
    android:*|*setupwizard*:*|*provision*:*|*initsetup*:*|*setupwraith*:*|*:*recoveryactivity*|*:*fallbackhome*|\
    *:*resolveractivity*|*:*chooser*) return 0 ;;
  esac
  case "$1" in */*) ;; *) return 1 ;; esac
  tv_matches "${1%%/*}" "$REPO_ROOT/config/protected-packages.txt" && return 0
  tv_matches "${1%%/*}" "$REPO_ROOT/config/forbidden-packages.txt" && return 0
  return 1
}

if [ -f "$state" ]; then
  echo "Keeping the Home screen record already in $state"
elif [ -n "$recorded" ]; then
  echo "The original Home screen is already recorded in $recorded, so the current Home is not recorded again."
else
  out="$(tv_shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME </dev/null)"
  rc=$?
  comp=""
  ncomp=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"
    [ -n "$TV_TRIMMED" ] || continue
    comp="$TV_TRIMMED"
    [[ "$TV_TRIMMED" =~ $COMP_RE ]] && ncomp=$((ncomp + 1))
  done <<EOT
$out
EOT
  if [ "$rc" -ne 0 ]; then
    echo "The TV did not say which launcher is the Home screen. Nothing was changed. Stopping." >&2
    exit 20
  fi
  if [ "$ncomp" -gt 1 ]; then
    echo "The TV named more than one Home screen, so it isn't clear which launcher to restore to. Nothing was changed. Stopping." >&2
    exit 3
  fi
  # Never record something that is not a real launcher as the one to restore to.
  if not_a_launcher "$comp"; then
    echo "Home isn't a normal launcher right now ($comp), so it is not a real launcher to restore to: it is Android's chooser, a setup, provisioning or recovery screen, or a system app. Nothing was changed. Stopping." >&2
    exit 3
  fi
  if ! [[ "$comp" =~ $COMP_RE ]] || ! [[ "${comp%%/*}" =~ $PKG_RE ]]; then
    echo "The TV did not say which launcher is the Home screen. Nothing was changed. Stopping." >&2
    exit 20
  fi
  stock="${comp%%/*}"
  if [ "$stock" = "$OURS" ]; then
    echo "Home is already our launcher and no original launcher was recorded, so there is nothing to restore to. Nothing was changed. Stopping." >&2
    exit 3
  else
    tmp="$state.tmp"
    if ! printf 'stock_package=%s\nstock_component=%s\nours=%s\n' "$stock" "$comp" "$OURS" > "$tmp" || ! mv -f "$tmp" "$state"; then
      rm -f "$tmp"
      echo "Can't write $state. Nothing was changed. Stopping." >&2
      exit 3
    fi
    echo "Recorded the current Home screen ($comp) in $state"
  fi
fi

mine="$backup/installed-by-us.txt"
# record_ours: list our package in installed-by-us.txt once (deduplicated).
record_ours() {
  local line found=0
  if [ -f "$mine" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      [ "$line" = "$OURS" ] && found=1
    done < "$mine"
  fi
  if [ "$found" -eq 0 ]; then
    if [ -s "$mine" ] && [ -n "$(tail -c 1 "$mine")" ]; then printf '\n' >> "$mine"; fi
    printf '%s\n' "$OURS" >> "$mine"
  fi
}
# tv_has_ours: 0 if the TV lists our package (exact line), 1 if not, 2 if it could not answer (the filtered
# list failed, and so did the unfiltered one).
tv_has_ours() {
  local out line
  out="$(tv_shell pm list packages "$OURS" </dev/null 2>/dev/null)" ||
    out="$(tv_shell pm list packages </dev/null 2>/dev/null)" || return 2
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"
    [ "$TV_TRIMMED" = "package:$OURS" ] && return 0
  done <<EOT
$out
EOT
  return 1
}

# TV_HOST is IP:port (upstream's tools/tv.py accepts that form), so a custom TV_ADB_PORT reaches the TV.
# RESTORE_KEY_SERVICES is unsupported in v1 and always 0, as in the .ps1 version (which never passes the switch).
( cd "$launcher" && TV_HOST="$SERIAL" SKIP_BUILD=1 STOCK_LAUNCHER=none RESTORE_KEY_SERVICES=0 bash ./build-and-install.sh )
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "The launcher install failed (exit $rc)." >&2
  tv_has_ours
  has=$?
  if [ "$has" -eq 0 ]; then
    record_ours
    echo "Our launcher ($OURS) is on the TV anyway, so it is listed in $mine and restore can switch it off." >&2
  elif [ "$has" -eq 2 ]; then
    record_ours
    echo "Warning: the TV could not say whether our launcher ($OURS) got installed. It is listed in $mine anyway, so restore will try to switch it off." >&2
  fi
  exit "$rc"
fi

record_ours
echo "Our launcher is installed. Follow PROMPT.md Phase 6 for the next step."
exit 0
