#!/usr/bin/env bash
# Builds the cleanyourtv launcher in Docker, signed with this owner's own key kept in user-content/keystore/
# (git-ignored, folder 700, files 600). The first build creates debug.keystore there; later builds reuse it, so an
# install over the launcher already on the TV keeps working. If the key is missing but an earlier install is
# recorded (installed-by-us.txt in a backup folder), it warns loudly: an app signed with a new key can't update the
# one on the TV. No arguments. Does not touch the TV.
# The APK must be (re)written by this build: an old one is set aside first and put back only if the build fails.
# Exit: 0 APK built, 2 bad arguments, 3 setup missing (Docker not installed or not running, vendor not fetched),
#       1 the build produced no APK (or an empty one); otherwise the upstream build's own exit code.
export LC_ALL=C
. "$(dirname "$0")/lib/tv-env.sh"

if [ "$#" -ne 0 ]; then
  echo "Usage: build-launcher.sh (no arguments)" >&2
  exit 2
fi

upstream="$REPO_ROOT/vendor/cleanyourtv/tools/docker-build.sh"
apk="$REPO_ROOT/vendor/cleanyourtv/launcher/app/build/outputs/apk/release/app-release.apk"
keydir="$REPO_ROOT/user-content/keystore"

if [ ! -f "$upstream" ]; then
  echo "cleanyourtv is not fetched yet. Run scripts/fetch-tools.sh first." >&2
  exit 3
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker isn't installed. Install Docker Desktop, open it and wait until it says running, then run this again." >&2
  exit 3
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Open Docker Desktop and wait until it says running, then run this again." >&2
  exit 3
fi
if ! ( umask 077 && mkdir -p "$keydir" ) || ! chmod 700 "$keydir"; then
  echo "Can't create $keydir" >&2
  exit 3
fi

# A new key can't update an app the TV already has from an earlier build.
if [ ! -f "$keydir/debug.keystore" ]; then
  if type _tv_read_dotenv >/dev/null 2>&1; then _tv_read_dotenv; fi
  bd="${TV_BACKUP_DIR:-backups}"
  case "$bd" in /*|[A-Za-z]:*) ;; *) bd="$REPO_ROOT/$bd" ;; esac
  for f in "$bd"/*/installed-by-us.txt; do
    if [ -f "$f" ]; then
      echo "WARNING: there is no signing key in $keydir, but our launcher was installed on a TV before ($f)." >&2
      echo "WARNING: this build makes a NEW key. The TV will refuse it as an update to the launcher it already has." >&2
      echo "WARNING: if you still have the old user-content/keystore folder, put it back and build again." >&2
      break
    fi
  done
fi

# Set the old APK aside, so only an APK written by this build counts.
old="$apk.previous"
rm -f "$old"
if [ -f "$apk" ] && ! mv -f "$apk" "$old"; then
  echo "Can't move the old APK out of the way ($apk)." >&2
  exit 3
fi

( umask 077 && HOST_KEY_DIR="$keydir" bash "$upstream" )
rc=$?
chmod 700 "$keydir" 2>/dev/null
for f in "$keydir"/* "$keydir"/.[!.]*; do
  [ -f "$f" ] && chmod 600 "$f" 2>/dev/null
done
if [ "$rc" -ne 0 ]; then
  [ -f "$old" ] && [ ! -f "$apk" ] && mv -f "$old" "$apk"
  echo "The launcher build failed (exit $rc)." >&2
  exit "$rc"
fi
if [ ! -s "$apk" ]; then
  rm -f "$apk"
  [ -f "$old" ] && mv -f "$old" "$apk"
  echo "The build finished but produced no APK at $apk (build produced no APK)." >&2
  exit 1
fi
rm -f "$old"
echo "Built $apk"
exit 0
