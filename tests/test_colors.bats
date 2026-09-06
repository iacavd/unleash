#!/usr/bin/env bats
# Tests for colors.sh - run with: bats tests/test_colors.bats

setup() {
  load '../lib/colors.sh'
  TEST_LOG=$(mktemp)
  TEST_RODIR=$(mktemp -d)
}

teardown() {
  rm -f "$TEST_LOG"
  if [ -n "${TEST_RODIR:-}" ] && [ -d "$TEST_RODIR" ]; then
    chmod -R u+w "$TEST_RODIR" 2>/dev/null || true
    rm -rf "$TEST_RODIR"
  fi
}

@test "log writes to LOG_FILE when set" {
  LOG_FILE="$TEST_LOG"
  log "INFO" "test message"
  run grep "test message" "$TEST_LOG"
  [ "$status" -eq 0 ]
}

@test "log respects VERBOSE for DEBUG" {
  VERBOSE=false
  run log "DEBUG" "hidden message"
  [ -z "$output" ]
}

@test "log shows DEBUG when VERBOSE is true" {
  VERBOSE=true
  run log "DEBUG" "visible message"
  echo "$output" | grep -q "visible"
}

@test "error_exit exits with non-zero" {
  run error_exit "test error" 2>/dev/null
  [ "$status" -ne 0 ]
}

@test "header outputs formatted title" {
  run header "Test Title"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Test Title"
}

@test "info writes nothing to stdout" {
  stdout_only=$(info "hello" 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "step writes nothing to stdout" {
  stdout_only=$(step "hello" 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "success writes nothing to stdout" {
  stdout_only=$(success "hello" 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "warn writes nothing to stdout" {
  stdout_only=$(warn "hello" 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "info writes message to stderr" {
  stderr_only=$(info "hello" 2>&1 >/dev/null)
  echo "$stderr_only" | grep -q "hello"
}

@test "stderr kv contains level= and ts=" {
  stderr_only=$(info "hello" 2>&1 >/dev/null)
  echo "$stderr_only" | grep -q "level="
  echo "$stderr_only" | grep -q "ts="
}

@test "stdout of info contains no ANSI" {
  stdout_only=$(info "hello" 2>/dev/null)
  [ -z "$stdout_only" ]
  case "$stdout_only" in
    *$'\033'*) false ;;
  esac
}

@test "info stderr has no ANSI when not a tty" {
  stderr_only=$(info "hello" 2>&1 >/dev/null)
  case "$stderr_only" in
    *$'\033'*) false ;;
  esac
}

@test "header writes title to stderr not stdout" {
  stdout_only=$(header "Test Title" 2>/dev/null)
  stderr_only=$(header "Test Title" 2>&1 >/dev/null)
  [ -z "$stdout_only" ]
  echo "$stderr_only" | grep -q "Test Title"
}

@test "header has no box drawing when not a tty" {
  stderr_only=$(header "Test Title" 2>&1 >/dev/null)
  if echo "$stderr_only" | grep -q "╔"; then
    false
  fi
}

@test "DEBUG is silent on stderr when VERBOSE is false" {
  VERBOSE=false
  stderr_only=$(debug "hidden message" 2>&1 >/dev/null)
  [ -z "$stderr_only" ]
}

@test "set_log_file fails when parent does not exist" {
  run set_log_file "/no/such/unleash-log-dir-$$/app.log"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "E_LOG_UNWRITABLE"
}

@test "set_log_file fails when parent is not writable" {
  chmod a-w "$TEST_RODIR"
  run set_log_file "$TEST_RODIR/unleash.log"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "E_LOG_UNWRITABLE"
}

@test "log fails when LOG_FILE parent does not exist" {
  LOG_FILE="/no/such/unleash-log-dir-$$/app.log"
  run log "INFO" "should fail"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "E_LOG_UNWRITABLE"
}

@test "set_log_file then log appends plain kv to the file" {
  set_log_file "$TEST_LOG"
  log "INFO" "file-ok"
  grep -q "file-ok" "$TEST_LOG"
  grep -q "level=" "$TEST_LOG"
  if grep -q $'\033' "$TEST_LOG"; then
    false
  fi
}
