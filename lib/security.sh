#!/usr/bin/env bash
# Unleash — Security & Defense Module
# Provides security posture analysis, APNs push blocking, and profile quarantine.

set -euo pipefail

# Check live security posture (SIP, FileVault, Gatekeeper, PF Firewall)
check_security_posture() {
  info "Evaluating System Security Posture..."
  echo ""
  
  # 1. SIP Status
  local sip_status="Unknown"
  if command -v csrutil >/dev/null 2>&1; then
    if csrutil status 2>&1 | grep -q "enabled"; then
      sip_status="${RED}ENABLED${NC}"
    else
      sip_status="${GRN}DISABLED${NC}"
    fi
  fi
  printf "  %-25s : %b\n" "SIP (System Integrity)" "$sip_status"

  # 2. FileVault Status
  local fv_status="Unknown"
  if command -v fdesetup >/dev/null 2>&1; then
    if fdesetup status 2>&1 | grep -q "On"; then
      fv_status="${GRN}ON (Encrypted)${NC}"
    else
      fv_status="${YEL}OFF (Unencrypted)${NC}"
    fi
  fi
  printf "  %-25s : %b\n" "FileVault Encryption" "$fv_status"

  # 3. Gatekeeper Status
  local gk_status="Unknown"
  if command -v spctl >/dev/null 2>&1; then
    if spctl --status 2>&1 | grep -q "enabled"; then
      gk_status="${GRN}ENABLED${NC}"
    else
      gk_status="${YEL}DISABLED${NC}"
    fi
  fi
  printf "  %-25s : %b\n" "Gatekeeper Assessment" "$gk_status"

  # 4. PF Firewall Status
  local pf_status="Unknown"
  if command -v pfctl >/dev/null 2>&1; then
    if pfctl -s info 2>&1 | grep -q "Status: Enabled"; then
      pf_status="${GRN}ACTIVE${NC}"
    else
      pf_status="${RED}INACTIVE${NC}"
    fi
  fi
  printf "  %-25s : %b\n" "Packet Filter (PF)" "$pf_status"

  # 5. APNs Push Firewall Status
  local apns_status="Inactive"
  if [ -f "/etc/pf.anchors/com.unleash.apns" ]; then
    apns_status="${GRN}BLOCKED${NC}"
  else
    apns_status="${YEL}NOT BLOCKED${NC}"
  fi
  printf "  %-25s : %b\n" "APNs Push Firewall" "$apns_status"

  echo ""
}

# Block Apple Push Notification service (APNs) endpoints via PF Firewall
block_apns() {
  info "Installing APNs Push Notification Firewall Anchor..."

  if [ "$(id -u)" -ne 0 ]; then
    warn "Root privileges required to modify firewall anchors."
    return 1
  fi

  mkdir -p /etc/pf.anchors
  local apns_anchor="/etc/pf.anchors/com.unleash.apns"

  cat << 'EOF' > "$apns_anchor"
# Unleash APNs Block Anchor — Prevents remote MDM lock/wipe signals
block drop out quick proto tcp to 17.0.0.0/8 port { 5223, 2195, 2196, 443 }
block drop out quick proto tcp to courier.push.apple.com
EOF

  success "Created APNs anchor file at $apns_anchor"

  # Include anchor in pf.conf if not present
  if ! grep -q "com.unleash.apns" /etc/pf.conf 2>/dev/null; then
    cat << 'EOF' >> /etc/pf.conf

# UNLEASH_APNS_START
anchor "com.unleash.apns"
load anchor "com.unleash.apns" from "/etc/pf.anchors/com.unleash.apns"
# UNLEASH_APNS_END
EOF
    success "Added APNs anchor declaration to /etc/pf.conf"
  fi

  pfctl -f /etc/pf.conf 2>/dev/null || true
  pfctl -e 2>/dev/null || true
  success "APNs Firewall Rule applied successfully."
}

# Unblock APNs
unblock_apns() {
  info "Removing APNs Push Notification Firewall Rules..."

  if [ "$(id -u)" -ne 0 ]; then
    warn "Root privileges required to modify firewall anchors."
    return 1
  fi

  rm -f /etc/pf.anchors/com.unleash.apns

  if [ -f /etc/pf.conf ]; then
    sed -i '' '/# UNLEASH_APNS_START/,/# UNLEASH_APNS_END/d' /etc/pf.conf
    sed -i '' '/com\.unleash\.apns/d' /etc/pf.conf
  fi

  pfctl -f /etc/pf.conf 2>/dev/null || true
  success "APNs firewall rule removed successfully."
}

# Quarantine mobileconfig & configuration profile artifacts
quarantine_profiles() {
  local target_vol="${1:-/}"
  info "Scanning and quarantining MDM profiles on target volume: $target_vol"

  local q_dir="$target_vol/var/db/.unleash-quarantine-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$q_dir"

  local count=0
  local search_paths=(
    "$target_vol/var/db/ConfigurationProfiles"
    "$target_vol/Library/Preferences/SystemConfiguration"
  )

  for p in "${search_paths[@]}"; do
    if [ -d "$p" ]; then
      info "Scanning $p..."
      while IFS= read -r -d '' file; do
        if [[ "$file" == *.mobileconfig || "$file" == *com.apple.mdm* ]]; then
          warn "Quarantining profile artifact: $file"
          cp "$file" "$q_dir/" 2>/dev/null || true
          rm -f "$file" 2>/dev/null || true
          ((count++))
        fi
      done < <(find "$p" -maxdepth 3 -type f \( -name "*.mobileconfig" -o -name "*mdm*" \) -print0 2>/dev/null || true)
    fi
  done

  if [ "$count" -gt 0 ]; then
    success "Quarantined $count MDM profile artifact(s) to $q_dir"
  else
    info "No raw mobileconfig profile artifacts found needing quarantine."
  fi
}
