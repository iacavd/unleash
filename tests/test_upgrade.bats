#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/backup.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  load '../lib/upgrade.sh'
  TEST_DIR=$(mktemp -d)
  DRY_RUN=true
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "cmd_upgrade_os runs pre and post hooks cleanly" {
  cmd_upgrade_os "$TEST_DIR"
}
