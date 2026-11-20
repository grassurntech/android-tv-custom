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
    # A quoted value ends at its closing quote (anything after, like "# my tv", is dropped);
    # an unquoted value ends before a whitespace-led "#" comment.
    first="${val:0:1}"
    if [ "$first" = '"' ] || [ "$first" = "'" ]; then
      last="${val:1}"
      case "$last" in
        *"$first"*) val="${last%%"$first"*}" ;;
      esac
    else
      case "$val" in
        *[[:space:]]#*) val="${val%%[[:space:]]#*}"; _tv_trim "$val"; val="$TV_TRIMMED" ;;
      esac
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

# _tv_resolve <normalised absolute path>: symlinks resolved in the part that exists, into TV_NORM.
_tv_resolve() {
  local p="$1" rest="" real
  while [ ! -d "$p" ] && [ -n "$p" ] && [ "$p" != "/" ]; do
    rest="/${p##*/}$rest"; p="${p%/*}"
  done
  [ -n "$p" ] || p="/"
  if real="$(CDPATH= cd -P -- "$p" 2>/dev/null && pwd -P)"; then
    _tv_norm "$real$rest"
  else
    _tv_norm "$1"
  fi
}

# Warns (stderr only, never fails) when TV_BACKUP_DIR is inside the repo but not under backups/:
# backups hold serial numbers, and only backups/ is git-ignored.
_tv_check_backup_dir() {
  local bd rr lbd lrr rel
  case "$TV_BACKUP_DIR" in /*) ;; *) return 0 ;; esac
  _tv_norm "$TV_BACKUP_DIR"; _tv_resolve "$TV_NORM"; bd="$TV_NORM"
  _tv_norm "$REPO_ROOT"; _tv_resolve "$TV_NORM"; rr="$TV_NORM"
  # "Inside the project" compares case-insensitively (macOS and Windows file systems are); "under backups/"
  # compares exactly, because git's ignore rule is case-sensitive on Linux. ASCII-only lower-casing keeps lengths.
  lbd="$(printf '%s' "$bd" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  lrr="$(printf '%s' "$rr" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  case "$lbd/" in
    "$lrr/"*) ;;
    *) return 0 ;;
  esac
  rel="${bd:${#rr}}/"
  case "$rel" in
    /backups/*) ;;
    *) echo "Warning: TV_BACKUP_DIR ($TV_BACKUP_DIR) is inside the project folder but not under backups/, so git may not ignore it. Backups hold serial numbers: move it outside the project or under backups/." >&2 ;;
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
  # A host name, an IPv4 address or a [bracketed] IPv6 address; never a port, spaces or shell characters.
  if ! [[ "$TV_IP" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && ! [[ "$TV_IP" =~ ^\[[0-9A-Fa-f:.]+\]$ ]]; then
    echo "TV_IP doesn't look like an address: '$TV_IP'. Set it in .env to the TV's IP address only (for example 192.168.1.50; the port goes in TV_ADB_PORT)." >&2
    exit 3
  fi
  if ! [[ "$TV_ADB_PORT" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$TV_ADB_PORT))" -lt 1 ] || [ "$((10#$TV_ADB_PORT))" -gt 65535 ]; then
    echo "TV_ADB_PORT doesn't look like a port number: '$TV_ADB_PORT'. Set it in .env (usually 5555)." >&2
    exit 3
  fi
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

# _tv_list_patterns <listfile>: the list's glob patterns, lower-cased, one per line, into TV_PATTERNS.
# Fails closed: a missing, unreadable, UTF-16 (BOM or NUL bytes) or pattern-less list exits 3.
# Format: one pattern per line; a line starting with # is a comment; anything after the first space,
# tab or # on a pattern line is a comment. LF, CRLF and CR-only line ends and a UTF-8 BOM are fine.
_tv_list_patterns() {
  local list="$1" content line bom n_all n_nul
  TV_PATTERNS=""
  if [ ! -f "$list" ]; then
    echo "Missing list file: $list. Nothing was changed. Stopping." >&2
    exit 3
  fi
  if ! content="$(LC_ALL=C tr '\r' '\n' < "$list" 2>/dev/null)"; then
    echo "Can't read the list file $list. Nothing was changed. Stopping." >&2
    exit 3
  fi
  bom="$(LC_ALL=C head -c 2 "$list" 2>/dev/null | LC_ALL=C od -An -tx1 | tr -d ' \n')"
  n_all="$(LC_ALL=C wc -c < "$list")"
  n_nul="$(LC_ALL=C tr -d '\000' < "$list" | LC_ALL=C wc -c)"
  if [ "$bom" = "fffe" ] || [ "$bom" = "feff" ] || [ "$((n_all))" -ne "$((n_nul))" ]; then
    echo "The list file $list is not plain UTF-8 text (it looks like UTF-16). Save it as UTF-8. Nothing was changed. Stopping." >&2
    exit 3
  fi
  content="$(printf '%s' "$content" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  while IFS= read -r line; do
    line="${line#$'\xef\xbb\xbf'}"
    _tv_trim "$line"; line="$TV_TRIMMED"
    case "$line" in ''|'#'*) continue ;; esac
    line="${line%%[[:space:]]*}"
    line="${line%%#*}"
    [ -n "$line" ] || continue
    TV_PATTERNS="$TV_PATTERNS$line
"
  done <<EOT
$content
EOT
  if [ -z "$TV_PATTERNS" ]; then
    echo "The list file $list has no patterns in it. Nothing was changed. Stopping." >&2
    exit 3
  fi
}

# tv_matches <pkg> <listfile>: 0 if the package matches any glob line (case-insensitive), 1 if not.
# Exits 3 if the list is missing, unreadable, UTF-16 or empty (see _tv_list_patterns).
tv_matches() {
  local pkg line
  _tv_list_patterns "$2"
  pkg="$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2254
    case "$pkg" in $line) return 0 ;; esac
  done <<EOT
$TV_PATTERNS
EOT
  return 1
}

# Files every backup folder must hold (backup.sh writes all of them).
TV_BACKUP_FILES="packages-all.txt packages-disabled.txt getprop.txt settings-global.txt settings-secure.txt settings-system.txt home-activity.txt"

# _tv_valid_stamp <name>: 0 if the name is a real YYYY-MM-DD_HHMMSS time that is not in the future.
_tv_valid_stamp() {
  local n="$1" mo d h mi s now
  case "$n" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  mo=$((10#${n:5:2})); d=$((10#${n:8:2})); h=$((10#${n:11:2})); mi=$((10#${n:13:2})); s=$((10#${n:15:2}))
  [ "$mo" -ge 1 ] && [ "$mo" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ] || return 1
  [ "$h" -le 23 ] && [ "$mi" -le 59 ] && [ "$s" -le 59 ] || return 1
  now="$(date +%Y-%m-%d_%H%M%S)"
  [[ "$n" > "$now" ]] && return 1
  return 0
}

# tv_backup_valid <dir>: 0 if it is a finished backup: a valid timestamp name, every file in
# TV_BACKUP_FILES present, and packages-all.txt holding at least one package: line.
tv_backup_valid() {
  local d="${1%/}" f
  _tv_valid_stamp "${d##*/}" || return 1
  for f in $TV_BACKUP_FILES; do
    [ -f "$d/$f" ] || return 1
  done
  LC_ALL=C grep -q '^[[:space:]]*package:' "$d/packages-all.txt" 2>/dev/null || return 1
  return 0
}

