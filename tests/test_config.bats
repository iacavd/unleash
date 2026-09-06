#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/config.sh'
  TEST_DIR=$(mktemp -d)
  CONFIG_FILE="$TEST_DIR/.unleash.conf"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "load_config handles missing config file" {
  CONFIG_FILE="$TEST_DIR/nonexistent"
  run load_config
  [ "$status" -eq 0 ]
}

@test "save_config creates config file" {
  save_config "TEST_KEY" "test_value" 2>/dev/null
  [ -f "$CONFIG_FILE" ]
  run grep -c "TEST_KEY=test_value" "$CONFIG_FILE"
  [ "$output" -ge 1 ]
}

@test "save_config updates existing key" {
  echo "KEY=old" > "$CONFIG_FILE"
  save_config "KEY" "new" 2>/dev/null
  run grep "KEY=" "$CONFIG_FILE"
  [[ "$output" == "KEY=new" ]]
}

@test "save_config appends new key" {
  echo "EXISTING=value" > "$CONFIG_FILE"
  save_config "NEW_KEY" "new_value" 2>/dev/null
  run grep -c "NEW_KEY=new_value" "$CONFIG_FILE"
  [ "$output" -ge 1 ]
  run grep -c "EXISTING=value" "$CONFIG_FILE"
  [ "$output" -ge 1 ]
}

@test "load_config reads WEBHOOK" {
  echo "WEBHOOK=https://example.com/hook" > "$CONFIG_FILE"
  load_config
  [ "$DISCORD_WEBHOOK" = "https://example.com/hook" ]
}

@test "load_config reads AUTO_USERNAME" {
  echo "AUTO_USERNAME=testuser" > "$CONFIG_FILE"
  load_config
  [ "$AUTO_USERNAME" = "testuser" ]
}

@test "load_config reads AUTO_PASSWORD" {
  echo "AUTO_PASSWORD=testpass" > "$CONFIG_FILE"
  load_config
  [ "$AUTO_PASSWORD" = "testpass" ]
}

@test "load_config reads BACKUP_RETENTION" {
  echo "BACKUP_RETENTION=10" > "$CONFIG_FILE"
  load_config
  [ "$BACKUP_RETENTION" = "10" ]
}

@test "load_config skips comment lines" {
  echo "# This is a comment" > "$CONFIG_FILE"
  echo "WEBHOOK=test" >> "$CONFIG_FILE"
  run load_config
  [ "$status" -eq 0 ]
}

@test "load_config handles LOG_LEVEL=verbose" {
  VERBOSE=false
  echo "LOG_LEVEL=verbose" > "$CONFIG_FILE"
  load_config
  [ "$VERBOSE" = "true" ]
}

@test "load_config reads I_OWN_THIS_DEVICE" {
  echo "I_OWN_THIS_DEVICE=1" > "$CONFIG_FILE"
  load_config
  [ "$UNLEASH_USB_INTENT" = 1 ]
}

@test "home I_OWN_THIS_DEVICE does not count as USB sidecar" {
  echo "I_OWN_THIS_DEVICE=1" > "$CONFIG_FILE"
  SCRIPT_DIR="$TEST_DIR"
  load_config
  run usb_sidecar_present
  [ "$status" -ne 0 ]
}

@test "USB unleash.conf I_OWN_THIS_DEVICE is a sidecar" {
  SCRIPT_DIR="$TEST_DIR"
  echo "I_OWN_THIS_DEVICE=1" > "$TEST_DIR/unleash.conf"
  run usb_sidecar_present
  [ "$status" -eq 0 ]
}
