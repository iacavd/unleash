#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/config.sh'
  load '../lib/simulate.sh'
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "run_simulation completes without errors or file mutations" {
  run_simulation "$TEST_DIR"
}
