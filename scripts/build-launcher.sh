#!/usr/bin/env bash
# Builds the cleanyourtv launcher in Docker, signed with this owner's own key kept in user-content/keystore/
# (git-ignored). The first build creates debug.keystore there; later builds reuse it, so an install over the
# launcher already on the TV keeps working. No arguments. Does not touch the TV.
# Exit: 0 APK built, 2 bad arguments, 3 setup missing (Docker not running, vendor not fetched),
#       1 the build produced no APK; otherwise the upstream build's own exit code.
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
if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Open Docker Desktop and wait until it says running, then run this again." >&2
  exit 3
fi
if ! mkdir -p "$keydir"; then
  echo "Can't create $keydir" >&2
  exit 3
fi

HOST_KEY_DIR="$keydir" bash "$upstream"
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "The launcher build failed (exit $rc)." >&2
  exit "$rc"
fi
if [ ! -f "$apk" ]; then
  echo "The build finished but there is no APK at $apk" >&2
  exit 1
fi
echo "Built $apk"
exit 0
