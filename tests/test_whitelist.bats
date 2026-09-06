#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  load '../lib/firewall.sh'
  load '../lib/whitelist.sh'
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/etc/pf.anchors/com.unleash"
  mkdir -p "$TEST_DIR/private/etc"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "_resolve_dns resolves known domain via host" {
  if ! command -v host &>/dev/null; then
    skip "host command not available"
  fi
  run _resolve_dns "apple.com" "A"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "_resolve_dns falls back to nslookup" {
  function host() { return 1; }
  export -f host
  if ! command -v nslookup &>/dev/null; then
    skip "nslookup not available"
  fi
  run _resolve_dns "apple.com" "A"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  unset -f host
}

@test "_resolve_dns returns 1 for MDM domain when DNS tools fail (no hardcoded IPs)" {
  function host() { return 1; }
  function nslookup() { return 1; }
  function dig() { return 1; }
  export -f host nslookup dig
  run _resolve_dns "deviceenrollment.apple.com" "A"
  [ "$status" -ne 0 ]
  unset -f host nslookup dig
}

@test "_resolve_dns returns 1 for unknown domain with no DNS tools" {
  function host() { return 1; }
  function nslookup() { return 1; }
  function dig() { return 1; }
  export -f host nslookup dig
  run _resolve_dns "unknown.example.com" "A"
  [ "$status" -ne 0 ]
  unset -f host nslookup dig
}

@test "install_selective_block is alias of selective firewall (com.unleash/mdm)" {
  install_selective_block "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  [ ! -f "$TEST_DIR/etc/pf.anchors/com.unleash.selective" ]
  [ ! -f "$TEST_DIR/private/etc/pf.anchors/com.unleash.selective" ]
}

@test "install_selective_block writes pf rules" {
  install_selective_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "block" "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  [ "$output" -gt 0 ]
}

@test "install_selective_block creates pf.conf under private/etc" {
  install_selective_block "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.conf" ]
}

@test "install_selective_block is idempotent" {
  install_selective_block "$TEST_DIR" 2>/dev/null || true
  install_selective_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/private/etc/pf.conf"
  [ "$output" -le 3 ]
}
