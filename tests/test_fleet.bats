#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/config.sh'
  load '../lib/suppress.sh'
  load '../lib/whitelist.sh'
  load '../lib/firewall.sh'
  load '../lib/heal.sh'
  load '../lib/webhook.sh'
  load '../lib/fleet.sh'
  TEST_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "cmd_fleet_apply fails gracefully without manifest" {
  run cmd_fleet_apply
  [ "$status" -ne 0 ]
}

@test "cmd_fleet_apply parses conf manifest file" {
  local conf="$TEST_DIR/fleet.conf"
  cat <<EOF > "$conf"
ADMIN_USER="testadmin"
ADMIN_PASS="pass123"
FIREWALL_MODE="selective"
EOF

  cmd_fleet_apply --manifest "$conf"
}
