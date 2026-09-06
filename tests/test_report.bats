#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/backup.sh'
  load '../lib/report.sh'
  VERSION="2.0.0"
  BACKUP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$BACKUP_DIR"
}

@test "generate_report_brief produces single line" {
  run generate_report_brief 2>/dev/null
  [ "$status" -eq 0 ]
  # Should be a single line
  local lines
  lines=$(echo "$output" | wc -l | tr -d ' ')
  [ "$lines" -eq 1 ]
}

@test "generate_report_brief includes version" {
  run generate_report_brief 2>/dev/null
  [[ "$output" == *"v2.0.0"* ]]
}

@test "generate_report_brief includes risk level" {
  run generate_report_brief 2>/dev/null
  [[ "$output" == *"risk="* ]]
}

@test "generate_report_json produces valid-looking JSON" {
  run generate_report_json 2>/dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"version"* ]]
  [[ "$output" == *"timestamp"* ]]
  [[ "$output" == *"system"* ]]
  [[ "$output" == *"firewall"* ]]
}

@test "generate_report_json includes system info" {
  run generate_report_json 2>/dev/null
  [[ "$output" == *"macos_version"* ]]
  [[ "$output" == *"architecture"* ]]
  [[ "$output" == *"hostname"* ]]
}

@test "generate_report_json includes firewall mode" {
  run generate_report_json 2>/dev/null
  [[ "$output" == *"mdm_block_mode"* ]]
}

@test "generate_report_json includes vpn_kill_switch" {
  run generate_report_json 2>/dev/null
  [[ "$output" == *"vpn_kill_switch"* ]]
}

@test "generate_report_json includes backup_count" {
  run generate_report_json 2>/dev/null
  [[ "$output" == *"backup_count"* ]]
}

@test "generate_report_full runs without error" {
  run generate_report_full 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "generate_report_full includes section headers" {
  run generate_report_full 2>/dev/null
  [[ "$output" == *"MDM Enrollment"* ]]
  [[ "$output" == *"Firewall"* ]]
  [[ "$output" == *"Persistence"* ]]
}
