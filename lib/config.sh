CONFIG_FILE="$HOME/.unleash.conf"
UNLEASH_USB_INTENT="${UNLEASH_USB_INTENT:-0}"

_load_config_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  while IFS='=' read -r key value; do
    key="${key// /}"
    value="${value// /}"
    [ -z "$key" ] && continue
    [[ "$key" =~ ^# ]] && continue
    case "$key" in
      WEBHOOK) DISCORD_WEBHOOK="$value" ;;
      LOG_LEVEL) [ "$value" = "verbose" ] && VERBOSE=true ;;
      LOG_FILE) LOG_FILE="$value" ;;
      AUTO_USERNAME) AUTO_USERNAME="$value" ;;
      AUTO_PASSWORD) AUTO_PASSWORD="$value" ;;
      BACKUP_RETENTION) BACKUP_RETENTION="$value" ;;
      I_OWN_THIS_DEVICE)
        case "$value" in
          1|true|yes|YES) UNLEASH_USB_INTENT=1 ;;
        esac
        ;;
      FIREWALL_MODE)
        case "$value" in
          selective|broad|off) UNLEASH_FIREWALL_MODE="$value" ;;
        esac
        ;;
    esac
  done < "$file"
}

load_config() {
  # USB unleash.conf next to the binary is the sidecar store (autorun).
  if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/unleash.conf" ]; then
    _load_config_file "$SCRIPT_DIR/unleash.conf"
  fi
  [ -f "$CONFIG_FILE" ] || return 0
  _load_config_file "$CONFIG_FILE"
}

# Volume UUID from diskutil; empty on fixtures diskutil cannot map.
volume_uuid_of() {
  local target="${1:-}"
  local uuid=""
  [ -n "$target" ] || return 0
  uuid=$("${DISKUTIL:-/usr/sbin/diskutil}" info "$target" 2>/dev/null \
    | awk -F': *' '/^[[:space:]]*Volume UUID:/{print $2; exit}')
  uuid="${uuid#"${uuid%%[![:space:]]*}"}"
  uuid="${uuid%"${uuid##*[![:space:]]}"}"
  printf '%s' "$uuid"
}

intent_path() {
  local root="${1:-${DATA_ROOT-}}"
  printf '%s\n' "${root}/Library/Unleash/state/intent"
}

# USB sidecar only: empty file next to unleash, or USB unleash.conf I_OWN_THIS_DEVICE=1.
# Home ~/.unleash.conf must not satisfy unattended intent.
usb_sidecar_present() {
  local root="${SCRIPT_DIR:-}"
  local line key value
  [ -n "$root" ] || return 1
  [ -f "$root/I_OWN_THIS_DEVICE" ] && return 0
  [ -f "$root/unleash.conf" ] || return 1
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="${key// /}"
    value="${value// /}"
    [ "$key" = "I_OWN_THIS_DEVICE" ] || continue
    case "$value" in
      1|true|yes|YES) return 0 ;;
    esac
  done < "$root/unleash.conf"
  return 1
}

write_intent() {
  local data_root="${1:-${DATA_ROOT-}}"
  local dir dest tmp uuid ts
  dir="${data_root}/Library/Unleash/state"
  mkdir -p "$dir" || return 1
  uuid=$(volume_uuid_of "$data_root")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  dest="$dir/intent"
  tmp="${dest}.tmp.$$"
  {
    printf 'owned=1\n'
    printf 'ts=%s\n' "$ts"
    printf 'volume_uuid=%s\n' "$uuid"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv "$tmp" "$dest"
}

# owned=1. If diskutil reports a UUID, stored volume_uuid must match (cloned tree → miss).
# Empty/empty only for fixtures diskutil cannot map.
intent_valid() {
  local path="$1"
  local data_root="${2:-${DATA_ROOT-}}"
  local line owned uuid current
  [ -f "$path" ] || return 1
  owned=0
  uuid=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      owned=1) owned=1 ;;
      volume_uuid=*) uuid="${line#volume_uuid=}" ;;
    esac
  done < "$path"
  [ "$owned" = 1 ] || return 1
  current=$(volume_uuid_of "$data_root")
  if [ -n "$current" ] && [ "$uuid" != "$current" ]; then
    return 1
  fi
  return 0
}

# Unattended/heal require target intent. USB sidecar is consumed onto the Data volume once.
# Heal (UNLEASH_RESUME=1) does not consume a USB sidecar.
check_or_consume_intent() {
  local data_root="${1:-${DATA_ROOT-}}"
  local path
  path=$(intent_path "$data_root")

  if [ "${UNLEASH_INTENT_FLAG:-0}" = 1 ]; then
    if [ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]; then
      return 0
    fi
    write_intent "$data_root" || {
      result_fail E_INTENT_MISSING pipeline intent "cannot write state/intent"
      return 1
    }
    return 0
  fi

  if [ "${UNLEASH_UNATTENDED:-0}" != 1 ] && [ "${UNLEASH_RESUME:-0}" != 1 ]; then
    return 0
  fi

  if intent_valid "$path" "$data_root"; then
    return 0
  fi

  if [ "${UNLEASH_RESUME:-0}" = 1 ]; then
    result_fail E_INTENT_MISSING pipeline intent "heal requires $path with matching volume_uuid"
    return 1
  fi

  if usb_sidecar_present; then
    if [ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]; then
      info pipeline intent "dry-run: would consume USB sidecar onto state/intent"
      return 0
    fi
    write_intent "$data_root" || {
      result_fail E_INTENT_MISSING pipeline intent "cannot write state/intent from USB sidecar"
      return 1
    }
    return 0
  fi

  result_fail E_INTENT_MISSING pipeline intent "unattended mutate requires I_OWN_THIS_DEVICE sidecar or --i-own-this-device"
  return 1
}

save_config() {
  local key="$1"
  local value="$2"
  local tmp

  [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i '' "s/^${key}=.*/${key}=${value}/" "$CONFIG_FILE"
  else
    echo "${key}=${value}" >> "$CONFIG_FILE"
  fi
  success "Saved $key to $CONFIG_FILE"
}

cmd_config() {
  header "Configuration"

  case "${2:-show}" in
    show)
      if [ ! -f "$CONFIG_FILE" ]; then
        info "No config file at $CONFIG_FILE"
        return 0
      fi
      step "Current settings ($CONFIG_FILE)"
      cat "$CONFIG_FILE" | sed 's/^/  /'
      ;;
    set)
      local key="${3:-}"
      local value="${4:-}"
      [ -z "$key" ] || [ -z "$value" ] && {
        info "Usage: ./unleash config set KEY VALUE"
        info "Keys: WEBHOOK, LOG_LEVEL (verbose), LOG_FILE,"
        info "      AUTO_USERNAME, AUTO_PASSWORD, BACKUP_RETENTION"
        return 1
      }
      save_config "$key" "$value"
      ;;
    unset)
      local key="${3:-}"
      [ -z "$key" ] && { info "Usage: ./unleash config unset KEY"; return 1; }
      if [ -f "$CONFIG_FILE" ]; then
        sed -i '' "/^${key}=/d" "$CONFIG_FILE"
        success "Removed $key from config"
      fi
      ;;
    *)
      info "Usage: ./unleash config {show|set KEY VALUE|unset KEY}"
      ;;
  esac
}
