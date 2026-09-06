#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  VERSION="2.0.0"
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  DRY_RUN=false
}

teardown() {
  chmod -R u+w "$TEST_DIR" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

@test "heal_suppress detects clean state" {
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  run heal_suppress "$TEST_DIR" 2>/dev/null
  [[ "$output" == *"intact"* ]] || [[ "$output" == *"no action"* ]]
}

@test "heal_suppress detects dirty state" {
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  touch "$TEST_DIR/private/etc/hosts"
  run heal_suppress "$TEST_DIR" 2>/dev/null || true
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

@test "persist plist ProgramArguments is live /Library/Unleash/unleash not USB" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib" "$USB/data" "$USB/state"
  printf '%s\n' '#!/bin/bash' 'echo usb' > "$USB/unleash"
  printf '%s\n' '# lib' > "$USB/lib/heal.sh"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  install_persist_launchdaemon "$TEST_DIR"
  plist="$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist"
  [ -f "$plist" ]
  grep -F '<string>/Library/Unleash/unleash</string>' "$plist"
  grep -F '<string>heal</string>' "$plist"
  grep -F '<string>--unattended</string>' "$plist"
  grep -F '<string>--log-file</string>' "$plist"
  grep -F '<string>/Library/Unleash/logs/heal.log</string>' "$plist"
  grep -F '<integer>300</integer>' "$plist"
  if grep -q '/bin/bash' "$plist"; then
    echo "plist must not use /bin/bash -c" >&2
    return 1
  fi
  if grep -F "$USB" "$plist"; then
    echo "plist must not embed USB path" >&2
    return 1
  fi
  if grep -q 'i-own-this-device' "$plist"; then
    echo "heal daemon must not take --i-own-this-device" >&2
    return 1
  fi
  [ -f "$TEST_DIR/Library/Unleash/unleash" ]
  rm -rf "$USB"
}

@test "persist copy does not copy USB state/intent into dest state" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib" "$USB/data" "$USB/state"
  printf '%s\n' '#!/bin/bash' > "$USB/unleash"
  printf '%s\n' '# lib' > "$USB/lib/heal.sh"
  printf '%s\n' 'secret-intent' > "$USB/state/intent"
  printf '%s\n' 'usb-journal' > "$USB/state/journal"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  install_persist_launchdaemon "$TEST_DIR"
  [ -f "$TEST_DIR/Library/Unleash/unleash" ]
  [ -f "$TEST_DIR/Library/Unleash/lib/heal.sh" ]
  [ ! -f "$TEST_DIR/Library/Unleash/state/intent" ]
  [ ! -f "$TEST_DIR/Library/Unleash/state/journal" ]
  rm -rf "$USB"
}

@test "persist sentinel has sha256 from shasum" {
  install_persist_launchdaemon "$TEST_DIR"
  sentinel="$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed"
  grep -q '^installed=' "$sentinel"
  grep -q '^sha256=' "$sentinel"
  sha=$(awk -F= '/^sha256=/{print $2}' "$sentinel")
  [ -n "$sha" ]
  [ ${#sha} -eq 64 ]
}

@test "persist install removes com.unleash.monitor plist" {
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  echo "old-monitor" > "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist"
  install_persist_launchdaemon "$TEST_DIR"
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist" ]
}

@test "persist missing source binary is E_PERSIST_PATH and not success" {
  SCRIPT_DIR="$TEST_DIR/missing-src"
  mkdir -p "$SCRIPT_DIR"
  DATA_ROOT="$TEST_DIR"
  st=0
  persist_copy "$TEST_DIR" || st=$?
  [ "$st" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_PERSIST_PATH" ]
}

@test "probe_hosts requires 0.0.0.0 or :: for three MDM domains" {
  DATA_ROOT="$TEST_DIR"
  : > "$TEST_DIR/private/etc/hosts"
  probe_hosts
  [ "$RESULT_STATUS" = "fail" ]
  printf '0.0.0.0 iprofiles.apple.com\n0.0.0.0 deviceenrollment.apple.com\n0.0.0.0 mdmenrollment.apple.com\n' > "$TEST_DIR/private/etc/hosts"
  probe_hosts
  [ "$RESULT_STATUS" = "ok" ]
}

@test "probe_dep requires cloudConfigRecordNotFound" {
  DATA_ROOT="$TEST_DIR"
  probe_dep
  [ "$RESULT_STATUS" = "fail" ]
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound"
  probe_dep
  [ "$RESULT_STATUS" = "ok" ]
}

@test "probe_dns skips off live OS with S_NO_DSCACHEUTIL" {
  DATA_ROOT="$TEST_DIR"
  probe_dns
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_NO_DSCACHEUTIL" ]
}

@test "persist not-writable dest is status 1 E_PERSIST_PATH" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib"
  printf '%s\n' '#!/bin/bash' > "$USB/unleash"
  printf '%s\n' '# lib' > "$USB/lib/heal.sh"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/Library/Unleash" "$TEST_DIR/Library/LaunchDaemons"
  chmod a-w "$TEST_DIR/Library/Unleash"
  st=0
  persist_copy "$TEST_DIR" || st=$?
  chmod u+w "$TEST_DIR/Library/Unleash" 2>/dev/null || true
  rm -rf "$USB"
  [ "$st" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_PERSIST_PATH" ]
}
