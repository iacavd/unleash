#!/usr/bin/env bash
# Unleash — Security & Defense Module
# Provides security posture analysis and profile quarantine.
# APNs block/unblock is tombstoned: the old 17/8:443 rule must not be installable.

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

# Tombstone: refuse the old 17/8:443 drop. Narrow APNs is a later spec.
_apns_removed() {
  error_exit "ERROR: apns-block was removed. The old rule dropped TCP 443 to all of 17.0.0.0/8. Next: use firewall (selective) or firewall-broad."
}

block_apns() { _apns_removed; }
unblock_apns() { _apns_removed; }

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
