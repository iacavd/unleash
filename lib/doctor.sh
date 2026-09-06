# shellcheck shell=bash
# doctor --gate is the apply/heal preflight. Informational doctor never fail-closes
# on Recovery-vs-live, SIP, or Little Snitch.

_doctor_libdir() {
  if [ -n "${LIB_DIR:-}" ]; then
    printf '%s' "$LIB_DIR"
    return 0
  fi
  if [ -n "${SCRIPT_DIR:-}" ]; then
    printf '%s' "$SCRIPT_DIR/lib"
    return 0
  fi
  printf ''
}

_doctor_core_libs() {
  printf '%s\n' colors result config detect validate dscl suppress backup pipeline status heal firewall doctor
}

_doctor_volume_is_disk_id() {
  local spec="${1:-}"
  spec="${spec#/dev/}"
  case "$spec" in
    disk[0-9]*s[0-9]*|disk[0-9]*) return 0 ;;
  esac
  return 1
}

# Same fixture exception as pipeline: tmp Data trees are not the live volume.
# diskNsN and unmounted /Volumes paths still need root; missing tmp paths do not
# (resolver emits E_VOLUME_NOT_FOUND).
_doctor_need_root() {
  if [ "${UNLEASH_DRY_RUN:-0}" = 1 ] || [ "${DRY_RUN:-false}" = true ]; then
    return 1
  fi
  if type is_root >/dev/null 2>&1 && is_root; then
    return 1
  fi
  if [ -n "${UNLEASH_VOLUME:-}" ]; then
    if _doctor_volume_is_disk_id "$UNLEASH_VOLUME"; then
      return 0
    fi
    case "${UNLEASH_VOLUME}" in
      /|/Volumes/*|/System/*) return 0 ;;
    esac
    return 1
  fi
  return 0
}

_doctor_disk_free_kb() {
  local target="${1:-/}"
  df -k "$target" 2>/dev/null | awk 'NR==2 {print $4; exit}'
}

_doctor_volume_locked() {
  local spec="${1:-}"
  local du="${DISKUTIL:-/usr/sbin/diskutil}"
  local info=""
  [ -n "$spec" ] || return 1
  [ -x "$du" ] || command -v diskutil >/dev/null 2>&1 || return 1
  info=$("$du" info "$spec" 2>/dev/null || true)
  [ -n "$info" ] || return 1
  printf '%s\n' "$info" | grep -qiE '^[[:space:]]*Locked:[[:space:]]*Yes' && return 0
  printf '%s\n' "$info" | grep -qiE '^[[:space:]]*FileVault:[[:space:]]*Yes[[:space:]]*\(Locked\)' && return 0
  return 1
}

_doctor_little_snitch() {
  [ -d "/Applications/Little Snitch.app" ] && return 0
  [ -f "/Library/Extensions/LittleSnitch.kext" ] && return 0
  return 1
}

# Fail closed. RESULT_* set. Return 2 on fail, 0 on ok (spec: doctor --gate is 0/2).
run_doctor_gate() {
  local libdir du pb missing=0 lib target avail

  if [ -z "${BASH_VERSION:-}" ]; then
    result_fail E_PREFLIGHT_TOOLS doctor gate "bash is required"
    return 2
  fi

  libdir=$(_doctor_libdir)
  if [ -n "$libdir" ]; then
    while IFS= read -r lib || [ -n "$lib" ]; do
      [ -n "$lib" ] || continue
      [ -f "$libdir/${lib}.sh" ] || missing=$((missing + 1))
    done <<EOF
$(_doctor_core_libs)
EOF
    if [ "$missing" -gt 0 ]; then
      result_fail E_PREFLIGHT_TOOLS doctor gate "$missing core lib(s) missing under $libdir"
      return 2
    fi
  fi

  du="${DISKUTIL:-/usr/sbin/diskutil}"
  if [ ! -x "$du" ] && ! command -v diskutil >/dev/null 2>&1; then
    result_fail E_PREFLIGHT_TOOLS doctor gate "diskutil not available"
    return 2
  fi
  pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
  if [ ! -x "$pb" ] && [ ! -x /usr/libexec/PlistBuddy ]; then
    result_fail E_PREFLIGHT_TOOLS doctor gate "PlistBuddy not available"
    return 2
  fi

  # diskNsN and unmounted /Volumes paths are the resolver's job, not [ -d ] here.
  if _doctor_need_root; then
    result_fail E_NOT_ROOT doctor gate "mutate requires root"
    return 2
  fi

  if [ "${UNLEASH_UNATTENDED:-0}" = 1 ]; then
    if _doctor_volume_locked "${UNLEASH_VOLUME:-}"; then
      if [ -z "${UNLEASH_FV_PASSWORD_FILE:-}" ] && [ -z "${UNLEASH_FV_KEY_FILE:-}" ]; then
        result_fail E_FV_LOCKED doctor gate "FileVault locked and no secret in unattended"
        return 2
      fi
    fi
  fi

  target="${UNLEASH_VOLUME:-/}"
  [ -d "$target" ] || target="/"
  avail=$(_doctor_disk_free_kb "$target")
  if [ -z "$avail" ]; then
    result_fail E_DISK_FULL doctor gate "cannot determine disk space on $target"
    return 2
  fi
  case "$avail" in
    *[!0-9]*)
      result_fail E_DISK_FULL doctor gate "cannot parse disk space"
      return 2
      ;;
  esac
  if [ "$avail" -lt 10240 ]; then
    result_fail E_DISK_FULL doctor gate "disk space below 10 MiB on $target"
    return 2
  fi

  if [ "${UNLEASH_UNATTENDED:-0}" = 1 ] || [ "${UNLEASH_RESUME:-0}" = 1 ]; then
    if [ "${UNLEASH_INTENT_FLAG:-0}" != 1 ]; then
      if ! usb_sidecar_present 2>/dev/null; then
        if [ -n "${UNLEASH_VOLUME:-}" ] && [ -d "${UNLEASH_VOLUME}" ] && type intent_valid >/dev/null 2>&1; then
          if ! intent_valid "$(intent_path "$UNLEASH_VOLUME")" "$UNLEASH_VOLUME"; then
            result_fail E_INTENT_MISSING doctor gate "unattended mutate requires intent or USB sidecar"
            return 2
          fi
        elif [ -z "${UNLEASH_VOLUME:-}" ]; then
          result_fail E_INTENT_MISSING doctor gate "unattended mutate requires intent or USB sidecar"
          return 2
        fi
      fi
    fi
  fi

  if type is_recovery >/dev/null 2>&1 && is_recovery; then
    info doctor gate "capability can_delete_cloudconfig=1 can_pfctl_load=0"
  else
    info doctor gate "capability can_delete_cloudconfig=0 can_pfctl_load=1"
  fi
  if _doctor_little_snitch; then
    info doctor gate "Little Snitch present (informational)"
  fi

  result_ok doctor gate "preflight ok"
  return 0
}

run_doctor() {
  if [ "${1:-}" = "--gate" ] || [ "${UNLEASH_GATE:-0}" = 1 ]; then
    run_doctor_gate
    return $?
  fi

  header "Unleash Doctor — Pre-Flight Check"

  local errors=0 warnings=0
  local libdir missing=0 total=0
  local avail tp_found=""

  begin "Script location"
  if [ -n "${SCRIPT_DIR:-}" ] && [ -d "$SCRIPT_DIR" ]; then
    end_ok; echo "     $SCRIPT_DIR"
  else
    end_fail; errors=$((errors + 1))
  fi

  begin "Library files"
  libdir=$(_doctor_libdir)
  if [ -z "$libdir" ]; then
    end_fail; echo "     LIB_DIR unset"; errors=$((errors + 1))
  else
    for _lib in colors result config detect validate dscl suppress backup status heal firewall harden whitelist check monitor history doctor selfupdate uninstall report ma_detect demo vpn init suggest remediate telemetry predict discord automate security webhook simulate tui fleet upgrade web; do
      total=$((total + 1))
      [ -f "$libdir/$_lib.sh" ] || missing=$((missing + 1))
    done
    if [ "$missing" -eq 0 ]; then
      end_ok; echo "     $total/$total modules loaded"
    else
      end_fail; echo "     $missing module(s) missing"; errors=$((errors + 1))
    fi
  fi

  begin "Root privileges"
  if type is_root >/dev/null 2>&1 && is_root; then
    end_ok
  else
    end_fail; echo "     Run with sudo for full checks"
    warnings=$((warnings + 1))
  fi

  begin "Recovery mode"
  if type is_recovery >/dev/null 2>&1 && is_recovery; then
    end_ok; echo "     capability can_delete_cloudconfig=1 can_pfctl_load=0"
  else
    # Not a fail: live OS is a capability bit, not an error.
    end_ok; echo "     capability can_delete_cloudconfig=0 can_pfctl_load=1"
  fi

  begin "Disk space (Data volume)"
  avail=$(_doctor_disk_free_kb "${UNLEASH_VOLUME:-/}")
  if [ -n "$avail" ] && [ "$avail" -ge 10240 ]; then
    end_ok; echo "     ${avail} KB free"
  elif [ -n "$avail" ]; then
    end_fail; echo "     Low disk space"; warnings=$((warnings + 1))
  else
    end_fail; echo "     Cannot determine"; errors=$((errors + 1))
  fi

  begin "Internet access"
  if command -v curl &>/dev/null && curl -s --max-time 3 https://github.com >/dev/null 2>&1; then
    end_ok; echo "     Online"
  else
    end_ok; echo "     Offline (expected in Recovery)"
  fi

  begin "pfctl available"
  if command -v pfctl &>/dev/null || [ -x "${PFCTL:-/sbin/pfctl}" ]; then
    end_ok
  else
    end_ok; echo "     Firewall commands unavailable"
  fi

  begin "profiles command"
  if command -v profiles &>/dev/null || [ -x "${PROFILES:-/usr/sbin/profiles}" ]; then
    end_ok
  else
    end_ok; echo "     Audit/harden commands limited"
  fi

  begin "launchctl available"
  if command -v launchctl &>/dev/null || [ -x "${LAUNCHCTL:-/bin/launchctl}" ]; then
    end_ok
  else
    end_ok; echo "     Persistence commands unavailable"
  fi

  begin "Third-party firewall"
  tp_found=""
  [ -d "/Applications/Little Snitch.app" ] && tp_found="Little Snitch"
  [ -d "/Applications/LuLu.app" ] && tp_found="${tp_found:+$tp_found, }LuLu"
  [ -f "/Library/Extensions/LittleSnitch.kext" ] && tp_found="${tp_found:+$tp_found, }Little Snitch (kext)"
  [ -d "/Applications/Radio Silence.app" ] && tp_found="${tp_found:+$tp_found, }Radio Silence"
  [ -d "/Applications/Vallum.app" ] && tp_found="${tp_found:+$tp_found, }Vallum"
  if [ -n "$tp_found" ]; then
    # Informational only — never fail the gate or increment errors for Little Snitch.
    end_ok; echo "     $tp_found (informational)"
  else
    end_ok; echo "     None detected"
  fi

  echo ""
  step "Persistence status"
  if [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ]; then
    echo "     heal  LaunchDaemon: installed"
  else
    echo "     heal  LaunchDaemon: not installed"
  fi
  if [ -f "/Library/LaunchDaemons/com.unleash.monitor.plist" ]; then
    echo "     monitor LaunchDaemon: installed"
  else
    echo "     monitor LaunchDaemon: not installed"
  fi
  if [ -f "/etc/pf.anchors/com.unleash/mdm" ]; then
    echo "     pf firewall anchor: installed"
  else
    echo "     pf firewall anchor: not installed"
  fi
  if [ -f "/etc/pf.anchors/com.unleash.selective" ]; then
    echo "     pf selective anchor: installed"
  else
    echo "     pf selective anchor: not installed"
  fi

  echo ""
  if type check_security_posture >/dev/null 2>&1; then
    check_security_posture
  fi

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
  if [ "$errors" -eq 0 ] && [ "$warnings" -eq 0 ]; then
    echo -e "${CYAN}║${NC}  ${GRN}All checks passed${NC}                       ${CYAN}║${NC}"
  elif [ "$errors" -eq 0 ]; then
    echo -e "${CYAN}║${NC}  ${YEL}Passed with $warnings warning(s)${NC}               ${CYAN}║${NC}"
  else
    echo -e "${CYAN}║${NC}  ${RED}$errors error(s), $warnings warning(s)${NC}              ${CYAN}║${NC}"
  fi
  echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
  return 0
}
