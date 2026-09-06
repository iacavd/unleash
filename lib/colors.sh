# shellcheck shell=bash
RED='\033[1;31m'
GRN='\033[1;32m'
BLU='\033[1;34m'
YEL='\033[1;33m'
CYAN='\033[1;36m'
MAG='\033[1;35m'
NC='\033[0m'

LOG_FILE=""
VERBOSE=false
# shellcheck disable=SC2034
DRY_RUN=false

log() {
  local level="${1:-INFO}"
  if [ $# -gt 0 ]; then
    shift
  fi

  local module="unleash"
  local event="log"
  local msg=""

  if [ $# -ge 3 ]; then
    module="$1"
    event="$2"
    shift 2
    msg="$*"
  else
    msg="$*"
  fi

  local level_kv=""
  local color=""
  local label=""

  case "$level" in
    ERROR|error) level_kv="error"; color="$RED";  label="ERR" ;;
    WARN|warn)   level_kv="warn";  color="$YEL";  label="WRN" ;;
    OK|ok)       level_kv="ok";    color="$GRN";  label=" OK" ;;
    INFO|info)   level_kv="info";  color="$BLU";  label="INF" ;;
    STEP|step)   level_kv="step";  color="$CYAN"; label="STP" ;;
    DEBUG|debug) level_kv="debug"; color="$MAG";  label="DBG" ;;
    *)           level_kv="info";  color="$NC";   label="LOG" ;;
  esac

  if [ "$level_kv" = "debug" ] && [ "$VERBOSE" = false ]; then
    return 0
  fi

  msg="${msg//$'\n'/ }"
  msg="${msg//$'\r'/ }"

  local ts
  ts=$(date '+%Y-%m-%dT%H:%M:%S')
  local kv="ts=${ts} level=${level_kv} module=${module} event=${event} msg=${msg}"

  if [ -t 2 ]; then
    printf '%b%s\n' "${color}[${label}]${NC} " "$kv" >&2
  else
    printf '%s\n' "$kv" >&2
  fi

  if [ -n "$LOG_FILE" ]; then
    if ! printf '%s\n' "$kv" >> "$LOG_FILE"; then
      local bad_path="$LOG_FILE"
      # Avoid recursing into another failed append via error_exit → log.
      LOG_FILE=""
      error_exit "ERROR E_LOG_UNWRITABLE: cannot write log file '${bad_path}'. Next: pass --log-file to a writable path."
    fi
  fi
}

set_log_file() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    LOG_FILE=""
    return 0
  fi
  if ! : >> "$path"; then
    error_exit "ERROR E_LOG_UNWRITABLE: cannot write log file '${path}'. Next: pass --log-file to a writable path."
  fi
  LOG_FILE="$path"
}

error_exit() {
  log "ERROR" "$1"
  exit 1
}

warn() {
  log "WARN" "$@"
}

success() {
  log "OK" "$@"
}

info() {
  log "INFO" "$@"
}

step() {
  log "STEP" "$@"
}

debug() {
  log "DEBUG" "$@"
}

header() {
  local title="$1"
  log "INFO" "unleash" "header" "$title"
}

begin() {
  log "STEP" "unleash" "begin" "$1"
}

spinner() {
  local pid="$1"
  local msg="${2:-Working}"
  local spin='-\|/'
  local i=0
  if [ ! -t 2 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      sleep 0.2
    done
    return 0
  fi
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf '\r%b%s%b' "$CYAN" "  ${msg} ... ${spin:$i:1}" "$NC" >&2
    sleep 0.2
  done
  printf '\r%b%s%b' "$CYAN" "  ${msg} ... " "$NC" >&2
}

end_ok() {
  log "OK" "unleash" "end" "ok"
}

end_fail() {
  log "ERROR" "unleash" "end" "fail"
}

prompt_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default="$3"
  local value
  if [ -t 2 ]; then
    printf '%b' "${CYAN}${prompt_text}${NC} (default '${default}'): " >&2
  else
    printf '%s' "${prompt_text} (default '${default}'): " >&2
  fi
  read -r value
  value="${value:=$default}"
  eval "$var_name=\"$value\""
}

confirm() {
  local prompt="$1"
  local response
  printf '%s' "${prompt} (y/N): " >&2
  read -r response
  [[ "$response" =~ ^[Yy]$ ]]
}
