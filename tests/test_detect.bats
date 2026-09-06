#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/detect.sh'
}

@test "is_recovery returns false on normal boot" {
  # On a normal test machine, this should be false
  run is_recovery
  [ "$status" -ne 0 ]
}

@test "is_root checks EUID" {
  # In test context, likely not root
  if [ "$EUID" -eq 0 ]; then
    run is_root
    [ "$status" -eq 0 ]
  else
    run is_root
    [ "$status" -ne 0 ]
  fi
}

@test "detect_boot_mode returns normal on standard boot" {
  run detect_boot_mode
  [ "$output" = "normal" ]
}

@test "detect_macos_version returns a version string" {
  run detect_macos_version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+ ]]
}

@test "detect_macos_major returns a number" {
  run detect_macos_major
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
}

@test "resolve_all_volumes returns paths or fails gracefully" {
  # On a standard Mac, there should be at least one Data volume
  run resolve_all_volumes 2>/dev/null
  # It's okay if it fails (e.g., no APFS), but shouldn't crash
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}

@test "detect_system_volume handles no match" {
  run detect_system_volume "/nonexistent"
  [ "$status" -eq 0 ]
}
