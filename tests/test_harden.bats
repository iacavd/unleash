#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/harden.sh'
  TEST_DIR=$(mktemp -d)
  PLISTBUDDY="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "harden_live_os function exists" {
  run type harden_live_os
  [ "$status" -eq 0 ]
}

@test "default harden does not run profiles -D -F without --remove-all-profiles" {
  # D17: the data-loss command must be behind the explicit flag.
  grep -q 'profiles -D -F' "$ROOT/lib/harden.sh"
  grep -A 6 'UNLEASH_REMOVE_ALL_PROFILES' "$ROOT/lib/harden.sh" | grep -q '_harden_remove_all_profiles'
  # The actual command (not an info string) lives in the opt-in helper.
  grep -n -- '-D -F' "$ROOT/lib/harden.sh"
  awk '
    /^_harden_remove_all_profiles\(\)/ { inh=1 }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ && !/_harden_remove_all_profiles/ { inh=0 }
    inh && /-D -F/ { ok=1 }
    END { exit ok ? 0 : 1 }
  ' "$ROOT/lib/harden.sh"
}

@test "harden still pkills MDM agents (live harden, not status)" {
  grep -q 'pkill' "$ROOT/lib/harden.sh"
  if grep -nE '(^|[[:space:]])pkill([[:space:]]|$)' "$ROOT/lib/status.sh"; then
    echo "status.sh must not pkill" >&2
    return 1
  fi
}

@test "harden_live_os dry-run does not call profiles -D -F" {
  UNLEASH_DRY_RUN=1
  UNLEASH_REMOVE_ALL_PROFILES=0
  run harden_live_os
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "DRY RUN"
  ! echo "$output" | grep -q "Forced profile removal"
}

@test "harden enrollment labels are the same 10 as suppress" {
  run _harden_enrollment_labels
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'com.apple.ManagedClient'
  echo "$output" | grep -qx 'com.apple.ManagedClient.enroll'
  echo "$output" | grep -qx 'com.apple.ManagedClient.cloudConfiguration'
  echo "$output" | grep -qx 'com.apple.ManagedClientAgent'
  echo "$output" | grep -qx 'com.apple.ManagedClientAgent.agent'
  echo "$output" | grep -qx 'com.apple.mdmclient'
  echo "$output" | grep -qx 'com.apple.mdmclient.daemon'
  echo "$output" | grep -qx 'com.apple.mdmclient.daemon.runatboot'
  echo "$output" | grep -qx 'com.apple.mdmclient.agent'
  echo "$output" | grep -qx 'com.apple.activationd'
  [ "$(echo "$output" | grep -c .)" -eq 10 ]
}

@test "harden_status function exists" {
  run type harden_status
  [ "$status" -eq 0 ]
}

@test "harden in Recovery skips before /private mutate" {
  is_recovery() { return 0; }
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  RESULT_STATUS=ok
  RESULT_REASON=""
  harden_live_os
  [ "$RESULT_STATUS" = skip ]
  [ "$RESULT_REASON" = S_LIVE_ONLY ]
  [ ! -f "$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist" ]
}

@test "harden daemon disable fail-closed does not success" {
  is_recovery() { return 1; }
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  printf 'not-a-plist\n' > "$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist"
  RESULT_STATUS=ok
  RESULT_REASON=""
  harden_live_os
  [ "$RESULT_STATUS" = fail ]
  [ "$RESULT_REASON" = E_PLIST_FAIL ]
}

@test "pipeline harden reads RESULT_STATUS and does not assume ok" {
  awk '/^_pipeline_step_harden\(\)/,/^}$/' "$ROOT/lib/pipeline.sh" | grep -q harden_live_os
  if awk '/^_pipeline_step_harden\(\)/,/^}$/' "$ROOT/lib/pipeline.sh" | grep -q 'harden complete'; then
    echo "pipeline must not assume harden complete" >&2
    return 1
  fi
  grep -q 'S_LIVE_ONLY' "$ROOT/lib/pipeline.sh"
}

@test "cmd_harden maps RESULT_STATUS=fail to exit 1; S_LIVE_ONLY skip stays 0" {
  awk '/^cmd_harden\(\)/,/^}$/' "$ROOT/unleash" | grep -q 'RESULT_STATUS'
  awk '/^cmd_harden\(\)/,/^}$/' "$ROOT/unleash" | grep -q 'fail) exit 1'
  if awk '/^cmd_harden\(\)/,/^}$/' "$ROOT/unleash" | grep -q 'S_LIVE_ONLY'; then
    echo "S_LIVE_ONLY must not be treated as CLI fail" >&2
    return 1
  fi
}

@test "remove-all-profiles fail is E_PROFILES_FAIL and not ok" {
  is_recovery() { return 1; }
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  fail_bin="$TEST_DIR/fake-profiles"
  printf '%s\n' '#!/bin/bash' 'if [ "$1" = "-C" ]; then echo ProfileDisplayName; exit 0; fi' 'exit 1' > "$fail_bin"
  chmod +x "$fail_bin"
  PROFILES="$fail_bin"
  UNLEASH_REMOVE_ALL_PROFILES=1
  RESULT_STATUS=ok
  RESULT_REASON=""
  harden_live_os
  [ "$RESULT_STATUS" = fail ]
  [ "$RESULT_REASON" = E_PROFILES_FAIL ]
}

@test "harden daemon disable Print true for all 10 labels" {
  is_recovery() { return 1; }
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist"
  RESULT_STATUS=fail
  harden_live_os
  [ "$RESULT_STATUS" = ok ]
  ldp="$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist"
  while IFS= read -r label || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    val=$("$PLISTBUDDY" -c "Print :$label" "$ldp" 2>/dev/null || true)
    case "$val" in
      true|1) ;;
      *) echo "label $label is not true (got '$val')" >&2; return 1 ;;
    esac
  done <<EOF
$(_harden_enrollment_labels)
EOF
}
