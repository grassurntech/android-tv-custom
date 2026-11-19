#!/usr/bin/env bash
# Fetches adb (Google platform-tools) and cleanyourtv at the pinned commit. No arguments, safe to re-run.
# Exit: 0 done, 3 a tool or download is missing, 30 the upstream copy does not match the pinned commit.
# Env: CLEANYOURTV_URL/TAG/COMMIT override config/upstream.env. FETCH_OFFLINE=1 skips downloads and pip
# (the git clone still runs, so tests can use a local repo). FETCH_SKIP_ADB=1 skips only the adb download.
# Does not need TV_IP or .env. Works on macOS's stock bash 3.2.
TV_LIB_DIR="$(CDPATH= cd -- "$(dirname "$0")/lib" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TV_LIB_DIR/../.." && pwd)"

if [ "$#" -gt 0 ]; then
  echo "Usage: fetch-tools.sh (no arguments)" >&2
  exit 2
fi

# Read config/upstream.env as plain KEY=VALUE lines (never sourced). Variables already set win.
UPSTREAM_FILE="$REPO_ROOT/config/upstream.env"
if [ ! -f "$UPSTREAM_FILE" ]; then
  echo "Missing config/upstream.env (the pinned cleanyourtv version)" >&2
  exit 3
fi
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in CLEANYOURTV_TAG=*|CLEANYOURTV_COMMIT=*|CLEANYOURTV_URL=*) ;; *) continue ;; esac
  key="${line%%=*}"; val="${line#*=}"
  if eval "[ -z \"\${$key:-}\" ]"; then export "$key=$val"; fi
done < "$UPSTREAM_FILE"
if [ -z "${CLEANYOURTV_TAG:-}" ] || [ -z "${CLEANYOURTV_COMMIT:-}" ] || [ -z "${CLEANYOURTV_URL:-}" ]; then
  echo "config/upstream.env must set CLEANYOURTV_TAG, CLEANYOURTV_COMMIT and CLEANYOURTV_URL" >&2
  exit 3
fi

OFFLINE=0; [ "${FETCH_OFFLINE:-}" = "1" ] && OFFLINE=1

if ! command -v git >/dev/null 2>&1; then
  echo "Git is not installed. Install Git (https://git-scm.com), then run this again." >&2
  exit 3
fi

# Step 1: adb
if [ "$OFFLINE" -eq 0 ] && [ "${FETCH_SKIP_ADB:-}" != "1" ] \
   && [ ! -x "$REPO_ROOT/tools/platform-tools/adb" ] && ! command -v adb >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin) PLATFORM=darwin ;;
    Linux)  PLATFORM=linux ;;
    *) echo "Unsupported system for the adb download. Install adb yourself and put it on PATH." >&2; exit 3 ;;
  esac
  for tool in curl unzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "$tool is not installed. Install it, then run this again." >&2
      exit 3
    fi
  done
  mkdir -p "$REPO_ROOT/tools"
  ZIP="$REPO_ROOT/tools/platform-tools.zip"
  echo "Downloading adb (platform-tools)..."
  if ! curl -fL -o "$ZIP" "https://dl.google.com/android/repository/platform-tools-latest-$PLATFORM.zip" \
     || ! unzip -q -o "$ZIP" -d "$REPO_ROOT/tools"; then
    rm -f "$ZIP"
    echo "Could not download or unpack adb. Check your internet connection and run this again." >&2
    exit 3
  fi
  rm -f "$ZIP"
fi

# Step 2 and 3: cleanyourtv at the pinned commit. Never pulled or upgraded.
VENDOR="$REPO_ROOT/vendor/cleanyourtv"
verify_pin() {
  local head dirty
  head="$(git -C "$VENDOR" rev-parse HEAD 2>/dev/null)"
  dirty=""
  if [ "$head" = "$CLEANYOURTV_COMMIT" ]; then
    # edited or extra files would run as "pinned" code; fsmonitor=false stops a tampered .git/config running a command
    dirty="$(git -C "$VENDOR" -c core.fsmonitor=false status --porcelain 2>/dev/null; echo "rc=$?")"
    [ "$dirty" = "rc=0" ] && dirty=""
  fi
  if [ "$head" != "$CLEANYOURTV_COMMIT" ] || [ -n "$dirty" ]; then
    rm -rf "$VENDOR"
    echo "The downloaded cleanyourtv is not the pinned version ($CLEANYOURTV_COMMIT) or has been modified, so it was deleted. Nothing was installed." >&2
    exit 30
  fi
}
if [ ! -e "$VENDOR" ]; then
  mkdir -p "$REPO_ROOT/vendor"
  echo "Cloning cleanyourtv $CLEANYOURTV_TAG..."
  if ! git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$CLEANYOURTV_TAG" "$CLEANYOURTV_URL" "$VENDOR"; then
    rm -rf "$VENDOR"
    echo "Could not download cleanyourtv. Check your internet connection and run this again." >&2
    exit 3
  fi
fi
verify_pin

# Step 4: Python environments (network)
if [ "$OFFLINE" -eq 0 ]; then
  if command -v python3 >/dev/null 2>&1; then PY=python3
  else
    echo "Python 3 is not installed. Install Python 3 (https://www.python.org), then run this again." >&2
    exit 3
  fi
  UPSTREAM_REQ="$VENDOR/tools/requirements.txt"
  if [ ! -f "$UPSTREAM_REQ" ]; then
    echo "cleanyourtv has no tools/requirements.txt at the pinned version" >&2
    exit 3
  fi
  if [ ! -x "$VENDOR/tools/venv/bin/python" ]; then
    "$PY" -m venv "$VENDOR/tools/venv" || { echo "Could not create the Python environment for cleanyourtv" >&2; exit 3; }
  fi
  "$VENDOR/tools/venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$UPSTREAM_REQ" \
    || { echo "Could not install cleanyourtv's Python packages. Check your internet connection." >&2; exit 3; }
  if [ ! -x "$REPO_ROOT/.venv/bin/python" ]; then
    "$PY" -m venv "$REPO_ROOT/.venv" || { echo "Could not create the Python environment" >&2; exit 3; }
  fi
  "$REPO_ROOT/.venv/bin/python" -m pip install --quiet --disable-pip-version-check -r "$REPO_ROOT/requirements.txt" \
    || { echo "Could not install the Python packages. Check your internet connection." >&2; exit 3; }
fi

echo "Tools are ready."
exit 0
