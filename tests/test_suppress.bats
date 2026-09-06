#!/usr/bin/env bats
# Tests for suppress.sh - run with: bats tests/test_suppress.bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  load '../lib/suppress.sh'
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/Users/testuser/Library/Preferences"
  mkdir -p "$TEST_DIR/Users/testuser/Library/Application Support"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "suppress_enrollment creates hosts entries" {
  DRY_RUN=false
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  run grep -c "iprofiles.apple.com" "$TEST_DIR/private/etc/hosts"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

@test "suppress_enrollment clears DEP markers" {
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  DRY_RUN=false
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]
  [ -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound" ]
}

@test "suppress_enrollment disables daemons" {
  DRY_RUN=false
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  local ldp="$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist"
  [ -f "$ldp" ]
  run /usr/libexec/PlistBuddy -c "Print :com.apple.ManagedClient.enroll" "$ldp" 2>/dev/null
  [ "$output" = "true" ]
}

@test "dry-run mode does not write files" {
  DRY_RUN=true
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/private/etc/hosts" ]
  [ ! -f "$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist" ]
}

@test "suppress_enrollment cleans user artifacts" {
  touch "$TEST_DIR/Users/testuser/Library/Preferences/com.apple.mdm.test"
  touch "$TEST_DIR/Users/testuser/Library/Application Support/com.apple.ManagedClient.cache"
  DRY_RUN=false
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/Users/testuser/Library/Preferences/com.apple.mdm.test" ]
  [ ! -f "$TEST_DIR/Users/testuser/Library/Application Support/com.apple.ManagedClient.cache" ]
}

@test "suppress_enrollment blocks org MDM host" {
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  cat > "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>OrganizationName</key><string>ACME Corp</string>
<key>URL</key><string>https://mdm.acme.com/enroll</string>
</dict></plist>
XML
  DRY_RUN=false
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  run grep -c "mdm.acme.com" "$TEST_DIR/private/etc/hosts"
  [ "$output" -gt 0 ]
}

@test "wipe_dep_records clears all cloudConfig files and flags" {
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Store"
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigTimerCheck"
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/com.apple.mdm.prelogin.plist"
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Store/test.profile"
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/.profilesAreInstalled"
  DRY_RUN=false
  wipe_dep_records "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigTimerCheck" ]
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/com.apple.mdm.prelogin.plist" ]
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Store/test.profile" ]
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/.profilesAreInstalled" ]
  [ -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound" ]
}

@test "auto_recovery_mode respects DRY_RUN" {
  DRY_RUN=true
  auto_recovery_mode "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/private/etc/hosts" ]
}

@test "suppress_enrollment dry-run names 14 domains and 10 labels" {
  DRY_RUN=true
  run suppress_enrollment "$TEST_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '14 Apple MDM domains'
  echo "$output" | grep -q '10 enrollment daemons'
  [ ! -f "$TEST_DIR/private/etc/hosts" ]
}

