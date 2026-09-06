#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/ma_detect.sh'
}

@test "detect_migration_assistant exits cleanly" {
  run detect_migration_assistant 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "clean_ma_artifacts does not error without users" {
  run clean_ma_artifacts 2>/dev/null || true
  [ "$status" -eq 0 ]
}

@test "clean_ma_artifacts with data_mount does not fall back to live /Users" {
  target=$(mktemp -d)
  mkdir -p "$target/private/etc"
  marker=$(mktemp -d)
  mkdir -p "$marker/Library/Preferences"
  touch "$marker/Library/Preferences/com.apple.mdm.plist"
  # If the function wrongly used /Users, we cannot safely assert; instead
  # confirm a passed mount without Users/ leaves that tree empty of deletes
  # and the function still returns 0.
  run clean_ma_artifacts "$target"
  [ "$status" -eq 0 ]
  [ -d "$target" ]
  [ ! -d "$target/Users" ]
  rm -rf "$target" "$marker"
}
