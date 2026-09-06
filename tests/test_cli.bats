#!/usr/bin/env bats
# CLI parse-in-main + apns-block tombstone. Does not require Recovery or sudo.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  UNLEASH="$ROOT/unleash"
  # Load parse_flags without sourcing libs or running main.
  eval "$(sed -n '/^# --- CLI parse/,/^# --- end CLI parse ---/p' "$UNLEASH")"
}

@test "parse_flags preserves volume path with spaces and equals firewall-mode" {
  cmd=apply
  parse_flags --volume "/Volumes/Macintosh HD - Data" --firewall-mode=broad --snapshot snap1 --allow-weak-password
  [ "$UNLEASH_VOLUME" = "/Volumes/Macintosh HD - Data" ]
  [ "$UNLEASH_FIREWALL_MODE" = "broad" ]
  [ "$UNLEASH_SNAPSHOT" = "snap1" ]
  [ "$UNLEASH_ALLOW_WEAK" = 1 ]
}

@test "parse_flags --firewall-mode space form" {
  parse_flags --firewall-mode broad
  [ "$UNLEASH_FIREWALL_MODE" = "broad" ]
}

@test "auto-all sets UNLEASH_UNATTENDED without --unattended" {
  parse_flags
  apply_command_defaults auto-all
  [ "$UNLEASH_UNATTENDED" = 1 ]
}

@test "apply does not imply unattended" {
  parse_flags
  apply_command_defaults apply
  [ "$UNLEASH_UNATTENDED" = 0 ]
}

@test "parse_flags --unattended sets flag" {
  parse_flags --unattended
  [ "$UNLEASH_UNATTENDED" = 1 ]
}

@test "unknown flag via parse_flags exits 1" {
  run parse_flags --nope
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "Unknown flag"
}

@test "./unleash version --nope exits 1" {
  run "$UNLEASH" version --nope
  [ "$status" -eq 1 ]
}

@test "./unleash heal --bogus exits 1" {
  run "$UNLEASH" heal --bogus
  [ "$status" -eq 1 ]
}

@test "./unleash auto-all --help exits 0" {
  run "$UNLEASH" auto-all --help
  [ "$status" -eq 0 ]
}

@test "./unleash version still works" {
  run "$UNLEASH" version
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "unleash v"
}

@test "./unleash apns-block exits 1 and mentions 17/8 or 443" {
  existed=0
  [ -f /etc/pf.anchors/com.unleash.apns ] && existed=1
  run "$UNLEASH" apns-block
  [ "$status" -eq 1 ]
  echo "$output" | grep -Eq '17/8|17\.0\.0\.0/8|443'
  if [ "$existed" -eq 0 ]; then
    [ ! -f /etc/pf.anchors/com.unleash.apns ]
  fi
}

@test "./unleash apns-unblock exits 1 similarly" {
  run "$UNLEASH" apns-unblock
  [ "$status" -eq 1 ]
  echo "$output" | grep -Eq '17/8|17\.0\.0\.0/8|443'
}
