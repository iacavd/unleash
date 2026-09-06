#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  load '../lib/colors.sh'
  load '../lib/detect.sh'
  load '../lib/uninstall.sh'
  PERSIST_SENTINEL=".unleash-persist-installed"
  TEST_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "do_uninstall requires root on live paths" {
  if [ "$EUID" -eq 0 ]; then
    skip "Running as root, cannot test non-root case"
  fi
  DATA_ROOT=""
  run do_uninstall
  [ "$status" -ne 0 ]
  echo "$output" | grep -q E_NOT_ROOT
}

@test "do_uninstall function exists" {
  run type do_uninstall
  [ "$status" -eq 0 ]
}

@test "uninstall label list matches suppress 10 labels" {
  run _uninstall_enrollment_labels
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

@test "uninstall hosts list includes all 14 suppress domains" {
  run _uninstall_mdm_domains
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx 'iprofiles.apple.com'
  echo "$output" | grep -qx 'deviceenrollment.apple.com'
  echo "$output" | grep -qx 'mdmenrollment.apple.com'
  echo "$output" | grep -qx 'acmdm.apple.com'
  echo "$output" | grep -qx 'axm-adm-mdm.apple.com'
  echo "$output" | grep -qx 'albert.apple.com'
  echo "$output" | grep -qx 'gdmf.apple.com'
  echo "$output" | grep -qx 'ax.init-content.apple.com'
  echo "$output" | grep -qx 'init-content.apple.com'
  echo "$output" | grep -qx 'configuration.apple.com'
  echo "$output" | grep -qx 'xp.apple.com'
  echo "$output" | grep -qx 'gs.apple.com'
  echo "$output" | grep -qx 'tb.apple.com'
  echo "$output" | grep -qx 'vpp.itunes.apple.com'
  [ "$(echo "$output" | grep -c .)" -eq 14 ]
}

@test "uninstall copy is honest (does not claim original state or DEP restored)" {
  if grep -qi 'original state' "$ROOT/lib/uninstall.sh"; then
    echo "uninstall must not claim original state" >&2
    return 1
  fi
  grep -qi 'does not restore DEP' "$ROOT/lib/uninstall.sh"
}

@test "uninstall deletes rc.unleash-update.local (D18)" {
  grep -q 'rc.unleash-update.local' "$ROOT/lib/uninstall.sh"
}

@test "fixture uninstall removes persist, pf, hosts, labels, rc hook" {
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  mkdir -p "$TEST_DIR/Library/Unleash/lib"
  mkdir -p "$TEST_DIR/private/etc/pf.anchors/com.unleash"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  printf 'plist\n' > "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist"
  printf 'sentinel\n' > "$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed"
  printf 'bin\n' > "$TEST_DIR/Library/Unleash/unleash"
  printf 'anchor\n' > "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  printf '# Added by unleash — DEP enrollment block\n0.0.0.0 iprofiles.apple.com\n::      iprofiles.apple.com\nkeep-me example.com\n' > "$TEST_DIR/private/etc/hosts"
  printf 'hook\n' > "$TEST_DIR/private/etc/rc.unleash-update.local"
  ldp="$TEST_DIR/private/var/db/com.apple.xpc.launchd/disabled.plist"
  pb="${PLISTBUDDY:-/usr/libexec/PlistBuddy}"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$ldp"
  while IFS= read -r label || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    "$pb" -c "Add :$label bool true" "$ldp"
    val=$("$pb" -c "Print :$label" "$ldp")
    case "$val" in
      true|1) ;;
      *) echo "seed failed for $label" >&2; return 1 ;;
    esac
  done <<EOF
$(_uninstall_enrollment_labels)
EOF

  run do_uninstall
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
  [ ! -d "$TEST_DIR/Library/Unleash" ]
  [ ! -f "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm" ]
  [ ! -f "$TEST_DIR/private/etc/rc.unleash-update.local" ]
  if grep -q 'iprofiles.apple.com' "$TEST_DIR/private/etc/hosts"; then
    echo "hosts MDM block still present" >&2
    return 1
  fi
  grep -q 'keep-me example.com' "$TEST_DIR/private/etc/hosts"
  echo "$output" | grep -qi 'does not restore DEP'
  ! echo "$output" | grep -qi 'original state'
  while IFS= read -r label || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    val=$("$pb" -c "Print :$label" "$ldp" 2>/dev/null || true)
    case "$val" in
      true|1)
        echo "label $label still true after uninstall" >&2
        return 1
        ;;
    esac
  done <<EOF
$(_uninstall_enrollment_labels)
EOF
}
