#!/usr/bin/env bash
# Installs the built cleanyourtv launcher (com.gathin.tvhome) on the TV through upstream's
# build-and-install.sh, with SKIP_BUILD=1 and STOCK_LAUNCHER=none: upstream never disables anything here.
# The stock launcher is switched off later, separately, with scripts/disable-one.
# Before installing it records what Home is now in home-state.txt (stock_package=, stock_component=, ours=) and,
# after a good install, lists our package in installed-by-us.txt, both in the newest backup folder (the one
# disable-one and restore read). An existing home-state.txt is never overwritten: the stock values must survive.
# If upstream fails, it still asks the TV whether our package got installed and, if so, lists it, so restore
# can always switch it off; upstream's exit code is passed up either way.
# Optional, only when set in the environment: HOME_KEY_SERVICE=1, INPUT_KEY_SERVICE=1 (passed to upstream).
# Exit: 0 installed, 2 bad arguments, 3 setup missing (TV_IP, vendor or its venv not fetched, Home already ours
#       with no recorded stock launcher), 13 no usable backup, 20 Home could not be read, 21 unreachable,
#       22 unauthorized; otherwise upstream's own exit code.
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
if [ ! -f "$launcher/app/build/outputs/apk/release/app-release.apk" ]; then
  echo "The launcher is not built yet. Run scripts/build-launcher.sh first." >&2
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
have_any=0
while IFS= read -r folder; do
  [ -n "$folder" ] || continue
  if [ -f "$folder/home-state.txt" ]; then have_any=1; break; fi
done <<EOT
$(tv_all_backups)
EOT

if [ -f "$state" ]; then
  echo "Keeping the Home screen record already in $state"
else
  out="$(tv_shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME </dev/null)"
  rc=$?
  comp=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"; [ -n "$TV_TRIMMED" ] && comp="$TV_TRIMMED"
  done <<EOT
$out
EOT
  if [ "$rc" -ne 0 ] || ! [[ "$comp" =~ $COMP_RE ]] || ! [[ "${comp%%/*}" =~ $PKG_RE ]]; then
    echo "The TV did not say which launcher is the Home screen. Nothing was changed. Stopping." >&2
    exit 20
  fi
  stock="${comp%%/*}"
  if [ "$stock" = "$OURS" ]; then
    if [ "$have_any" -eq 1 ]; then
      echo "Home is already our launcher; the original one is recorded in an earlier backup."
    else
      echo "Home is already our launcher and no original launcher was recorded, so there is nothing to restore to. Nothing was changed. Stopping." >&2
      exit 3
    fi
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
# tv_has_ours: 0 if the TV lists our package (exact line), 1 if not or if it could not answer.
tv_has_ours() {
  local out line
  out="$(tv_shell pm list packages "$OURS" </dev/null 2>/dev/null)" || return 1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"
    [ "$TV_TRIMMED" = "package:$OURS" ] && return 0
  done <<EOT
$out
EOT
  return 1
}

( cd "$launcher" && TV_HOST="$TV_IP" SKIP_BUILD=1 STOCK_LAUNCHER=none bash ./build-and-install.sh )
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "The launcher install failed (exit $rc)." >&2
  if tv_has_ours; then
    record_ours
    echo "Our launcher ($OURS) is on the TV anyway, so it is listed in $mine and restore can switch it off." >&2
  fi
  exit "$rc"
fi

record_ours
echo "Installed $OURS. The original launcher is still on; turn it off with scripts/disable-one when you are ready."
exit 0
