#!/usr/bin/env bash
# Unleash — Interactive Terminal User Interface (TUI) Dashboard

set -euo pipefail

launch_tui() {
  while true; do
    clear
    echo -e "${CYAN}"
    echo "============================================================"
    echo "            🚀 UNLEASH — MACOS UTILITY DASHBOARD           "
    echo "============================================================"
    echo -e "${NC}"
    echo "  1) Full System Security Audit (csrutil, FileVault, PF)"
    echo "  2) Dry-Run Simulation Mode (Non-Destructive Preview)"
    echo "  3) Selective Firewall Setup (Safe MDM IP Block)"
    echo "  4) Broad Firewall Setup (17.0.0.0/8 Block)"
    echo "  5) APNs Push Notification Firewall Block"
    echo "  6) Quarantine MDM .mobileconfig Profiles"
    echo "  7) Run Self-Healing & Suppress Check"
    echo "  8) Dispatch Test Webhook Alert"
    echo "  9) Backup & Snapshot System State"
    echo " 10) Exit TUI Dashboard"
    echo ""
    read -rp "Select an option [1-10]: " choice

    case "$choice" in
      1)
        clear
        check_security_posture
        read -rp "Press Enter to return to menu..."
        ;;
      2)
        clear
        run_simulation "/"
        read -rp "Press Enter to return to menu..."
        ;;
      3)
        clear
        install_pf_mdm_block
        read -rp "Press Enter to return to menu..."
        ;;
      4)
        clear
        install_pf_mdm_block_broad
        read -rp "Press Enter to return to menu..."
        ;;
      5)
        clear
        block_apns
        read -rp "Press Enter to return to menu..."
        ;;
      6)
        clear
        quarantine_profiles "/"
        read -rp "Press Enter to return to menu..."
        ;;
      7)
        clear
        heal_suppress "/"
        read -rp "Press Enter to return to menu..."
        ;;
      8)
        clear
        read -rp "Enter Webhook Type (discord/slack/telegram/ntfy/generic): " wtype
        read -rp "Enter Webhook URL (or token/chat_id for telegram): " wurl
        send_webhook_alert "$wtype" "$wurl" "Test notification from Unleash TUI" "TUI Test Alert"
        read -rp "Press Enter to return to menu..."
        ;;
      9)
        clear
        backup_state "/"
        read -rp "Press Enter to return to menu..."
        ;;
      10)
        info "Exiting Unleash TUI."
        break
        ;;
      *)
        echo -e "${RED}Invalid option.${NC}"
        sleep 1
        ;;
    esac
  done
}
