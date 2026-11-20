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
# STOCK_HOME_REDIRECT=1 (needs HOME_KEY_SERVICE=1): Google TV redirect mode, for firmware where the stock launcher
# keeps Home while it is enabled (set-home-activity says Success and changes nothing). Upstream then stops with 1
# before it turns its helpers on. Only in that case, and only if our launcher is installed and Home still resolves
# to the stock launcher recorded in home-state.txt, this script switches on HomeKeyService itself: the TCL
# AUTO_START app-ops (persisted with appops write-settings), then our service added to the accessibility list
# (other services kept; an already-listed one is cleared and written back so Android binds it again), then read
# back. The theme's stock_home_redirect sends the stock home screen to ours. Nothing is ever disabled here, and
# the setup wizard is never touched. Exit 0 when the read-back lists the helper, 20 if it doesn't (or the current
# list holds anything but package/component characters, which is never rewritten), upstream's 1 otherwise.
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
case "${STOCK_HOME_REDIRECT:-}" in
  ''|0) REDIRECT=0 ;;
  1)    REDIRECT=1 ;;
  *) echo "STOCK_HOME_REDIRECT must be 0 or 1 (it is '$STOCK_HOME_REDIRECT'). Nothing was changed." >&2; exit 2 ;;
esac
unset STOCK_HOME_REDIRECT   # ours only: upstream never sees it
if [ "$REDIRECT" = 1 ] && [ "${HOME_KEY_SERVICE:-}" != 1 ]; then
  echo "STOCK_HOME_REDIRECT=1 needs HOME_KEY_SERVICE=1 (the helper that sends Home to the new launcher). Nothing was changed." >&2
  exit 2
fi

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

# read_home: prints the component Home resolves to now (the last component line), empty if the TV can't say.
read_home() {
  local out line comp=""
  out="$(tv_shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME </dev/null)" || return 0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"
    [[ "$TV_TRIMMED" =~ $COMP_RE ]] && comp="$TV_TRIMMED"
  done <<EOT
$out
EOT
  printf '%s' "$comp"
}
# read_services: the accessibility service list, trimmed ("null" when none is set).
read_services() {
  local out
  out="$(tv_shell settings get secure enabled_accessibility_services </dev/null)" || return 1
  out="${out%%$'\n'*}"
  out="${out%$'\r'}"
  _tv_trim "$out"
  printf '%s' "$TV_TRIMMED"
}
# redirect_home: STOCK_HOME_REDIRECT=1 after upstream's 1 (see the header). Returns 0, 1 or 20.
redirect_home() {
  local hs stock home cur new svc="$OURS/.HomeKeyService"
  hs="$state"
  [ -f "$hs" ] || hs="$recorded"
  stock=""
  if [ -n "$hs" ] && [ -f "$hs" ]; then
    stock="$(sed -n 's/^stock_package=//p' "$hs" | tr -d '\r' | head -n 1)"
  fi
  if ! [[ "$stock" =~ $PKG_RE ]]; then
    echo "No recorded original launcher, so redirect mode is not switched on. Home is unchanged." >&2
    return 1
  fi
  home="$(read_home)"
  if [ "${home%%/*}" != "$stock" ]; then
    echo "Home is ${home:-unknown}, not the recorded launcher ($stock), so redirect mode is not switched on. Run restore --home-only and stop." >&2
    return 1
  fi
  echo "Home stays on $stock, as Google TV insists. Switching on the Home helper so it sends Home to the new launcher."
  # TCL firmware only binds an accessibility service of an app allowed to auto-start; other TVs ignore these ops.
  tv_shell cmd appops set "$OURS" AUTO_START allow </dev/null >/dev/null 2>&1
  tv_shell cmd appops set "$OURS" APP_AUTO_START allow </dev/null >/dev/null 2>&1
  tv_shell appops write-settings </dev/null >/dev/null 2>&1
  cur="$(read_services)" || cur="?"
  if [ "$cur" != "null" ] && [ -n "$cur" ] && ! [[ "$cur" =~ ^[A-Za-z0-9_.\$/:]+$ ]]; then
    echo "The TV's accessibility list holds something unexpected, so it is left alone and the Home helper is not switched on. Run restore --home-only and stop." >&2
    return 20
  fi
  case ":$cur:" in
    *":$svc:"*)   # listed already but maybe not bound: clear it, then write it back
      new="$cur"
      tv_shell settings put secure enabled_accessibility_services "''" </dev/null >/dev/null 2>&1
      tv_shell settings put secure accessibility_enabled 0 </dev/null >/dev/null 2>&1 ;;
    ":null:"|"::") new="$svc" ;;
    *)            new="$cur:$svc" ;;
  esac
  tv_shell settings put secure enabled_accessibility_services "$new" </dev/null >/dev/null 2>&1
  tv_shell settings put secure accessibility_enabled 1 </dev/null >/dev/null 2>&1
  cur="$(read_services)" || cur=""
  case ":$cur:" in
    *":$svc:"*)
      echo "Redirect mode is on: Home stays $stock, and the Home helper sends it to the new launcher. Push the theme next (it holds stock_home_redirect)."
      return 0 ;;
  esac
  echo "The TV did not switch on the Home helper (its list reads '${cur:-nothing}'). Run restore --home-only and stop." >&2
  return 20
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
    if [ "$rc" -eq 1 ] && [ "$REDIRECT" = 1 ]; then
      redirect_home
      exit "$?"
    fi
  elif [ "$has" -eq 2 ]; then
    record_ours
    echo "Warning: the TV could not say whether our launcher ($OURS) got installed. It is listed in $mine anyway, so restore will try to switch it off." >&2
  fi
  exit "$rc"
fi

record_ours
echo "Our launcher is installed. Follow PROMPT.md Phase 6 for the next step."
exit 0
