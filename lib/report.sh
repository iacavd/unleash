generate_report() {
  local mode="${1:-}"
  local output_file=""

  # Parse flags
  case "$mode" in
    --json) generate_report_json; return ;;
    --brief) generate_report_brief; return ;;
    --output)
      output_file="${2:-unleash-report.md}"
      generate_report_full | tee "$output_file"
      success "Report saved to $output_file"
      return
      ;;
    *) generate_report_full ;;
  esac
}

generate_report_brief() {
  local risk="LOW"
  local issues=0

  if [ -f "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]; then
    local org=""
    org=$(plutil -convert xml1 -o - "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" 2>/dev/null \
      | grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
    if [ -n "$org" ] || ! plutil -p "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" 2>/dev/null | grep -q "CloudConfigFetchError"; then
      risk="CRITICAL"; issues=$((issues + 1))
    fi
  fi
  if command -v profiles &>/dev/null; then
    local pc
    pc=$(sudo profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
    pc="${pc:-0}"
    pc=$(echo "$pc" | head -n 1 | tr -dc '0-9')
    pc="${pc:-0}"
    [ "$pc" -gt 0 ] && { risk="MEDIUM"; issues=$((issues + 1)); }
  fi
  ps aux 2>/dev/null | grep -iE "(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)" | grep -qv grep && { risk="HIGH"; issues=$((issues + 1)); }

  local persist="no"
  [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ] && persist="yes"
  local fw="no"
  if command -v pfctl &>/dev/null; then
    local fw_rules=""
    fw_rules=$(pfctl -a "com.unleash/mdm" -s rules 2>/dev/null || true)
    fw_rules="${fw_rules}$(pfctl -a "com.unleash.selective" -s rules 2>/dev/null || true)"
    echo "$fw_rules" | grep -q "block" && fw="yes"
  fi

  echo "unleash v${VERSION} | risk=$risk issues=$issues persist=$persist firewall=$fw | $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

generate_report_full() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║                  UNLEASH SYSTEM REPORT                      ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "  ${CYAN}Generated:${NC} $ts"
  echo -e "  ${CYAN}Version:${NC}   $VERSION"
  if command -v sw_vers &>/dev/null; then
    echo -e "  ${CYAN}macOS:${NC}     $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
  fi
  if command -v uname &>/dev/null; then
    echo -e "  ${CYAN}Arch:${NC}      $(uname -m 2>/dev/null || echo 'unknown')"
  fi
  echo -e "  ${CYAN}Hostname:${NC}  $(hostname 2>/dev/null || echo 'unknown')"
  echo ""

  echo -e "${CYAN}─── MDM Enrollment ─────────────────────────────────────────${NC}"
  if command -v profiles &>/dev/null; then
    sudo profiles status -type enrollment 2>/dev/null | sed 's/^/  /' || echo "  (cannot determine)"
  fi

  local cfg="/private/var/db/ConfigurationProfiles/Settings"
  if [ -f "$cfg/.cloudConfigRecordFound" ]; then
    local org=""
    org=$(plutil -convert xml1 -o - "$cfg/.cloudConfigRecordFound" 2>/dev/null \
      | grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
    if [ -n "$org" ]; then
      echo -e "  ${RED}DEP record: FOUND (Organization: $org)${NC}"
    elif plutil -p "$cfg/.cloudConfigRecordFound" 2>/dev/null | grep -q "CloudConfigFetchError"; then
      echo -e "  ${GRN}DEP record: Blocked (CloudConfigFetchError logged — domain sinkhole active)${NC}"
    else
      echo -e "  ${YEL}DEP record: present${NC}"
    fi
  else
    echo -e "  ${GRN}DEP record: clean${NC}"
  fi
  echo ""

  echo -e "${CYAN}─── Installed Profiles ─────────────────────────────────────${NC}"
  if command -v profiles &>/dev/null; then
    local count
    count=$(sudo profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
    count="${count:-0}"
    count=$(echo "$count" | head -n 1 | tr -dc '0-9')
    count="${count:-0}"
    if [ "$count" -gt 0 ]; then
      echo -e "  ${YEL}$count profile(s) installed:${NC}"
      sudo profiles -C -output=xml 2>/dev/null | grep -A1 "ProfileDisplayName" | grep "<string>" \
        | sed 's/.*<string>\(.*\)<\/string>.*/    - \1/'
    else
      echo -e "  ${GRN}No profiles installed${NC}"
    fi
  fi
  echo ""

  echo -e "${CYAN}─── Firewall ───────────────────────────────────────────────${NC}"
  if command -v pfctl &>/dev/null; then
    pfctl -si 2>/dev/null | grep -E "Status|Enabled" | sed 's/^/  /' || echo "  pf not enabled"
    echo ""
    local rules
    rules=$(pfctl -a "com.unleash/mdm" -s rules 2>/dev/null || true)
    if echo "$rules" | grep -q "block"; then
      echo -e "  ${GRN}MDM block anchor: loaded${NC}"
      echo "$rules" | sed 's/^/    /'
    else
      echo -e "  ${YEL}MDM block anchor: not loaded${NC}"
    fi
    rules=$(pfctl -a "com.unleash.selective" -s rules 2>/dev/null || true)
    [ -n "$rules" ] \
      && echo -e "  ${GRN}Selective anchor: loaded${NC}" \
      || echo -e "  ${YEL}Selective anchor: not loaded${NC}"
  fi
  echo ""

  echo -e "${CYAN}─── VPN Kill-Switch ────────────────────────────────────────${NC}"
  if [ -f "/etc/pf.anchors/com.unleash/vpn-kill" ]; then
    echo -e "  ${GRN}VPN kill-switch: installed${NC}"
    if command -v pfctl &>/dev/null; then
      pfctl -a "com.unleash/vpn-kill" -s rules 2>/dev/null | grep -q "block" \
        && echo -e "  ${GRN}Anchor: loaded${NC}" \
        || echo -e "  ${YEL}Anchor: not loaded${NC}"
    fi
  else
    echo -e "  ${YEL}VPN kill-switch: not installed${NC}"
  fi
  echo ""

  echo -e "${CYAN}─── Persistence ────────────────────────────────────────────${NC}"
  [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ] \
    && echo -e "  ${GRN}heal LaunchDaemon: installed${NC}" \
    || echo -e "  ${YEL}heal LaunchDaemon: not installed${NC}"
  [ -f "/Library/LaunchDaemons/com.unleash.monitor.plist" ] \
    && echo -e "  ${GRN}monitor LaunchDaemon: installed${NC}" \
    || echo -e "  ${YEL}monitor LaunchDaemon: not installed${NC}"
  [ -f "/tmp/unleash-monitor.pid" ] && kill -0 "$(cat /tmp/unleash-monitor.pid)" 2>/dev/null \
    && echo -e "  ${GRN}monitor process: running${NC}" \
    || echo -e "  ${YEL}monitor process: not running${NC}"
  echo ""

  echo -e "${CYAN}─── Backup Status ──────────────────────────────────────────${NC}"
  if has_backup; then
    local backup_count=0
    if [ -d "$BACKUP_DIR" ]; then
      backup_count=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | wc -l | tr -d ' ')
    fi
    echo -e "  ${GRN}Backups available: $backup_count${NC}"
  else
    echo -e "  ${YEL}No backups${NC}"
  fi
  echo ""

  echo -e "${CYAN}─── Recent Events ──────────────────────────────────────────${NC}"
  for logfile in /var/log/unleash-monitor.log /var/log/unleash-heal.log; do
    if [ -f "$logfile" ] && [ -s "$logfile" ]; then
      echo "  From $(basename "$logfile"):"
      tail -3 "$logfile" | sed 's/^/    /'
    fi
  done
  echo ""

  echo -e "${CYAN}─── Hosts Block ────────────────────────────────────────────${NC}"
  if grep -q "iprofiles.apple.com" /private/etc/hosts 2>/dev/null; then
    local blocked
    blocked=$(grep -c "0.0.0.0" /private/etc/hosts 2>/dev/null || echo 0)
    echo -e "  ${GRN}$blocked domain(s) blocked in /etc/hosts${NC}"
  else
    echo -e "  ${YEL}No block entries found${NC}"
  fi
  echo ""

  echo -e "${CYAN}─── Running MDM Processes ──────────────────────────────────${NC}"
  local procs
  procs=$(ps aux 2>/dev/null | grep -iE "(ManagedClient\.app|/mdmclient|com\.apple\.ManagedClient)" | grep -v grep || true)
  if [ -n "$procs" ]; then
    echo "$procs" | awk '{print "  " $11 " (PID " $2 ")"}'
  else
    echo -e "  ${GRN}None${NC}"
  fi
  echo ""

  echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
}

generate_report_json() {
  local report=""
  report="${report}{\n"

  report="${report}  \"version\": \"$VERSION\",\n"
  report="${report}  \"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\n"

  # System info
  local os_ver="unknown"
  command -v sw_vers &>/dev/null && os_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  local arch="unknown"
  command -v uname &>/dev/null && arch=$(uname -m 2>/dev/null || echo "unknown")
  local host_name="unknown"
  command -v hostname &>/dev/null && host_name=$(hostname 2>/dev/null || echo "unknown")
  report="${report}  \"system\": {\n"
  report="${report}    \"macos_version\": \"${os_ver}\",\n"
  report="${report}    \"architecture\": \"${arch}\",\n"
  report="${report}    \"hostname\": \"${host_name}\"\n"
  report="${report}  },\n"

  local enroll_state="unknown"
  if command -v profiles &>/dev/null; then
    enroll_state=$(sudo profiles status -type enrollment 2>/dev/null | head -1 | xargs || echo "unknown")
  fi
  enroll_state="${enroll_state//\"/\\\"}"
  report="${report}  \"enrollment_state\": \"${enroll_state}\",\n"

  local has_dep="false"
  if [ -f "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]; then
    local org=""
    org=$(plutil -convert xml1 -o - "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" 2>/dev/null \
      | grep -iA1 OrganizationName | tail -1 | sed -E 's/.*<string>(.*)<\/string>.*/\1/' || true)
    if [ -n "$org" ] || ! plutil -p "/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" 2>/dev/null | grep -q "CloudConfigFetchError"; then
      has_dep="true"
    fi
  fi
  report="${report}  \"dep_record_found\": $has_dep,\n"

  local profile_count=0
  if command -v profiles &>/dev/null; then
    profile_count=$(sudo profiles -C -output=xml 2>/dev/null | grep -c "ProfileDisplayName" || true)
    profile_count="${profile_count:-0}"
    profile_count=$(echo "$profile_count" | head -n 1 | tr -dc '0-9')
    profile_count="${profile_count:-0}"
  fi
  report="${report}  \"installed_profiles\": $profile_count,\n"

  local heal_installed="false"
  [ -f "/Library/LaunchDaemons/com.unleash.heal.plist" ] && heal_installed="true"
  local monitor_installed="false"
  [ -f "/Library/LaunchDaemons/com.unleash.monitor.plist" ] && monitor_installed="true"
  local monitor_running="false"
  [ -f "/tmp/unleash-monitor.pid" ] && kill -0 "$(cat /tmp/unleash-monitor.pid)" 2>/dev/null && monitor_running="true"
  report="${report}  \"persistence\": {\n"
  report="${report}    \"heal_launchdaemon\": $heal_installed,\n"
  report="${report}    \"monitor_launchdaemon\": $monitor_installed,\n"
  report="${report}    \"monitor_running\": $monitor_running\n"
  report="${report}  },\n"

  local fw_active="false"
  local fw_mode="none"
  if command -v pfctl &>/dev/null; then
    local rules
    rules=$(pfctl -a "com.unleash/mdm" -s rules 2>/dev/null || true)
    if echo "$rules" | grep -q "block"; then
      fw_active="true"
      if echo "$rules" | grep -q "17.0.0.0/8"; then
        fw_mode="broad"
      else
        fw_mode="selective"
      fi
    fi
  fi
  local selective_active="false"
  if command -v pfctl &>/dev/null && pfctl -a "com.unleash.selective" -s rules 2>/dev/null | grep -q "block"; then
    selective_active="true"
  fi
  local vpn_kill="false"
  [ -f "/etc/pf.anchors/com.unleash/vpn-kill" ] && vpn_kill="true"
  report="${report}  \"firewall\": {\n"
  report="${report}    \"mdm_block_active\": $fw_active,\n"
  report="${report}    \"mdm_block_mode\": \"$fw_mode\",\n"
  report="${report}    \"selective_block_active\": $selective_active,\n"
  report="${report}    \"vpn_kill_switch\": $vpn_kill\n"
  report="${report}  },\n"

  local hosts_blocked=0
  hosts_blocked=$(grep -c "0.0.0.0" /private/etc/hosts 2>/dev/null || echo 0)
  report="${report}  \"hosts_blocked\": $hosts_blocked,\n"

  local backup_count=0
  if [ -d "$BACKUP_DIR" ]; then
    backup_count=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | wc -l | tr -d ' ')
  fi
  report="${report}  \"backup_count\": $backup_count\n"

  report="${report}}"

  echo -e "$report"
}
