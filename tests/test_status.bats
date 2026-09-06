#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/status.sh'
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "check_mdm_status exits cleanly" {
  run check_mdm_status "$TEST_DIR" 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "deep_status exits cleanly" {
  run deep_status 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "deep_status_json contains braces" {
  run deep_status_json 2>/dev/null || true
  echo "$output" | grep -q "}"
}

@test "deep_status uses UNLEASH_JSON without argv --json" {
  UNLEASH_JSON=1
  run deep_status 2>/dev/null || true
  echo "$output" | grep -q "}"
}

@test "status.sh does not pkill" {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  if grep -nE '(^|[[:space:]])pkill([[:space:]]|$)' "$ROOT/lib/status.sh"; then
    echo "status.sh must not pkill" >&2
    return 1
  fi
}

@test "check_mdm_status works with a fixture volume (live or Recovery path)" {
  echo "0.0.0.0 iprofiles.apple.com" > "$TEST_DIR/private/etc/hosts"
  echo "0.0.0.0 deviceenrollment.apple.com" >> "$TEST_DIR/private/etc/hosts"
  echo "0.0.0.0 mdmenrollment.apple.com" >> "$TEST_DIR/private/etc/hosts"
  run check_mdm_status "$TEST_DIR"
  [ "$status" -eq 0 ]
}
