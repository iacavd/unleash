#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/check.sh'
}

@test "run_preformat_check exits cleanly" {
  run run_preformat_check 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "check_upgrade_safety exits cleanly" {
  run check_upgrade_safety 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "run_preformat_check contains SAFE or MDM" {
  run run_preformat_check 2>/dev/null || true
  echo "$output" | grep -qiE "safe|mdm"
}

@test "HTTP 000 is not reachable" {
  run http_code_reachable 000
  [ "$status" -ne 0 ]
  run http_code_reachable ""
  [ "$status" -ne 0 ]
  run http_code_reachable 000000
  [ "$status" -ne 0 ]
  run http_code_reachable 200
  [ "$status" -eq 0 ]
  run http_code_reachable 403
  [ "$status" -eq 0 ]
}

@test "check.sh does not print SAFE TO FORMAT box art" {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  if grep -q '╔' "$ROOT/lib/check.sh"; then
    echo "box drawing still in check.sh" >&2
    return 1
  fi
  if grep -q 'SAFE TO FORMAT' "$ROOT/lib/check.sh"; then
    echo "SAFE TO FORMAT slogan still in check.sh" >&2
    return 1
  fi
  grep -q 'not safe to format' "$ROOT/lib/check.sh"
}
