#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/config.sh'
  load '../lib/detect.sh'
  load '../lib/validate.sh'
  load '../lib/dscl.sh'
  load '../lib/suppress.sh'
  load '../lib/backup.sh'
  load '../lib/heal.sh'
  load '../lib/whitelist.sh'
  load '../lib/firewall.sh'
  load '../lib/monitor.sh'
  load '../lib/automate.sh'

  VERSION="2.0.0"
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/private/var/db/dslocal/nodes/Default"
  mkdir -p "$TEST_DIR/Users/testuser/Library/Preferences"
  mkdir -p "$TEST_DIR/Users/testuser/Library/Application Support"
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  DRY_RUN=false
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "cmd_auto_all runs suppress_enrollment on target" {
  # Simulate cmd_auto_all by calling suppress_enrollment directly
  # (full auto_all requires dscl which may not work in test)
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/hosts" ]
  run grep -c "iprofiles.apple.com" "$TEST_DIR/private/etc/hosts"
  [ "$output" -gt 0 ]
}

@test "cmd_auto_all installs selective firewall" {
  DATA_ROOT="$TEST_DIR"
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  install_pf_mdm_block_selective "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
}

@test "cmd_auto_all installs persistence" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
}

@test "cmd_auto_all installs monitor" {
  install_monitor_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist" ]
}