# Prints every usable backup directory (see tv_backup_valid), newest first, one per line.
# Never a leftover .partial, a junk folder or a future-dated one.
tv_all_backups() {
  local d
  for d in "$TV_BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    tv_backup_valid "$d" || continue
    printf '%s\n' "$d"
  done | LC_ALL=C sort -r
  return 0
}

# Prints the newest usable backup directory (see tv_all_backups); nothing if there is none.
tv_latest_backup() {
  tv_all_backups | sed -n '1p'
  return 0
}

# tv_backups_readable: exits 3 if any backup-named folder holds a file this tool reads that can't be read
# (an unreadable file must never look like "no backup" or "nothing to restore").
tv_backups_readable() {
  local d f
  for d in "$TV_BACKUP_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    _tv_valid_stamp "${d##*/}" || continue
    for f in $TV_BACKUP_FILES tv-id.txt disabled-by-us.txt installed-by-us.txt home-state.txt restored.txt; do
      [ -f "$d/$f" ] || continue
      if ! { : < "$d/$f"; } 2>/dev/null; then
        echo "Can't read $d/$f. Fix its permissions, then run this again. Nothing was changed. Stopping." >&2
        exit 3
      fi
    done
  done
  return 0
}

# tv_list_state <output> <pkg>: reads `pm list packages ...` output. 0 the exact package:<pkg> line is
# there, 1 it is not (and every line is a package: line, or there is no output), 2 the output has a
# line that is not a package: line (an error message), so the answer can't be trusted.
tv_list_state() {
  local line found=1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    _tv_trim "$line"; line="$TV_TRIMMED"
    [ -z "$line" ] && continue
    case "$line" in
      package:*) [ "$line" = "package:$2" ] && found=0 ;;
      *) return 2 ;;
    esac
  done <<EOT
