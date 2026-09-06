#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  load '../lib/backup.sh'
  load '../lib/pipeline.sh'
  DATA_ROOT=$(mktemp -d)
  UNLEASH_UNATTENDED=0
  JOURNAL_RUN=""
  RESULT_STATUS=ok
  RESULT_REASON=""
}

teardown() {
  pipeline_lock_release || true
  if [ -n "${DATA_ROOT:-}" ] && [ -d "$DATA_ROOT" ]; then
    rm -rf "$DATA_ROOT"
  fi
}

@test "encode/decode roundtrip with spaces and quotes" {
  input='say "hello" and 100% done = yes'
  encoded=$(_kv_encode "$input")
  decoded=$(_kv_decode "$encoded")
  [ "$decoded" = "$input" ]
  case "$encoded" in
    *' '*) false ;;
  esac
  case "$encoded" in
    *'"'*) false ;;
  esac
  case "$encoded" in
    *'='*) false ;;
  esac
  [[ "$encoded" == *"%20"* ]]
  [[ "$encoded" == *"%22"* ]]
  [[ "$encoded" == *"%25"* ]]
  [[ "$encoded" == *"%3D"* ]]
}

@test "encode volume path matches percent-encoded slash and spaces" {
  encoded=$(_kv_encode "/Volumes/Macintosh HD - Data")
  [ "$encoded" = "%2FVolumes%2FMacintosh%20HD%20-%20Data" ]
  [ "$(_kv_decode "$encoded")" = "/Volumes/Macintosh HD - Data" ]
}

@test "encode/decode tab and CR" {
  input=$(printf 'a\tb\rc')
  encoded=$(_kv_encode "$input")
  [ "$encoded" = "a%09b%0Dc" ]
  [ "$(_kv_decode "$encoded")" = "$input" ]
}

@test "WAL start then ok" {
  journal_begin apply "/Volumes/Macintosh HD - Data"
  journal_step hosts start
  journal_step hosts ok
  journal="$(_journal_path)"
  [ -f "$journal" ]
  grep -q 'op=BEGIN' "$journal"
  grep -q 'volume=%2FVolumes%2FMacintosh%20HD%20-%20Data' "$journal"
  start_line=$(grep -n 'op=STEP' "$journal" | grep 'name=hosts' | grep 'status=start' | head -1 | cut -d: -f1)
  ok_line=$(grep -n 'op=STEP' "$journal" | grep 'name=hosts' | grep 'status=ok' | head -1 | cut -d: -f1)
  [ -n "$start_line" ]
  [ -n "$ok_line" ]
  [ "$start_line" -lt "$ok_line" ]
}

@test "lock steal if dead pid" {
  mkdir -p "$(_state_dir)"
  sleep 30 &
  dead=$!
  kill "$dead"
  wait "$dead" 2>/dev/null || true
  printf 'pid=%s ts=%s\n' "$dead" "2026-01-01T00:00:00Z" > "$(_lock_path)"
  pipeline_lock_acquire
  lock=$(cat "$(_lock_path)")
  [[ "$lock" == *"pid=$$"* ]]
}

@test "lock refuse if pid alive" {
  pipeline_lock_acquire
  rc=0
  pipeline_lock_acquire || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_REASON" = "E_LOCKED" ]
  [ "$RESULT_STATUS" = "fail" ]
}

@test "journal_resume_scan finds last unfinished BEGIN" {
  journal_begin apply /vol
  unfinished="$JOURNAL_RUN"
  journal_step hosts start
  JOURNAL_RUN="sentinel"
  got=$(journal_resume_scan)
  [ "$got" = "$unfinished" ]
  [ "$JOURNAL_RUN" = "sentinel" ]
  JOURNAL_RUN="$got"
  journal_commit
  got=$(journal_resume_scan)
  [ -z "$got" ]
}

@test "journal_degraded then journal_commit leaves degraded file" {
  journal_begin apply /vol
  journal_degraded S_SIP_LIVE "Boot Recovery"
  [ -f "$(_state_dir)/degraded" ]
  journal_commit
  [ -f "$(_state_dir)/degraded" ]
  grep -q 'op=DEGRADED' "$(_journal_path)"
  grep -q 'op=COMMIT' "$(_journal_path)"
}

@test "success journal_commit clears degraded" {
  journal_begin apply /vol
  journal_degraded S_SIP_LIVE "x"
  journal_commit
  [ -f "$(_state_dir)/degraded" ]
  journal_begin apply /vol
  journal_commit
  [ ! -f "$(_state_dir)/degraded" ]
}

@test "EXIT trap releases lock" {
  (
    trap 'pipeline_lock_release' EXIT
    pipeline_lock_acquire
    [ -d "$(_lock_dir)" ]
    [ -f "$(_lock_path)" ]
  )
  [ ! -d "$(_lock_dir)" ]
  [ ! -f "$(_lock_path)" ]
}

@test "password_from_file is not captured in a subshell in pipeline dscl" {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  if grep -E 'password=\$\(password_from_file' "$ROOT/lib/pipeline.sh"; then
    echo "password_from_file must not run in \$()" >&2
    return 1
  fi
}

