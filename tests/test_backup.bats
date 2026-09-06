#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/backup.sh'
  VERSION="2.0.0"
  TEST_DIR=$(mktemp -d)
  BACKUP_DIR="$TEST_DIR/.unleash-backup"
  BACKUP_RETENTION=3
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/etc/pf.anchors"
  echo "test hosts" > "$TEST_DIR/private/etc/hosts"
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "backup_state creates snapshot directory" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  local snapshots
  snapshots=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | wc -l | tr -d ' ')
  [ "$snapshots" -ge 1 ]
}

@test "backup_state saves hosts file" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -f "$snapshot/hosts.backup" ]
}

@test "backup_state saves config profiles" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -d "$snapshot/ConfigurationProfiles" ]
}

@test "backup_state saves pf.conf" {
  echo "test pf" > "$TEST_DIR/etc/pf.conf"
  backup_state "$TEST_DIR" 2>/dev/null || true
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -f "$snapshot/pf/pf.conf.backup" ]
}

@test "backup_state generates manifest.json" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -f "$snapshot/manifest.json" ]
}

@test "manifest.json contains version field" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  run grep -c "version" "$snapshot/manifest.json"
  [ "$output" -ge 1 ]
}

@test "has_backup returns true after backup" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  run has_backup
  [ "$status" -eq 0 ]
}

@test "backup_rotate keeps only N backups" {
  BACKUP_RETENTION=2
  # Create 4 backups with different timestamps
  for i in 1 2 3 4; do
    local ts="2024-01-0${i}_12-00-00"
    mkdir -p "$BACKUP_DIR/$ts"
    echo "$ts" > "$BACKUP_DIR/$ts/timestamp"
  done
  backup_rotate
  local count
  count=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -le 2 ]
}

@test "backup_list runs without error" {
  backup_state "$TEST_DIR" 2>/dev/null || true
  run backup_list 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "check_disk_space passes with enough space" {
  run check_disk_space "/" 2>/dev/null
  [ "$status" -eq 0 ]
}
