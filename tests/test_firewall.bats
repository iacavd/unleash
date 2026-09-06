#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/whitelist.sh'
  load '../lib/firewall.sh'
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/etc/pf.anchors/com.unleash"
  mkdir -p "$TEST_DIR/private/etc"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "install_pf_mdm_block creates anchor (default=selective)" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/etc/pf.anchors/com.unleash/mdm" ]
}

@test "install_pf_mdm_block_selective creates selective anchor" {
  run install_pf_mdm_block_selective "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/etc/pf.anchors/com.unleash/mdm" ]
  # Should NOT have the broad 17.0.0.0/8 range
  run grep -c "17.0.0.0/8" "$TEST_DIR/etc/pf.anchors/com.unleash/mdm" || true
  [ "${output:-0}" -eq 0 ]
}

@test "install_pf_mdm_block_broad creates broad anchor" {
  run install_pf_mdm_block_broad "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/etc/pf.anchors/com.unleash/mdm" ]
  run grep -c "17.0.0.0/8" "$TEST_DIR/etc/pf.anchors/com.unleash/mdm"
  [ "$output" -ge 1 ]
}

@test "install_pf_mdm_block_broad includes warning comment" {
  run install_pf_mdm_block_broad "$TEST_DIR" 2>/dev/null || true
  run grep -c "BROAD" "$TEST_DIR/etc/pf.anchors/com.unleash/mdm"
  [ "$output" -ge 1 ]
}

@test "install_pf_mdm_block creates pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/etc/pf.conf" ]
}

@test "install_pf_mdm_block adds anchor to pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/etc/pf.conf"
  [ "$output" -ge 1 ]
}

@test "install_pf_mdm_block is idempotent on pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/etc/pf.conf"
  [ "$output" -ge 1 ]
  [ "$output" -le 3 ]
}

@test "remove_pf_mdm_block cleans anchor file" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run remove_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/etc/pf.anchors/com.unleash/mdm" ]
}

@test "remove_pf_mdm_block cleans pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run remove_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/etc/pf.conf" || true
  [ "${output:-0}" -eq 0 ]
}

@test "pf_backup_anchor creates backup file" {
  echo "test" > "$TEST_DIR/etc/pf.anchors/com.unleash/mdm"
  run pf_backup_anchor "$TEST_DIR" 2>/dev/null || true
  run ls "$TEST_DIR/etc/pf.anchors/com.unleash/mdm.backup."* 2>/dev/null
  [ -n "$output" ]
}

@test "pf_backup_conf creates backup file" {
  echo "test" > "$TEST_DIR/etc/pf.conf"
  run pf_backup_conf "$TEST_DIR" 2>/dev/null || true
  run ls "$TEST_DIR/etc/pf.conf.backup."* 2>/dev/null
  [ -n "$output" ]
}
