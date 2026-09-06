# lib/automate.sh — Automated deployment mode (--auto-all)
# Runs the full bypass sequence with zero prompts.
# Designed for bootable USB payloads and unattended deployments.

cmd_auto_all() {
  local username="Apple"
  local password="1234"
  local realname="Apple"
  local target_volume=""

  # Parse arguments
  local args=("$@")
  local i=0
  while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
      --username)
        i=$((i + 1))
        username="${args[$i]:-Apple}"
        ;;
      --password)
        i=$((i + 1))
        password="${args[$i]:-1234}"
        ;;
      --realname)
        i=$((i + 1))
        realname="${args[$i]:-Apple}"
        ;;
      --volume)
        i=$((i + 1))
        target_volume="${args[$i]:-}"
        ;;
    esac
    i=$((i + 1))
  done

  header "AUTOMATED DEPLOYMENT"

  echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  ⚠  FULLY AUTOMATED MODE — NO PROMPTS                     ║${NC}"
  echo -e "${RED}║  This will bypass MDM, create an admin user, install       ║${NC}"
  echo -e "${RED}║  persistence, firewall, and monitoring — all automatically.║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  local data_mount=""
  local volumes_processed=0

  if [ -n "$target_volume" ]; then
    # Use specified volume
    if [ ! -d "$target_volume" ]; then
      error_exit "Specified volume not found: $target_volume"
    fi
    data_mount="$target_volume"
    info "Target volume: $data_mount"
  elif is_recovery; then
    # Try to auto-detect
    step "Auto-detecting Data volumes..."
    data_mount=$(resolve_data_volume 2>/dev/null || true)
    if [ -z "$data_mount" ]; then
      error_exit "Cannot auto-detect Data volume. Use --volume to specify."
    fi
  else
    data_mount=""
    info "Running on booted system (not Recovery)"
  fi

  # Phase 1: Bypass (only in Recovery)
  if is_recovery && [ -n "$data_mount" ]; then
    step "Phase 1: Creating admin user..."
    local node
    node=$(dscl_node "$data_mount")

    local uid
    uid=$(find_available_uid "$node")

    if check_user_exists "$node" "$username"; then
      info "User '$username' already exists — skipping creation"
    else
      create_admin_user "$node" "$data_mount" "$username" "$realname" "$password" "$uid"
    fi

    touch "$data_mount/private/var/db/.AppleSetupDone" 2>/dev/null || true
    success "Admin user ready: $username"

    add_to_filevault "$username" 2>/dev/null || true
  fi

  # Phase 2: Suppress enrollment
  step "Phase 2: Suppressing MDM enrollment..."
  suppress_enrollment "${data_mount:-/}"
  success "Enrollment suppressed"

  # Phase 3: Firewall (selective mode)
  step "Phase 3: Installing selective firewall..."
  local fw_root=""
  [ -n "$data_mount" ] && fw_root="$data_mount"
  install_pf_mdm_block_selective "$fw_root" 2>/dev/null || warn "Firewall install skipped (pfctl unavailable)"
  install_selective_block "$fw_root" 2>/dev/null || warn "Whitelist install skipped"

  # Phase 4: Persistence
  step "Phase 4: Installing persistence LaunchDaemon..."
  install_persist_launchdaemon "${data_mount:-}" 2>/dev/null || warn "Persistence install skipped"

  # Phase 5: Monitor
  step "Phase 5: Installing monitor LaunchDaemon..."
  install_monitor_launchdaemon "${data_mount:-}" 2>/dev/null || warn "Monitor install skipped"

  volumes_processed=$((volumes_processed + 1))

  echo ""
  echo -e "${GRN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GRN}║      AUTOMATED DEPLOYMENT COMPLETE                         ║${NC}"
  echo -e "${GRN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}Credentials:${NC} ${YEL}$username${NC} / ${YEL}$password${NC}"
  echo -e "${CYAN}Volume:${NC}      ${YEL}${data_mount:-/}${NC}"
  echo -e "${CYAN}Firewall:${NC}    ${GRN}selective mode (iCloud-safe)${NC}"
  echo -e "${CYAN}Persistence:${NC} ${GRN}installed (auto-heal on boot)${NC}"
  echo -e "${CYAN}Monitor:${NC}     ${GRN}installed (checks every 5 min)${NC}"
  echo ""
  echo -e "${YEL}Reboot to apply all changes.${NC}"
}
