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
  got=$(journal_resume_scan)
  [ "$got" = "$unfinished" ]
  journal_commit
  got=$(journal_resume_scan)
  [ -z "$got" ]
}
