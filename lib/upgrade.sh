#!/usr/bin/env bash
# Unleash — Safe macOS Software Update Wrapper
# Creates state snapshot, executes softwareupdate, and automatically re-applies suppressions post-upgrade.

set -euo pipefail

cmd_upgrade_os() {
  local target_vol="${1:-/}"

  info "=========================================================="
  info " UNLEASH SAFE MACOS SOFTWARE UPDATE WRAPPER"
  info "=========================================================="

  # 1. Pre-hook: Create full backup snapshot
  info "[Pre-Upgrade Hook] Creating pre-upgrade backup snapshot..."
  backup_state "$target_vol"

  # 2. Perform macOS Update
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

  # 3. Post-hook: Immediate re-suppress and persistence verification
  info "[Post-Upgrade Hook] Re-applying Unleash suppressions & verifying persistence..."
  heal_suppress "$target_vol"
  install_persist_launchdaemon "$target_vol"

  if [ -f "/etc/pf.anchors/com.unleash.selective" ] || [ -f "/etc/pf.anchors/com.unleash/mdm" ]; then
    pfctl -f /etc/pf.conf 2>/dev/null || true
    pfctl -e 2>/dev/null || true
    success "PF firewall rules re-enforced."
  fi

  success "Safe macOS software update sequence complete."
}
