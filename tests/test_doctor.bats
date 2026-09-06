#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/doctor.sh'
}

@test "run_doctor exits cleanly" {
  run run_doctor 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "run_doctor detects missing libs" {
  local old_dir="$LIB_DIR"
  LIB_DIR="/nonexistent"
  run run_doctor 2>/dev/null || true
  LIB_DIR="$old_dir"
  echo "$output" | grep -qi "missing\|error"
}

@test "run_doctor --gate missing libs is E_PREFLIGHT_TOOLS" {
  load '../lib/result.sh'
  LIB_DIR="/nonexistent-unleash-libs"
  SCRIPT_DIR="/nonexistent-unleash-libs"
  UNLEASH_VOLUME=$(mktemp -d)
  mkdir -p "$UNLEASH_VOLUME/private/var/db/dslocal/nodes/Default"
  run run_doctor --gate
  rm -rf "$UNLEASH_VOLUME"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q E_PREFLIGHT_TOOLS
}

@test "run_doctor --gate does not fail closed on Little Snitch" {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  if grep -E 'result_fail|end_fail' "$ROOT/lib/doctor.sh" | grep -qi 'Little Snitch'; then
    echo "Little Snitch must be informational" >&2
    return 1
  fi
}
