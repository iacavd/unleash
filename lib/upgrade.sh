#!/usr/bin/env bash
# Unleash — Safe macOS Software Update Wrapper
# Creates state snapshot, executes softwareupdate, and automatically re-applies suppressions post-upgrade.

set -euo pipefail

cmd_upgrade_os() {
  local target_vol="${1:-/}"

  info "=========================================================="
  info " UNLEASH ULTRA-RESILIENT MACOS SOFTWARE UPDATE WRAPPER"
  info "=========================================================="

  # 1. Pre-hook: Create full backup snapshot
  info "[Pre-Upgrade Hook] Creating pre-upgrade backup snapshot..."
  backup_state "$target_vol"

  # 2. Pre-hook: Install persistent post-reboot recovery hook
  info "[Pre-Upgrade Hook] Installing post-reboot auto-heal recovery script..."
  local post_update_script="$target_vol/private/etc/rc.unleash-update.local"
  if [ "${DRY_RUN:-false}" = false ]; then
    cat << 'EOF' > "$post_update_script"
#!/bin/sh
# Unleash Auto-Heal Hook Executed Post-OS Update
/usr/bin/touch /private/var/db/.AppleSetupDone 2>/dev/null || true
if [ -f /private/etc/hosts ]; then
  grep -q "iprofiles.apple.com" /private/etc/hosts || echo "127.0.0.1 iprofiles.apple.com deviceenrollment.apple.com mdmenrollment.apple.com acmdm.apple.com # Added by unleash" >> /private/etc/hosts
fi
/sbin/pfctl -e -f /etc/pf.conf 2>/dev/null || true
EOF
    chmod +x "$post_update_script" 2>/dev/null || true
  fi

  # 3. Perform macOS Update
  info "[System Update] Initiating macOS softwareupdate check & install..."
  if command -v softwareupdate >/dev/null 2>&1; then
    if [ "${DRY_RUN:-false}" = true ]; then
      info "[DRY RUN] Would execute: softwareupdate -i -a"
    else
      softwareupdate -i -a 2>&1 || warn "Softwareupdate returned non-zero status (update may require reboot)."
    fi
  else
    warn "softwareupdate CLI tool not available."
  fi

  # 4. Post-hook: Immediate re-suppress and persistence verification
  info "[Post-Upgrade Hook] Re-applying Unleash suppressions & verifying persistence..."
  heal_suppress "$target_vol"
  install_persist_launchdaemon "$target_vol"

  # Re-apply firewall anchors and reload packet filter
  if [ -f "$target_vol/etc/pf.anchors/com.unleash.selective" ] || [ -f "$target_vol/etc/pf.anchors/com.unleash/mdm" ] || [ -f "$target_vol/etc/pf.anchors/com.unleash.apns" ]; then
    if [ "${DRY_RUN:-false}" = false ]; then
      pfctl -f /etc/pf.conf 2>/dev/null || true
      pfctl -e 2>/dev/null || true
    fi
    success "PF firewall rules re-enforced."
  fi

  success "Safe macOS software update sequence complete."
}
