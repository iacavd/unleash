#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  VERSION="2.0.0"
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  DRY_RUN=false
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "heal_suppress detects clean state" {
  # Create a fully suppressed state
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  run heal_suppress "$TEST_DIR" 2>/dev/null
  [[ "$output" == *"intact"* ]] || [[ "$output" == *"no action"* ]]
}

@test "heal_suppress detects dirty state" {
  # Create hosts but leave DEP record
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  touch "$TEST_DIR/private/etc/hosts"
  run heal_suppress "$TEST_DIR" 2>/dev/null || true
  # Should have triggered re-suppression
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]
}

@test "heal_suppress fixes missing hosts block" {
  echo "" > "$TEST_DIR/private/etc/hosts"
  run heal_suppress "$TEST_DIR" 2>/dev/null || true
  run grep -c "iprofiles.apple.com" "$TEST_DIR/private/etc/hosts"
  [ "$output" -gt 0 ]
}

@test "install_persist_launchdaemon creates plist" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
}

@test "install_persist_launchdaemon creates sentinel file" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed" ]
}

@test "is_persist_installed returns true after install" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  run is_persist_installed "$TEST_DIR"
  [ "$status" -eq 0 ]
}

@test "remove_persist_launchdaemon removes plist and sentinel" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  remove_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed" ]
}

@test "is_persist_installed returns false after removal" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  remove_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  run is_persist_installed "$TEST_DIR"
  [ "$status" -ne 0 ]
}
