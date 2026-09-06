#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/config.sh'
  load '../lib/detect.sh'
  load '../lib/validate.sh'
  load '../lib/dscl.sh'
  load '../lib/suppress.sh'
  load '../lib/backup.sh'
  load '../lib/pipeline.sh'
  load '../lib/heal.sh'
  load '../lib/whitelist.sh'
  load '../lib/firewall.sh'
  load '../lib/ma_detect.sh'
  load '../lib/automate.sh'

  VERSION="2.0.0"
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ROOT="$SCRIPT_DIR"
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/private/var/db/dslocal/nodes/Default"
  mkdir -p "$TEST_DIR/Users/testuser/Library/Preferences"
  mkdir -p "$TEST_DIR/Users/testuser/Library/Application Support"
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  DRY_RUN=false
  UNLEASH_DRY_RUN=0
  UNLEASH_UNATTENDED=0
  UNLEASH_CREATE_ADMIN=0
  UNLEASH_RESUME=0
  UNLEASH_PERSIST=1
  UNLEASH_INTENT_FLAG=0
  UNLEASH_USB_INTENT=0
  UNLEASH_ALLOW_WEAK=0
  UNLEASH_USERNAME=""
  UNLEASH_PASSWORD_FILE=""
  UNLEASH_VOLUME="$TEST_DIR"
  UNLEASH_FIREWALL_MODE="selective"
  UNLEASH_JSON=0
  UNLEASH_HARDEN=0
  UNLEASH_CMD="apply"
  DATA_ROOT="$TEST_DIR"
  JOURNAL_RUN=""
}

teardown() {
  pipeline_lock_release || true
  rm -rf "$TEST_DIR"
}

_write_intent() {
  mkdir -p "$TEST_DIR/Library/Unleash/state"
  printf 'owned=1\nts=2026-09-06T12:00:00Z\nvolume_uuid=\n' > "$TEST_DIR/Library/Unleash/state/intent"
}

@test "cmd_auto_all without --unattended still UNLEASH_UNATTENDED=1" {
  UNLEASH_UNATTENDED=0
  UNLEASH_CREATE_ADMIN=0
  run cmd_auto_all
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_INTENT_MISSING
  ! echo "$output" | grep -q COMPLETE
}

@test "unattended apply without sidecar/intent is exit 2 E_INTENT_MISSING" {
  UNLEASH_UNATTENDED=1
  run cmd_apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_INTENT_MISSING
  [ ! -f "$TEST_DIR/private/etc/hosts" ]
  [ ! -d "$TEST_DIR/Library/Unleash/logs" ]
}

@test "password file 1234 is E_DEFAULT_PASSWORD via cmd_apply" {
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=1
  UNLEASH_USERNAME="alice"
  UNLEASH_PASSWORD_FILE="$TEST_DIR/pw"
  printf '1234\n' > "$UNLEASH_PASSWORD_FILE"
  run cmd_apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_DEFAULT_PASSWORD
}

@test "create-admin without username is E_CREDS_REQUIRED via cmd_apply" {
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=1
  UNLEASH_USERNAME=""
  UNLEASH_PASSWORD_FILE="$TEST_DIR/pw"
  printf 's3cret!!\n' > "$UNLEASH_PASSWORD_FILE"
  run cmd_apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_CREDS_REQUIRED
}

@test "cmd_apply unattended writes hosts and does not print COMPLETE on persist skip" {
  _write_intent
  UNLEASH_UNATTENDED=1
  persist_copy "$TEST_DIR"
  run cmd_apply
  [ "$status" -eq 0 ]
  grep -q "iprofiles.apple.com" "$TEST_DIR/private/etc/hosts"
  grep -q "deviceenrollment.apple.com" "$TEST_DIR/private/etc/hosts"
  [ -f "$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist" ]
  journal="$TEST_DIR/Library/Unleash/state/journal"
  [ -f "$journal" ]
  grep -q 'name=persist' "$journal"
  grep -q 'S_ALREADY_OK' "$journal"
  ! echo "$output" | grep -q COMPLETE
}

