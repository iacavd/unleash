# curl %{http_code} 000 (or 000 concatenated with a fallback) is not reachable.
http_code_reachable() {
  local code="${1:-}"
  code="${code#"${code%%[![:space:]]*}"}"
  code="${code%"${code##*[![:space:]]}"}"
  case "$code" in
    ''|000|000000|000*) return 1 ;;
  esac
  return 0
}

run_preformat_check() {
  header "Pre-Format MDM Assessment"

  local clean=true
  local fw_rules=""

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
      echo -e "  ${RED}On-disk DEP record present — assigned to: $org${NC}"
      echo -e "  ${YEL}A wipe can re-lock this Mac. Hosts block does not survive a format.${NC}"
      clean=false
    elif [ "$is_fetch_err" = "true" ]; then
      echo -e "  ${YEL}On-disk DEP record present (CloudConfigFetchError — domain block is active now).${NC}"
      echo -e "  ${YEL}A wipe still re-enrolls: format removes /etc/hosts. Not safe to format.${NC}"
      clean=false
    else
      echo -e "  ${RED}On-disk DEP record present${NC}"
      echo -e "  ${YEL}A wipe can re-lock this Mac.${NC}"
      clean=false
    fi
  else
    echo -e "  ${GRN}DEP record clean${NC}"
  fi

  step "Checking MDM enrollment URL for this device..."
  if command -v curl &>/dev/null; then
    local enroll_check
    enroll_check=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      "https://deviceenrollment.apple.com/" 2>/dev/null) || enroll_check="000"
    [ -n "$enroll_check" ] || enroll_check="000"
    if http_code_reachable "$enroll_check"; then
      echo -e "  ${YEL}deviceenrollment.apple.com reachable (HTTP $enroll_check). Hosts block may not apply to this check.${NC}"
    else
      echo -e "  ${GRN}deviceenrollment.apple.com not reachable (code ${enroll_check})${NC}"
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
  local persist_on=0 fw_on=0
  if [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ]; then
    persist_on=1
  fi
  if printf '%s\n' "$fw_rules" | grep -q "block"; then
    fw_on=1
  fi
  if [ "$clean" = true ]; then
    echo -e "${GRN}Verdict: no live MDM enrollment.${NC}"
    echo "A wipe is unlikely to re-lock unless Apple DEP still has this serial."
    if [ "$persist_on" != 1 ]; then
      echo "Next: sudo ./unleash persist"
    fi
    if [ "$fw_on" != 1 ]; then
      echo "Next: sudo ./unleash firewall"
    fi
  else
    echo -e "${RED}Verdict: not safe to format.${NC}"
    echo "On-disk DEP or enrollment is still present. A wipe can re-lock this Mac."
    echo "Next: boot Recovery and run ./unleash apply --unattended"
  fi
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
    echo -e "  ${YEL}Fix: sudo ./unleash firewall${NC}"
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
