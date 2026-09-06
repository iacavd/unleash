#!/usr/bin/env bats
# Live Recovery / FileVault / pfctl checklist. Skipped in CI unless UNLEASH_LIVE=1.

setup() {
  if [ "${UNLEASH_LIVE:-0}" != 1 ]; then
    skip "requires UNLEASH_LIVE=1"
  fi
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

@test "live: dscacheutil exists for DNS probe" {
  [ -x /usr/bin/dscacheutil ]
}

@test "live: diskutil and PlistBuddy exist" {
  [ -x /usr/sbin/diskutil ]
  [ -x /usr/libexec/PlistBuddy ]
}

@test "live: status --json exits 0 or 3 and is an object" {
  run "$ROOT/unleash" status --json
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
  [ "$status" -ne 4 ]
  echo "$output" | grep -q '{'
}

@test "live: doctor --gate exits 0 or 2" {
  run "$ROOT/unleash" doctor --gate
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

@test "live: status/audit/report sources do not pkill" {
  if grep -nE '(^|[[:space:]])pkill([[:space:]]|$)' "$ROOT/lib/status.sh" "$ROOT/lib/report.sh"; then
    echo "status/report must not pkill" >&2
    return 1
  fi
}