@test "persist probe skip S_ALREADY_OK when copy already live-path" {
  _write_intent
  UNLEASH_UNATTENDED=1
  persist_copy "$TEST_DIR"
  persist_probe_ok
  run cmd_apply
  [ "$status" -eq 0 ]
  grep -q 'status=skip' "$TEST_DIR/Library/Unleash/state/journal"
  grep -q 'S_ALREADY_OK' "$TEST_DIR/Library/Unleash/state/journal"
}

@test "cmd_heal re-copies persist when binary missing" {
  if awk '/^pipeline_run_heal\(\)/,/^}/ { if ($0 ~ /UNLEASH_PERSIST=0/) found=1 } END { exit found ? 0 : 1 }' "$ROOT/lib/pipeline.sh"; then
    echo "pipeline_run_heal must not disable persist" >&2
    return 1
  fi
  if awk '/^cmd_heal\(\)/,/^}/ { if ($0 ~ /UNLEASH_PERSIST=0/) found=1 } END { exit found ? 0 : 1 }' "$ROOT/lib/pipeline.sh"; then
    echo "cmd_heal must not disable persist" >&2
    return 1
  fi
  _write_intent
  UNLEASH_UNATTENDED=1
  persist_copy "$TEST_DIR"
  [ -f "$TEST_DIR/Library/Unleash/unleash" ]
  rm -f "$TEST_DIR/Library/Unleash/unleash"
  run cmd_heal
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
  [ -f "$TEST_DIR/Library/Unleash/unleash" ]
  grep 'name=persist' "$TEST_DIR/Library/Unleash/state/journal" | grep -q 'status=ok'
}

@test "dry-run unattended sidecar does not write intent" {
  USB=$(mktemp -d)
  touch "$USB/I_OWN_THIS_DEVICE"
  SCRIPT_DIR="$USB"
  UNLEASH_UNATTENDED=1
  UNLEASH_DRY_RUN=1
  DRY_RUN=true
  run cmd_apply
  rm -rf "$USB"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/Library/Unleash/state/intent" ]
}

@test "USB sidecar I_OWN_THIS_DEVICE is consumed onto target intent" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib" "$USB/data"
  cp "$ROOT/unleash" "$USB/unleash"
  cp "$ROOT/lib/"*.sh "$USB/lib/"
  cp "$ROOT/data/"*.tsv "$USB/data/" 2>/dev/null || true
  touch "$USB/I_OWN_THIS_DEVICE"
  SCRIPT_DIR="$USB"
  UNLEASH_UNATTENDED=1
  UNLEASH_USB_INTENT=0
  run cmd_apply
  rm -rf "$USB"
  [ -f "$TEST_DIR/Library/Unleash/state/intent" ]
  grep -q 'owned=1' "$TEST_DIR/Library/Unleash/state/intent"
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

@test "dualboot no longer writes 3 hosts lines inline" {
  ! grep -A 30 '^cmd_dualboot()' "$ROOT/unleash" | grep -q '0.0.0.0 deviceenrollment.apple.com'
  grep -A 10 '^cmd_dualboot()' "$ROOT/unleash" | grep -q pipeline_run
}

@test "autorun.sh does not contain --i-own-this-device" {
  run grep -n 'i-own-this-device' "$ROOT/payloads/autorun.sh"
  [ "$status" -ne 0 ]
  grep -q 'apply --unattended' "$ROOT/payloads/autorun.sh"
}

@test "examples/auto-bypass-usb.sh calls apply --unattended" {
  grep -q 'apply --unattended' "$ROOT/examples/auto-bypass-usb.sh"
  ! grep -qE '"\$UNLEASH"[[:space:]]+bypass|[[:space:]]bypass[[:space:]]*$' "$ROOT/examples/auto-bypass-usb.sh"
}

@test "cmd_auto_all installs selective firewall via pipeline" {
  _write_intent
  UNLEASH_UNATTENDED=1
  run cmd_auto_all
  [ -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
}

@test "cmd_auto_all does not leave com.unleash.monitor after persist" {
  _write_intent
  UNLEASH_UNATTENDED=1
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  echo "old-monitor" > "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist"
  run cmd_apply
  [ -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist" ]
}
