#!/usr/bin/env bash
# Unleash — Declarative Fleet Manifest Engine
# Parses and applies YAML/JSON/CONF fleet configuration manifests across multiple machines.

set -euo pipefail

cmd_fleet_apply() {
  local manifest_file="${UNLEASH_MANIFEST:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --manifest|-m)
        manifest_file="${2:-}"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done

  if [ -z "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
    warn "Manifest file missing or unreadable. Usage: unleash fleet-apply --manifest <fleet.json|fleet.conf>"
    return 1
  fi

  info "Applying fleet manifest: $manifest_file"

  local admin_user="" admin_pass="" firewall_mode="" webhook_url="" webhook_type=""

  # 1. Parse JSON if jq is available, or parse simple key-value file
  if command -v jq >/dev/null 2>&1 && [[ "$manifest_file" == *.json ]]; then
    admin_user=$(jq -r '.admin_user // empty' "$manifest_file" 2>/dev/null || true)
    admin_pass=$(jq -r '.admin_pass // empty' "$manifest_file" 2>/dev/null || true)
    firewall_mode=$(jq -r '.firewall_mode // "selective"' "$manifest_file" 2>/dev/null || true)
    webhook_url=$(jq -r '.webhook_url // empty' "$manifest_file" 2>/dev/null || true)
    webhook_type=$(jq -r '.webhook_type // "generic"' "$manifest_file" 2>/dev/null || true)
  else
    # Parse KEY=VALUE format
    admin_user=$(grep -E '^ADMIN_USER=' "$manifest_file" | cut -d'=' -f2- | tr -d '"' || true)
    admin_pass=$(grep -E '^ADMIN_PASS=' "$manifest_file" | cut -d'=' -f2- | tr -d '"' || true)
    firewall_mode=$(grep -E '^FIREWALL_MODE=' "$manifest_file" | cut -d'=' -f2- | tr -d '"' || true)
    webhook_url=$(grep -E '^WEBHOOK_URL=' "$manifest_file" | cut -d'=' -f2- | tr -d '"' || true)
    webhook_type=$(grep -E '^WEBHOOK_TYPE=' "$manifest_file" | cut -d'=' -f2- | tr -d '"' || true)
  fi

  # Default fallbacks
  firewall_mode="${firewall_mode:-selective}"
  webhook_type="${webhook_type:-generic}"

  info "Fleet Provisioning Configuration:"
  info "  - Admin User: ${admin_user:-'(none)'}"
  info "  - Firewall Mode: $firewall_mode"
  info "  - Alert Webhook: ${webhook_url:-'(disabled)'}"

  # 2. Execute Auto-All setup sequence
  local target_vol
  target_vol=$(resolve_data_volume 2>/dev/null || echo "/")

  info "Provisioning target volume: $target_vol"

  if [ -n "$admin_user" ] && [ -n "$admin_pass" ]; then
    info "Configuring automated credentials..."
    save_config "AUTO_USERNAME" "$admin_user"
    save_config "AUTO_PASSWORD" "$admin_pass"
  fi

  # Apply suppression
  suppress_enrollment "$target_vol"

  # Apply selected firewall configuration
  case "$firewall_mode" in
    broad)
      install_pf_mdm_block_broad "$target_vol"
      ;;
    apns)
      block_apns
      ;;
    selective|*)
      install_pf_mdm_block "$target_vol"
      ;;
  esac

  # Apply persistence LaunchDaemon
  install_persist_launchdaemon ""

  # Dispatch notification if webhook configured
  if [ -n "$webhook_url" ]; then
    send_webhook_alert "$webhook_type" "$webhook_url" "Fleet provisioning complete on $(hostname)" "Unleash Fleet Manifest Applied"
  fi

  success "Fleet manifest successfully applied to $target_vol"
}
