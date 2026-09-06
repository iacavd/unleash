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
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "install_pf_mdm_block creates anchor (default=selective)" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
}

@test "install_pf_mdm_block_selective creates selective anchor" {
  run install_pf_mdm_block_selective "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  run grep -c "17.0.0.0/8" "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" || true
  [ "${output:-0}" -eq 0 ]
}

@test "install_pf_mdm_block_broad creates broad anchor" {
  run install_pf_mdm_block_broad "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  run grep -c "17.0.0.0/8" "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  [ "$output" -ge 1 ]
}

@test "install_pf_mdm_block_broad includes warning comment" {
  run install_pf_mdm_block_broad "$TEST_DIR" 2>/dev/null || true
  run grep -c "BROAD" "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  [ "$output" -ge 1 ]
}

@test "install_pf_mdm_block creates pf.conf under private/etc" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/private/etc/pf.conf" ]
  [ ! -f "$TEST_DIR/etc/pf.conf" ]
}

@test "install_pf_mdm_block adds anchor to pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/private/etc/pf.conf"
  [ "$output" -ge 1 ]
}

@test "install_pf_mdm_block is idempotent on pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/private/etc/pf.conf"
  [ "$output" -ge 1 ]
  [ "$output" -le 3 ]
}

@test "remove_pf_mdm_block cleans anchor file" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run remove_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
}

@test "remove_pf_mdm_block cleans pf.conf" {
  run install_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run remove_pf_mdm_block "$TEST_DIR" 2>/dev/null || true
  run grep -c "com.unleash" "$TEST_DIR/private/etc/pf.conf" || true
  [ "${output:-0}" -eq 0 ]
}

@test "pf_backup_anchor creates backup file" {
  echo "test" > "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  run pf_backup_anchor "$TEST_DIR" 2>/dev/null || true
  run ls "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm.backup."* 2>/dev/null
  [ -n "$output" ]
}

@test "pf_backup_conf creates backup file" {
  echo "test" > "$TEST_DIR/private/etc/pf.conf"
  run pf_backup_conf "$TEST_DIR" 2>/dev/null || true
  run ls "$TEST_DIR/private/etc/pf.conf.backup."* 2>/dev/null
  [ -n "$output" ]
}

@test "selective DNS fail with TSV writes non-empty anchor" {
  USB=$(mktemp -d)
  mkdir -p "$USB/data"
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  cp "$REPO/data/mdm-ips.tsv" "$USB/data/mdm-ips.tsv"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  _resolve_dns() { return 1; }
  install_pf_mdm_block_selective "$TEST_DIR"
  anchor="$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  [ -s "$anchor" ]
  grep -q "17.253.34.253" "$anchor"
  grep -q "block drop" "$anchor"
  [ ! -f "$TEST_DIR/etc/pf.anchors/com.unleash.selective" ]
  rm -rf "$USB"
}

@test "selective DNS fail with empty TSV does not write empty anchor" {
  USB=$(mktemp -d)
  mkdir -p "$USB/data"
  printf '%s\n' '# domain	ipv4	ipv6	retrieved_at' > "$USB/data/mdm-ips.tsv"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  _resolve_dns() { return 1; }
  rm -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  install_pf_mdm_block_selective "$TEST_DIR"
  [ ! -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  [ "$RESULT_REASON" = "E_DNS_FAIL" ]
  [ "$RESULT_STATUS" = "skip" ]
  rm -rf "$USB"
}

@test "Recovery pf path uses private/etc not etc/pf.conf" {
  DATA_ROOT="$TEST_DIR"
  install_pf_mdm_block "$TEST_DIR"
  [ -f "$TEST_DIR/private/etc/pf.conf" ]
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  [ ! -f "$TEST_DIR/etc/pf.conf" ]
  grep -q 'com.unleash/mdm' "$TEST_DIR/private/etc/pf.conf"
  if grep -q 'com.unleash.selective' "$TEST_DIR/private/etc/pf.conf"; then
    echo "must not install dual-anchor com.unleash.selective" >&2
    return 1
  fi
}

@test "Recovery S_PF_RECOVERY does not pfctl the Data conf" {
  DATA_ROOT="$TEST_DIR"
  PFCTL_LOG="$TEST_DIR/pfctl.log"
  PFCTL="$TEST_DIR/fake-pfctl"
  cat > "$PFCTL" <<EOF
#!/bin/bash
echo "\$@" >> "$PFCTL_LOG"
exit 1
EOF
  chmod +x "$PFCTL"
  is_recovery() { return 0; }
  install_pf_mdm_block_selective "$TEST_DIR"
  [ "$RESULT_REASON" = "S_PF_RECOVERY" ]
  [ "$RESULT_STATUS" = "skip" ]
  [ -f "$TEST_DIR/private/etc/pf.conf" ]
  [ ! -f "$PFCTL_LOG" ]
}

@test "zero-IP path strips leftover com.unleash.selective" {
  USB=$(mktemp -d)
  mkdir -p "$USB/data" "$TEST_DIR/etc/pf.anchors" "$TEST_DIR/private/etc/pf.anchors"
  printf '%s\n' '# domain	ipv4	ipv6	retrieved_at' > "$USB/data/mdm-ips.tsv"
  echo leftover > "$TEST_DIR/etc/pf.anchors/com.unleash.selective"
  echo leftover > "$TEST_DIR/private/etc/pf.anchors/com.unleash.selective"
  printf '%s\n' 'anchor "com.unleash.selective"' > "$TEST_DIR/private/etc/pf.conf"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  _resolve_dns() { return 1; }
  install_pf_mdm_block_selective "$TEST_DIR"
  [ "$RESULT_REASON" = "E_DNS_FAIL" ]
  [ ! -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  [ ! -f "$TEST_DIR/etc/pf.anchors/com.unleash.selective" ]
  [ ! -f "$TEST_DIR/private/etc/pf.anchors/com.unleash.selective" ]
  if grep -q 'com.unleash.selective' "$TEST_DIR/private/etc/pf.conf"; then
    echo "selective leftover should be stripped on E_DNS_FAIL" >&2
    rm -rf "$USB"
    return 1
  fi
  rm -rf "$USB"
}
