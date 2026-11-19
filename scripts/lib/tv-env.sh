# Shared helpers for the TV scripts. Source it; do not execute it:
#   . "$(dirname "$0")/lib/tv-env.sh"
# Works on macOS's stock bash 3.2. Reads .env as plain KEY=VALUE lines, never sources it.

TV_LIB_DIR="$(CDPATH= cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$TV_LIB_DIR/../.." && pwd)"

# Trim leading and trailing whitespace of $1 into TV_TRIMMED (no subshell, no sed).
_tv_trim() {
  TV_TRIMMED="$1"
  TV_TRIMMED="${TV_TRIMMED#"${TV_TRIMMED%%[![:space:]]*}"}"
  TV_TRIMMED="${TV_TRIMMED%"${TV_TRIMMED##*[![:space:]]}"}"
}

# Read $REPO_ROOT/.env (if any). Variables that are already set in the environment win.
_tv_read_dotenv() {
  local file="$REPO_ROOT/.env" line key val first last
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#$'\xef\xbb\xbf'}"   # UTF-8 BOM
    _tv_trim "$line"; line="$TV_TRIMMED"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in 'export '*) line="${line#export }" ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    _tv_trim "$key"; key="$TV_TRIMMED"
    _tv_trim "$val"; val="$TV_TRIMMED"
    case "$key" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) continue ;; esac
    if [ "${#val}" -ge 2 ]; then
      first="${val:0:1}"; last="${val: -1}"
      if [ "$first" = "$last" ] && { [ "$first" = '"' ] || [ "$first" = "'" ]; }; then
        val="${val:1:${#val}-2}"
      fi
    fi
    # shellcheck disable=SC2086
    # unset or empty counts as unset (Windows can't hold an empty env var; keeps sh and ps1 identical)
    if eval "[ -z \"\${$key:-}\" ]"; then
      export "$key=$val"
    fi
  done < "$file"
}

# Lexically normalise an absolute /path (drops ".", "..", repeated "/") into TV_NORM. No symlinks resolved.
_tv_norm() {
  local IFS=/ part out=""
  case $- in *f*) local had_f=1 ;; *) local had_f=0 ;; esac
  set -f
  for part in $1; do
    case "$part" in ''|.) ;; ..) out="${out%/*}" ;; *) out="$out/$part" ;; esac
  done
  [ "$had_f" -eq 1 ] || set +f
  TV_NORM="${out:-/}"
}

# Warns (stderr only, never fails) when TV_BACKUP_DIR is inside the repo but not under backups/:
# backups hold serial numbers, and only backups/ is git-ignored.
_tv_check_backup_dir() {
  local bd rr
  case "$TV_BACKUP_DIR" in /*) ;; *) return 0 ;; esac
  _tv_norm "$TV_BACKUP_DIR"; bd="$TV_NORM"
  _tv_norm "$REPO_ROOT"; rr="$TV_NORM"
  case "$bd/" in
    "$rr/backups/"*) ;;
    "$rr/"*) echo "Warning: TV_BACKUP_DIR ($TV_BACKUP_DIR) is inside the project folder but not under backups/, so git may not ignore it. Backups hold serial numbers: move it outside the project or under backups/." >&2 ;;
  esac
  return 0
}

# Sets REPO_ROOT, TV_IP, TV_ADB_PORT, TV_BACKUP_DIR (absolute), ADB, SERIAL. Exits 3 if TV_IP is empty.
tv_load_env() {
  _tv_read_dotenv
  if [ -z "${TV_IP:-}" ]; then
    echo "Create .env from .env.example and set TV_IP" >&2
    exit 3
  fi
  TV_ADB_PORT="${TV_ADB_PORT:-5555}"
  TV_BACKUP_DIR="${TV_BACKUP_DIR:-backups}"
  while [ "${#TV_BACKUP_DIR}" -gt 1 ] && [ "${TV_BACKUP_DIR%/}" != "$TV_BACKUP_DIR" ]; do
    TV_BACKUP_DIR="${TV_BACKUP_DIR%/}"
  done
  case "$TV_BACKUP_DIR" in
    /*|[A-Za-z]:*) ;;
    *) TV_BACKUP_DIR="$REPO_ROOT/$TV_BACKUP_DIR" ;;
  esac
  _tv_check_backup_dir
  if [ -z "${ADB:-}" ]; then
    if [ -x "$REPO_ROOT/tools/platform-tools/adb" ]; then
      ADB="$REPO_ROOT/tools/platform-tools/adb"
    else
      ADB="adb"
    fi
  fi
  SERIAL="$TV_IP:$TV_ADB_PORT"
  export TV_IP TV_ADB_PORT TV_BACKUP_DIR ADB SERIAL
}

# tv_matches <pkg> <listfile>: 0 if the package matches any glob line, 1 if not, exits 3 if the list is missing.
tv_matches() {
  local pkg list="$2" line
  if [ ! -f "$list" ]; then
    echo "Missing list file: $list" >&2
    exit 3
  fi
  pkg="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    _tv_trim "$line"; line="$TV_TRIMMED"
    case "$line" in ''|'#'*) continue ;; esac
    line="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    # shellcheck disable=SC2254
    case "$pkg" in $line) return 0 ;; esac
  done < "$list"
  return 1
}

# Prints every usable backup directory, newest first, one per line: only finished backups named
# YYYY-MM-DD_HHMMSS (never a leftover .partial) whose packages-all.txt is non-empty.
tv_all_backups() {
  local d
  for d in "$TV_BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    case "${d##*/}" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
      *) continue ;;
    esac
    [ -s "$d/packages-all.txt" ] || continue
    printf '%s\n' "$d"
  done | LC_ALL=C sort -r
  return 0
}

# Prints the newest usable backup directory (see tv_all_backups); nothing if there is none.
tv_latest_backup() {
  tv_all_backups | sed -n '1p'
  return 0
}

# Returns 0 if the TV is a usable device, 22 if unauthorized, 21 if unreachable, 3 if adb is missing.
tv_reachable() {
  local out rc
  if ! command -v "$ADB" >/dev/null 2>&1; then
    echo "adb not found ($ADB). Run scripts/fetch-tools or install platform-tools." >&2
    return 3
  fi
  "$ADB" connect "$SERIAL" >/dev/null 2>&1
  out="$("$ADB" -s "$SERIAL" get-state 2>&1)"; rc=$?
  case "$out" in *unauthorized*) return 22 ;; esac
  if [ "$rc" -eq 0 ] && [ "$out" = "device" ]; then return 0; fi
  return 21
}

# tv_shell <cmd...>: run a command on the TV.
tv_shell() {
  "$ADB" -s "$SERIAL" shell "$@"
}
