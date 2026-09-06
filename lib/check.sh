run_preformat_check() {
  header "Pre-Format MDM Assessment"

  local clean=true

  step "Checking DEP activation record..."
  local dep_file="/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  if [ -f "$dep_file" ]; then
    local org=""
    org=$(plutil -convert xml1 -o - "$dep_file" 2>/dev/null \
      | grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
    local is_fetch_err="false"
    if plutil -p "$dep_file" 2>/dev/null | grep -q "CloudConfigFetchError"; then
      is_fetch_err="true"
    fi

    if [ -n "$org" ]; then
      echo -e "  ${RED}ACTIVE DEP RECORD FOUND${NC}"
      echo -e "  ${YEL}Device assigned to: $org${NC}"
      clean=false
    elif [ "$is_fetch_err" = "true" ]; then
      echo -e "  ${GRN}DEP cloud check blocked (CloudConfigFetchError recorded — domain block active)${NC}"
    else
      echo -e "  ${RED}ACTIVE DEP RECORD FOUND${NC}"
      clean=false
    fi
  else
    echo -e "  ${GRN}DEP record clean${NC}"
  fi

  step "Checking MDM enrollment URL for this device..."
  if command -v curl &>/dev/null; then
    local enroll_check
    enroll_check=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      "https://deviceenrollment.apple.com/" 2>/dev/null || echo "000")
    if [ "$enroll_check" = "000" ] || [ "$enroll_check" = "200" ]; then
      echo -e "  ${YEL}deviceenrollment.apple.com reachable${NC}"
    else
      echo -e "  ${GRN}deviceenrollment.apple.com blocked (code $enroll_check)${NC}"
    fi
  else
    echo -e "  ${YEL}curl not available, skipping URL check${NC}"
  fi

  step "Checking MDM enrollment state..."
  if command -v profiles &>/dev/null; then
    local enroll_state
    enroll_state=$(sudo profiles status -type enrollment 2>/dev/null || true)
    if echo "$enroll_state" | grep -qiE "(Enrolled via DEP|MDM enrollment):[[:space:]]*Yes"; then
      echo -e "  ${RED}Device is enrolled in MDM${NC}"
      clean=false
    else
      echo -e "  ${GRN}Not enrolled in MDM${NC}"
    fi
  fi

  step "Checking installed profiles..."
  if command -v profiles &>/dev/null; then
    local profile_count
    profile_count=$(sudo profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
    profile_count="${profile_count:-0}"
    profile_count=$(echo "$profile_count" | head -n 1 | tr -dc '0-9')
    profile_count="${profile_count:-0}"
    if [ "$profile_count" -gt 0 ]; then
      echo -e "  ${YEL}$profile_count profile(s) installed${NC}"
      clean=false
    else
      echo -e "  ${GRN}No profiles installed${NC}"
    fi
  fi

  step "Checking pf firewall status..."
  if command -v pfctl &>/dev/null; then
    local fw_rules=""
    fw_rules=$(pfctl -a "com.unleash/mdm" -s rules 2>/dev/null || true)
    fw_rules="${fw_rules}$(pfctl -a "com.unleash.selective" -s rules 2>/dev/null || true)"
    if echo "$fw_rules" | grep -q "block"; then
      echo -e "  ${GRN}Unleash pf firewall active${NC}"
    else
      echo -e "  ${YEL}No Unleash pf firewall rules active${NC}"
    fi
  else
    echo -e "  ${YEL}pfctl not available${NC}"
  fi

  step "Checking persistence LaunchDaemon..."
  if [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ]; then
    echo -e "  ${GRN}Unleash LaunchDaemon installed (auto-heal on boot)${NC}"
  else
    echo -e "  ${YEL}No Unleash LaunchDaemon${NC}"
  fi

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  if [ "$clean" = true ]; then
    echo -e "${CYAN}║${NC}  ${GRN}SAFE TO FORMAT${NC} — No MDM enrollment detected                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  This Mac should not lock after a wipe.                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  If you want defense-in-depth anyway, run:                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}    ${YEL}sudo ./unleash persist && sudo ./unleash firewall${NC}              ${CYAN}║${NC}"
  else
    echo -e "${CYAN}║${NC}  ${RED}MDM DETECTED${NC} — This Mac WILL lock after format                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Run from Recovery after wipe: ${YEL}./unleash bypass${NC}                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  To survive macOS updates (not full wipes):                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}    ${YEL}sudo ./unleash persist && sudo ./unleash firewall${NC}              ${CYAN}║${NC}"
  fi
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

check_upgrade_safety() {
  header "macOS Upgrade Safety Check"

  step "Checking if suppression will survive upgrade..."
  local issues=0

  if [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ]; then
    echo -e "  ${GRN}Persistence installed — heal runs after reboot${NC}"
  else
    echo -e "  ${RED}No persistence — upgrade may restore MDM${NC}"
    echo -e "  ${YEL}Fix: sudo ./unleash persist${NC}"
    issues=$((issues + 1))
  fi

  local fw_rules=""
  if command -v pfctl &>/dev/null; then
    fw_rules=$(pfctl -a "com.unleash/mdm" -s rules 2>/dev/null || true)
    fw_rules="${fw_rules}$(pfctl -a "com.unleash.selective" -s rules 2>/dev/null || true)"
  fi
  if echo "$fw_rules" | grep -q "block"; then
    echo -e "  ${GRN}pf firewall active — survives upgrade${NC}"
  else
    echo -e "  ${YEL}No pf firewall — upgrade may restore MDM connectivity${NC}"
    echo -e "  ${YEL}Fix: sudo ./unleash whitelist${NC}"
    issues=$((issues + 1))
  fi

  if grep -q "iprofiles.apple.com" /private/etc/hosts 2>/dev/null; then
    echo -e "  ${GRN}Hosts block active${NC}"
  else
    echo -e "  ${YEL}Hosts block not found${NC}"
    issues=$((issues + 1))
  fi

  echo ""
  if [ "$issues" -eq 0 ]; then
    echo -e "${GRN}Upgrade should be safe — MDM suppression will survive.${NC}"
  else
    echo -e "${YEL}$issues issue(s) found. Run the fixes above before upgrading.${NC}"
  fi
}
