do_uninstall() {
  header "Unleash — Full Uninstall"

  if ! is_root; then
    error_exit "Uninstall needs sudo: sudo ./unleash uninstall"
  fi

  begin "Removing heal LaunchDaemon"
  local plist="/Library/LaunchDaemons/com.unleash.heal.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    rm -f "/Library/LaunchDaemons/${PERSIST_SENTINEL:-'.unleash-persist-installed'}"
    end_ok
  else
    end_fail; echo "     Not installed"
  fi

  begin "Removing monitor LaunchDaemon"
  plist="/Library/LaunchDaemons/com.unleash.monitor.plist"
  if [ -f "$plist" ]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    end_ok
  else
    end_fail; echo "     Not installed"
  fi

  begin "Cleaning pf anchors"
  local anchors=("/etc/pf.anchors/com.unleash/mdm" "/etc/pf.anchors/com.unleash.selective" "/etc/pf.anchors/com.unleash/vpn-kill" "/etc/pf.anchors/com.unleash.apns")
  for a in "${anchors[@]}"; do
    [ -f "$a" ] && rm -f "$a"
  done
  # Clean the com.unleash directory if empty
  [ -d "/etc/pf.anchors/com.unleash" ] && rmdir "/etc/pf.anchors/com.unleash" 2>/dev/null || true
  for anchor_name in "com.unleash/mdm" "com.unleash.selective" "com.unleash/vpn-kill" "com.unleash.apns"; do
    pfctl -a "$anchor_name" -F all 2>/dev/null || true
  done
  local pf_conf="/etc/pf.conf"
  if [ -f "$pf_conf" ]; then
    sed -i '' '/# Added by unleash/d' "$pf_conf" 2>/dev/null || true
    sed -i '' '/# UNLEASH_/d' "$pf_conf" 2>/dev/null || true
    sed -i '' '/com\.unleash/d' "$pf_conf" 2>/dev/null || true
  fi
  pfctl -f /etc/pf.conf 2>/dev/null || true
  end_ok

  begin "Removing post-update hooks"
  [ -f "/private/etc/rc.unleash-update.local" ] && rm -f "/private/etc/rc.unleash-update.local"
  end_ok

  begin "Cleaning hosts entries"
  local hosts="/private/etc/hosts"
  if [ -f "$hosts" ]; then
    sed -i '' '/# Added by unleash/d' "$hosts" 2>/dev/null || true
    local domains=("iprofiles.apple.com" "deviceenrollment.apple.com" "mdmenrollment.apple.com"
      "acmdm.apple.com" "axm-adm-mdm.apple.com" "albert.apple.com" "gdmf.apple.com"
      "ax.init-content.apple.com" "init-content.apple.com" "configuration.apple.com"
      "xp.apple.com" "gs.apple.com" "tb.apple.com" "vpp.itunes.apple.com")
    for d in "${domains[@]}"; do
      sed -i '' "/[[:space:]]$d/d" "$hosts" 2>/dev/null || true
      sed -i '' "/::.*$d/d" "$hosts" 2>/dev/null || true
    done
    end_ok
  else
    end_fail; echo "     Not found"
  fi

  begin "Restoring launchd overrides"
  local ldp="/private/var/db/com.apple.xpc.launchd/disabled.plist"
  if [ -f "$ldp" ]; then
    for label in com.apple.ManagedClient.enroll com.apple.ManagedClient.cloudConfiguration \
      com.apple.mdmclient.daemon.runatboot com.apple.activationd; do
      /usr/libexec/PlistBuddy -c "Delete :$label" "$ldp" 2>/dev/null || true
    done
    end_ok
  else
    end_fail; echo "     Not found"
  fi

  begin "Removing backup directory"
  local backup="${BACKUP_DIR:-${SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}}/.unleash-backup"
  if [ -d "$backup" ]; then
    rm -rf "$backup" 2>/dev/null || true
    end_ok
  elif [ -d ".unleash-backup" ]; then
    rm -rf ".unleash-backup" 2>/dev/null || true
    end_ok
  else
    end_fail; echo "     Not found"
  fi

  begin "Removing config file"
  if [ -f "$HOME/.unleash.conf" ]; then
    rm -f "$HOME/.unleash.conf"
    end_ok
  else
    end_fail; echo "     Not found"
  fi

  begin "Stopping monitor if running"
  local pidfile="/tmp/unleash-monitor.pid"
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile"
    end_ok
  else
    end_fail; echo "     Not running"
  fi

  begin "Stopping Discord bot if running"
  local discord_pid="/tmp/unleash-discord/bot.pid"
  if [ -f "$discord_pid" ]; then
    kill "$(cat "$discord_pid")" 2>/dev/null || true
    rm -rf "/tmp/unleash-discord"
    end_ok
  else
    end_fail; echo "     Not running"
  fi

  begin "Removing telemetry file"
  if [ -f "$HOME/.unleash-telemetry" ]; then
    rm -f "$HOME/.unleash-telemetry"
    end_ok
  else
    end_fail; echo "     Not found"
  fi

  echo ""
  success "Uninstall complete"
  info "Your system is back to its original state."
  info "The unleash script itself was not removed."
}
