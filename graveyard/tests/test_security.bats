#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/security.sh'
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/etc/pf.anchors"
  mkdir -p "$TEST_DIR/private/etc"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "check_security_posture exits cleanly" {
  check_security_posture
}

@test "quarantine_profiles runs and identifies test mobileconfig" {
  mkdir -p "$TEST_DIR/Library/Preferences/SystemConfiguration"
  touch "$TEST_DIR/Library/Preferences/SystemConfiguration/test.mobileconfig"

  quarantine_profiles "$TEST_DIR"
  [ ! -f "$TEST_DIR/Library/Preferences/SystemConfiguration/test.mobileconfig" ]
}