@test "pipeline_rollback_files restores hosts" {
  mkdir -p "$DATA_ROOT/private/etc"
  echo "original hosts" > "$DATA_ROOT/private/etc/hosts"
  backup_state "$DATA_ROOT"
  echo "mutated hosts" > "$DATA_ROOT/private/etc/hosts"
  pipeline_rollback_files "$SNAPSHOT_ID" "$DATA_ROOT"
  [ "$(cat "$DATA_ROOT/private/etc/hosts")" = "original hosts" ]
}

@test "result_skip under set -e does not abort pipeline_run" {
  load '../lib/config.sh'
  load '../lib/validate.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  load '../lib/firewall.sh'
  load '../lib/ma_detect.sh'
  mkdir -p "$DATA_ROOT/private/var/db/dslocal/nodes/Default"
  mkdir -p "$DATA_ROOT/private/etc"
  mkdir -p "$DATA_ROOT/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$DATA_ROOT/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$DATA_ROOT/Library/Unleash/state"
  printf 'owned=1\nts=2026-09-06T00:00:00Z\nvolume_uuid=\n' > "$DATA_ROOT/Library/Unleash/state/intent"
  UNLEASH_VOLUME="$DATA_ROOT"
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=0
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  wipe_dep_records() {
    result_skip S_SIP_LIVE suppress dep_wipe "DEP remains under SIP"
    return 0
  }
  set -e
  run pipeline_run
  [ "$status" -eq 3 ]
  echo "$output" | grep -q S_SIP_LIVE
  grep -q "iprofiles.apple.com" "$DATA_ROOT/private/etc/hosts"
  journal="$DATA_ROOT/Library/Unleash/state/journal"
  grep -q 'op=BEGIN' "$journal"
  grep -q 'name=dep_wipe' "$journal"
  grep -q 'status=skip' "$journal"
}

@test "heal resume does not journal_begin over an unfinished run" {
  load '../lib/config.sh'
  load '../lib/validate.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  load '../lib/firewall.sh'
  load '../lib/ma_detect.sh'
  mkdir -p "$DATA_ROOT/private/var/db/dslocal/nodes/Default"
  mkdir -p "$DATA_ROOT/private/etc"
  mkdir -p "$DATA_ROOT/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$DATA_ROOT/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$DATA_ROOT/Library/Unleash/state"
  printf 'owned=1\nts=2026-09-06T00:00:00Z\nvolume_uuid=\n' > "$DATA_ROOT/Library/Unleash/state/intent"
  UNLEASH_VOLUME="$DATA_ROOT"
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=0
  UNLEASH_RESUME=1
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  journal_begin apply "$DATA_ROOT"
  first_run="$JOURNAL_RUN"
  backup_state "$DATA_ROOT"
  journal_snap "$SNAPSHOT_ID"
  journal_step hosts start
  suppress_hosts "$DATA_ROOT"
  journal_step hosts ok
  journal_step daemons start
  run pipeline_run
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
  begins=$(grep -c 'op=BEGIN' "$DATA_ROOT/Library/Unleash/state/journal")
  [ "$begins" -eq 1 ]
  grep -q "run=$first_run" "$DATA_ROOT/Library/Unleash/state/journal"
  grep 'name=daemons' "$DATA_ROOT/Library/Unleash/state/journal" | grep -q 'status=ok'
}

@test "PlistBuddy fail journals daemons fail, restores plist, exit 1" {
  load '../lib/config.sh'
  load '../lib/validate.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  load '../lib/firewall.sh'
  load '../lib/ma_detect.sh'
  mkdir -p "$DATA_ROOT/private/var/db/dslocal/nodes/Default"
  mkdir -p "$DATA_ROOT/private/etc"
  mkdir -p "$DATA_ROOT/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$DATA_ROOT/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$DATA_ROOT/Library/Unleash/state"
  printf 'owned=1\nts=2026-09-06T00:00:00Z\nvolume_uuid=\n' > "$DATA_ROOT/Library/Unleash/state/intent"
  orig='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>KeepMe</key><true/></dict></plist>'
  printf '%s\n' "$orig" > "$DATA_ROOT/private/var/db/com.apple.xpc.launchd/disabled.plist"
  UNLEASH_VOLUME="$DATA_ROOT"
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=0
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  failpb=$(mktemp)
  printf '%s\n' '#!/bin/bash' 'exit 1' > "$failpb"
  chmod +x "$failpb"
  PLISTBUDDY="$failpb"
  export PLISTBUDDY
  run cmd_apply
  rm -f "$failpb"
  [ "$status" -eq 1 ]
  journal="$DATA_ROOT/Library/Unleash/state/journal"
  grep -q 'name=daemons' "$journal"
  grep -q 'status=fail' "$journal"
  grep -q 'KeepMe' "$DATA_ROOT/private/var/db/com.apple.xpc.launchd/disabled.plist"
}

@test "pipeline_run E_VOLUME_RO exits 2 with no BEGIN" {
  load '../lib/config.sh'
  load '../lib/validate.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  resolve_data_volume() {
    result_fail E_VOLUME_RO detect remount "Data volume is read-only after mount -uw"
    return 1
  }
  UNLEASH_VOLUME="$DATA_ROOT"
  mkdir -p "$DATA_ROOT/private/var/db/dslocal/nodes/Default"
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=0
  run pipeline_run
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_VOLUME_RO
  if [ -f "$DATA_ROOT/Library/Unleash/state/journal" ]; then
    ! grep -q 'op=BEGIN' "$DATA_ROOT/Library/Unleash/state/journal"
  fi
}
