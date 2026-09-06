# shellcheck shell=bash
# Typed results: helpers always return 0 so set -e cannot abort on skip.
# Status is RESULT_* globals.
#
# Process exits 0, 1, 2, 3, 4 only:
#   0  all required ok, or skip-class that does not degrade
#      (S_ALREADY_OK, S_FV_ADD, S_PF_RECOVERY, S_NO_PROFILES_CMD, S_NO_DSCACHEUTIL, S_LIVE_ONLY)
#   1  usage / error_exit / rollback after required mutate fail
#      (error_exit stays 1; E_LOG_UNWRITABLE is exit 1)
#   2  preflight, no mutation
#      (E_VOLUME_*, E_FV_*, E_CREDS_REQUIRED, E_DEFAULT_PASSWORD, E_INTENT_MISSING,
#       E_DISK_FULL, E_PREFLIGHT_TOOLS, E_NOT_ROOT, E_LOCKED)
#   3  degraded after some mutation (S_SIP_LIVE, E_PFCTL_FAIL after hosts ok, …)
#   4  mutate ok but probes fail
# error_exit (lib/colors.sh) remains exit 1 for usage/unhandled abort.

RESULT_STATUS=ok      # ok | skip | fail
RESULT_REASON=""      # E_* / S_* / empty
RESULT_MSG=""
# shellcheck disable=SC2034
RESULT_MODULE=""
# shellcheck disable=SC2034
RESULT_EVENT=""

result_ok() {   # $1=module $2=event $3=msg
  RESULT_STATUS=ok
  RESULT_REASON=""
  RESULT_MSG="$3"
  # shellcheck disable=SC2034
  RESULT_MODULE="$1"
  # shellcheck disable=SC2034
  RESULT_EVENT="$2"
  log INFO "$1" "$2" "$3"
  return 0
}

result_skip() { # $1=reason $2=module $3=event $4=msg
  RESULT_STATUS=skip
  RESULT_REASON="$1"
  RESULT_MSG="$4"
  # shellcheck disable=SC2034
  RESULT_MODULE="$2"
  # shellcheck disable=SC2034
  RESULT_EVENT="$3"
  log WARN "$2" "$3" "$4 reason=$1"
  return 0
}

result_fail() { # $1=reason $2=module $3=event $4=msg
  RESULT_STATUS=fail
  RESULT_REASON="$1"
  RESULT_MSG="$4"
  # shellcheck disable=SC2034
  RESULT_MODULE="$2"
  # shellcheck disable=SC2034
  RESULT_EVENT="$3"
  log ERROR "$2" "$3" "$4 reason=$1"
  return 0
}

# json_escape STRING → stdout (no trailing newline).
# Byte-wise over ${#s} / ${s:i:1} (bash 3.2). Map:
#   \ → \\   " → \"   newline → \n   CR → \r   tab → \t
# No other Unicode handling; UTF-8 path bytes copy through.
json_escape() {
  local s="${1-}"
  local i=0
  local c
  local out=""
  local len=${#s}
  while [ "$i" -lt "$len" ]; do
    c="${s:i:1}"
    case "$c" in
      \\) out="${out}\\\\" ;;
      \") out="${out}\\\"" ;;
      $'\n') out="${out}\\n" ;;
      $'\r') out="${out}\\r" ;;
      $'\t') out="${out}\\t" ;;
      *) out="${out}${c}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# emit_json EXIT NEXT [VOLUME] — one JSON object to stdout.
# ok/reason/message from RESULT_*; string fields go through json_escape.
# Later pipeline fills steps; logs stay on stderr.
emit_json() {
  local exit_code="${1:-0}"
  local next="${2:-}"
  local volume="${3:-}"
  local ok_json="false"
  local reason_e msg_e next_e volume_e
  [ "$RESULT_STATUS" = "ok" ] && ok_json="true"
  reason_e=$(json_escape "${RESULT_REASON:-}")
  msg_e=$(json_escape "${RESULT_MSG:-}")
  next_e=$(json_escape "$next")
  volume_e=$(json_escape "$volume")
  printf '{"ok":%s,"exit":%s,"reason":"%s","message":"%s","next":"%s","volume":"%s"}\n' \
    "$ok_json" "$exit_code" "$reason_e" "$msg_e" "$next_e" "$volume_e"
}
