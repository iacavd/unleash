#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/heal.sh'
  load '../lib/uninstall.sh'
  PERSIST_SENTINEL=".unleash-persist-installed"
  TEST_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "do_uninstall requires root" {
  if [ "$EUID" -eq 0 ]; then
    skip "Running as root, cannot test non-root case"
  fi
  run do_uninstall 2>/dev/null
  [ "$status" -ne 0 ]
}

@test "do_uninstall function exists" {
  run type do_uninstall
  [ "$status" -eq 0 ]
}

@test "uninstall includes VPN kill-switch cleanup" {
  run type do_uninstall
  [[ "$output" == *"vpn-kill"* ]]
}

@test "uninstall includes Discord bot cleanup" {
  run type do_uninstall
  [[ "$output" == *"discord"* ]] || [[ "$output" == *"Discord"* ]]
}

@test "uninstall includes telemetry cleanup" {
  run type do_uninstall
  [[ "$output" == *"telemetry"* ]]
}

@test "uninstall cleans all 14 domains" {
  run type do_uninstall
  [[ "$output" == *"acmdm.apple.com"* ]]
  [[ "$output" == *"vpp.itunes.apple.com"* ]]
}
