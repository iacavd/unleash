#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  load '../lib/backup.sh'
  VERSION="2.0.0"
  TEST_DIR=$(mktemp -d)
  BACKUP_DIR="$TEST_DIR/.unleash-backup"
  BACKUP_RETENTION=3
  UNLEASH_UNATTENDED=0
  RESULT_STATUS=ok
  RESULT_REASON=""
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
  backup_state "$TEST_DIR"
  local snapshots
  snapshots=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | wc -l | tr -d ' ')
  [ "$snapshots" -ge 1 ]
}

@test "backup_state saves hosts file" {
  backup_state "$TEST_DIR"
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -f "$snapshot/hosts.backup" ]
}

@test "backup_state saves config profiles" {
  backup_state "$TEST_DIR"
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -d "$snapshot/ConfigurationProfiles" ]
}

@test "backup_state saves pf.conf" {
  echo "test pf" > "$TEST_DIR/etc/pf.conf"
  backup_state "$TEST_DIR"
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -f "$snapshot/pf/pf.conf.backup" ]
}

@test "backup_state generates manifest.json" {
  backup_state "$TEST_DIR"
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  [ -f "$snapshot/manifest.json" ]
}

@test "manifest.json contains version field" {
  backup_state "$TEST_DIR"
  local snapshot
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? 2>/dev/null | head -1)
  run grep -c "version" "$snapshot/manifest.json"
  [ "$output" -ge 1 ]
}

@test "has_backup returns true after backup" {
  backup_state "$TEST_DIR"
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
  backup_state "$TEST_DIR"
  run backup_list
  [ "$status" -eq 0 ]
}

@test "check_disk_space passes with enough space" {
  run check_disk_space "/" 2>/dev/null
  [ "$status" -eq 0 ]
}

@test "unattended E_DISK_FULL when space low" {
  DF="$TEST_DIR/fake_df"
  cat > "$DF" << 'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 20480 20000 100 99% /tmp"
EOF
  chmod +x "$DF"
  UNLEASH_UNATTENDED=1
  rc=0
  check_disk_space "$TEST_DIR" 2>"$TEST_DIR/err" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_REASON" = "E_DISK_FULL" ]
  [ "$RESULT_STATUS" = "fail" ]
  if grep -q "Continue anyway" "$TEST_DIR/err"; then
    false
  fi
}

@test "rollback restores a hosts file from snapshot" {
  echo "original hosts" > "$TEST_DIR/private/etc/hosts"
  backup_state "$TEST_DIR"
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? | head -1)
  [ -n "$snapshot" ]
  echo "mutated hosts" > "$TEST_DIR/private/etc/hosts"
  rollback_hosts "$(basename "$snapshot")" "$TEST_DIR"
  [ "$(cat "$TEST_DIR/private/etc/hosts")" = "original hosts" ]
}

@test "unattended unparseable df is E_DISK_FULL" {
  DF="$TEST_DIR/fake_df"
  cat > "$DF" << 'EOF'
#!/bin/bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "not-a-df-line"
EOF
  chmod +x "$DF"
  UNLEASH_UNATTENDED=1
  rc=0
  check_disk_space "$TEST_DIR" 2>"$TEST_DIR/err" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_REASON" = "E_DISK_FULL" ]
}

@test "backup_rotate keeps full directories when BACKUP_DIR has spaces" {
  BACKUP_DIR="$TEST_DIR/Macintosh HD - Data/snapshots"
  mkdir -p "$BACKUP_DIR"
  BACKUP_RETENTION=2
  for i in 1 2 3 4; do
    ts="2024-01-0${i}_12-00-00"
    mkdir -p "$BACKUP_DIR/$ts"
    echo "$ts" > "$BACKUP_DIR/$ts/timestamp"
  done
  backup_rotate
  [ -d "$BACKUP_DIR/2024-01-03_12-00-00" ]
  [ -d "$BACKUP_DIR/2024-01-04_12-00-00" ]
  [ ! -d "$BACKUP_DIR/2024-01-01_12-00-00" ]
  [ ! -d "$BACKUP_DIR/2024-01-02_12-00-00" ]
  [ ! -e "$TEST_DIR/Macintosh" ]
  [ ! -e "$TEST_DIR/HD" ]
  [ ! -d "$TEST_DIR/-" ]
}

@test "backup_list lists snapshots when BACKUP_DIR has spaces" {
  BACKUP_DIR="$TEST_DIR/Macintosh HD - Data/snapshots"
  mkdir -p "$BACKUP_DIR/2024-02-01_12-00-00"
  echo "2024-02-01_12-00-00" > "$BACKUP_DIR/2024-02-01_12-00-00/timestamp"
  echo "$TEST_DIR" > "$BACKUP_DIR/2024-02-01_12-00-00/data_volume_path"
  run backup_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"2024-02-01_12-00-00"* ]]
}

@test "snapshot round-trips under DATA_ROOT with spaces" {
  BACKUP_DIR=""
  DATA_ROOT="$TEST_DIR/Macintosh HD - Data"
  mkdir -p "$DATA_ROOT/private/etc"
  mkdir -p "$DATA_ROOT/private/var/db/ConfigurationProfiles/Settings"
  echo "space hosts" > "$DATA_ROOT/private/etc/hosts"
  touch "$DATA_ROOT/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  backup_state "$DATA_ROOT"
  root="$DATA_ROOT/Library/Unleash/state/snapshots"
  snapshot=""
  while IFS= read -r snapshot; do
    [ -n "$snapshot" ] && break
  done <<EOF
$(ls -1d "$root"/????-??-??_??-??-?? 2>/dev/null)
EOF
  [ -n "$snapshot" ]
  [ -f "$snapshot/hosts.backup" ]
  echo "mutated hosts" > "$DATA_ROOT/private/etc/hosts"
  rollback_hosts "$(basename "$snapshot")" "$DATA_ROOT"
  [ "$(cat "$DATA_ROOT/private/etc/hosts")" = "space hosts" ]
}

@test "failed rollback_dep leaves live DEP dir intact" {
  echo "live-dep" > "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/keep-me"
  backup_state "$TEST_DIR"
  snapshot=$(ls -1d "$BACKUP_DIR"/????-??-??_??-??-?? | head -1)
  echo "mutated-dep" > "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/keep-me"
  CP="$TEST_DIR/fail_cp"
  cat > "$CP" << 'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$CP"
  rc=0
  rollback_dep "$(basename "$snapshot")" "$TEST_DIR" || rc=$?
  [ "$rc" -ne 0 ]
  [ -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/keep-me" ]
  [ "$(cat "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/keep-me")" = "mutated-dep" ]
  [ ! -d "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings.unleash-new.$$" ]
}