$1
EOT
  return "$found"
}

# tv_identity: which TV this is, into TV_ID: ro.serialno, else ro.boot.serialno, else "adb:<SERIAL>".
# Returns 2 if the TV didn't answer.
tv_identity() {
  local key out
  TV_ID=""
  for key in ro.serialno ro.boot.serialno; do
    out="$("$ADB" -s "$SERIAL" shell getprop "$key" </dev/null 2>/dev/null)" || return 2
    out="${out//$'\r'/}"
    _tv_trim "$out"
    if [[ "$TV_TRIMMED" =~ ^[A-Za-z0-9._:-]{1,64}$ ]]; then
      TV_ID="$TV_TRIMMED"
      return 0
    fi
  done
  TV_ID="adb:$SERIAL"
  return 0
}

# tv_backup_id <dir>: the TV identity recorded in that backup's tv-id.txt, into TV_BACKUP_ID (empty if none).
# Exits 3 if the file exists but can't be read.
tv_backup_id() {
  local f="$1/tv-id.txt" line=""
  TV_BACKUP_ID=""
  [ -f "$f" ] || return 0
  if ! { : < "$f"; } 2>/dev/null; then
    echo "Can't read $f. Nothing was changed. Stopping." >&2
    exit 3
  fi
  IFS= read -r line < "$f" || true
  line="${line%$'\r'}"
  line="${line#$'\xef\xbb\xbf'}"
  _tv_trim "$line"
  TV_BACKUP_ID="$TV_TRIMMED"
}

# tv_check_identity <backupdir>: the backup must have been taken on the connected TV.
# Exits 20 if the TV didn't say who it is, 13 if the backup has no identity or another TV's. Sets TV_ID.
tv_check_identity() {
  if ! tv_identity; then
    echo "The TV didn't say which TV it is, so the backup can't be checked. Nothing was changed. Stopping." >&2
    exit 20
  fi
  tv_backup_id "$1"
  if [ -z "$TV_BACKUP_ID" ]; then
    echo "The latest backup ($1) doesn't say which TV it came from. Run scripts/backup on this TV first. Nothing was changed. Stopping." >&2
    exit 13
  fi
  if [ "$TV_BACKUP_ID" != "$TV_ID" ]; then
    echo "The backup is from a different TV (the latest backup, $1, was not taken on the TV at $TV_IP). Run scripts/backup on this TV first. Nothing was changed. Stopping." >&2
    exit 13
  fi
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
