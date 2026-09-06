#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load '../lib/colors.sh'
  load '../lib/harden.sh'
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
  grep -n 'if profiles -D -F' "$ROOT/lib/harden.sh"
  awk '
    /^_harden_remove_all_profiles\(\)/ { inh=1 }
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ && !/_harden_remove_all_profiles/ { inh=0 }
    inh && /if profiles -D -F/ { ok=1 }
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
