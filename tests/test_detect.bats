#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  DETECT_FAKE_ROOT=""
  DETECT_BIN=""
  DETECT_MOUNT=""
  DETECT_ORIG_PATH="$PATH"
}

teardown() {
  if [ -n "${DETECT_FAKE_ROOT:-}" ] && [ -d "$DETECT_FAKE_ROOT" ]; then
    chmod -R u+w "$DETECT_FAKE_ROOT" 2>/dev/null || true
    rm -rf "$DETECT_FAKE_ROOT"
  fi
  unset DISKUTIL PLISTBUDDY MOUNT
  if [ -n "${DETECT_ORIG_PATH:-}" ]; then
    export PATH="$DETECT_ORIG_PATH"
  fi
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

@test "unleash_root is /Library/Unleash when DATA_ROOT is empty" {
  DATA_ROOT=""
  [ "$(unleash_root)" = "/Library/Unleash" ]
}

@test "unleash_root prefixes DATA_ROOT in Recovery" {
  DATA_ROOT="/Volumes/Macintosh HD - Data"
  [ "$(unleash_root)" = "/Volumes/Macintosh HD - Data/Library/Unleash" ]
}

# PATH wrappers for diskutil / PlistBuddy / mount. Logs are asserted on stderr, never 2>/dev/null.
_install_detect_mocks() {
  local mode="${1:-ok}"
  DETECT_FAKE_ROOT=$(mktemp -d)
  DETECT_BIN="$DETECT_FAKE_ROOT/bin"
  DETECT_MOUNT="$DETECT_FAKE_ROOT/mnt"
  mkdir -p "$DETECT_BIN"
  mkdir -p "$DETECT_MOUNT/private/var/db/dslocal/nodes/Default"

  cat > "$DETECT_BIN/apfs.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Containers</key>
	<array>
		<dict>
			<key>Volumes</key>
			<array>
				<dict>
					<key>DeviceIdentifier</key>
					<string>disk3s5</string>
					<key>Name</key>
					<string>Macintosh HD - Data</string>
					<key>MountPoint</key>
					<string>${DETECT_MOUNT}</string>
					<key>Locked</key>
					<false/>
					<key>Roles</key>
					<array>
						<string>Data</string>
					</array>
				</dict>
			</array>
		</dict>
	</array>
</dict>
</plist>
PLIST

  if [ "$mode" = "none" ]; then
    cat > "$DETECT_BIN/apfs.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Containers</key>
	<array></array>
</dict>
</plist>
PLIST
  fi

  cat > "$DETECT_BIN/diskutil" <<EOF
#!/bin/bash
FAKE_MOUNT="$DETECT_MOUNT"
PLIST="$DETECT_BIN/apfs.plist"
MODE="$mode"
UNLOCKED="$DETECT_BIN/unlocked"
UNLOCK_ARGS="$DETECT_BIN/unlock.args"
UNLOCK_STDIN="$DETECT_BIN/unlock.stdin"
if [ "\$1" = "apfs" ] && [ "\$2" = "list" ] && [ "\$3" = "-plist" ]; then
  cat "\$PLIST"
  exit 0
fi
if [ "\$1" = "apfs" ] && [ "\$2" = "list" ]; then
  if [ "\$MODE" = "none" ]; then
    echo "No Data role volumes"
    exit 0
  fi
  echo "    APFS Volume Disk (Role):   disk3s5 (Data)"
  echo "    Name:                      Macintosh HD - Data"
  echo "    Mount Point:               \$FAKE_MOUNT"
  exit 0
fi
if [ "\$1" = "list" ]; then
  echo "fake diskutil list"
  echo "/dev/disk0"
  exit 0
fi
if [ "\$1" = "info" ]; then
  disk="\${2#/dev/}"
  if [ "\$disk" = "disk3s5" ] || [ "\$disk" = "\$FAKE_MOUNT" ]; then
    echo "   Device Identifier:         disk3s5"
    echo "   Volume Name:               Macintosh HD - Data"
    if { [ "\$MODE" = "locked" ] || [ "\$MODE" = "unlockfail" ]; } && [ ! -f "\$UNLOCKED" ]; then
      echo "   Mounted:                   No"
      echo "   FileVault:                 Yes"
      echo "   Locked:                    Yes"
    else
      echo "   Mounted:                   Yes"
      echo "   Mount Point:               \$FAKE_MOUNT"
      echo "   FileVault:                 No"
      echo "   Locked:                    No"
    fi
    exit 0
  fi
  exit 1
fi
if [ "\$1" = "mount" ]; then
  if { [ "\$MODE" = "locked" ] || [ "\$MODE" = "unlockfail" ]; } && [ ! -f "\$UNLOCKED" ]; then
    exit 1
  fi
  exit 0
fi
if [ "\$1" = "apfs" ] && [ "\$2" = "unlockVolume" ]; then
  printf '%s\n' "\$@" > "\$UNLOCK_ARGS"
  cat > "\$UNLOCK_STDIN" || true
  if [ "\$MODE" = "unlockfail" ]; then
    exit 1
  fi
  echo "Unlocked Volume disk3s5"
  touch "\$UNLOCKED"
  exit 0
fi
exit 1
EOF
  chmod +x "$DETECT_BIN/diskutil"

  if [ -x /usr/libexec/PlistBuddy ]; then
    cat > "$DETECT_BIN/PlistBuddy" <<'EOF'
#!/bin/bash
exec /usr/libexec/PlistBuddy "$@"
EOF
  else
    cat > "$DETECT_BIN/PlistBuddy" <<'EOF'
#!/bin/bash
exit 1
EOF
  fi
  chmod +x "$DETECT_BIN/PlistBuddy"

  cat > "$DETECT_BIN/mount" <<EOF
#!/bin/bash
echo "\$@" >> "$DETECT_BIN/mount.args"
exit 0
EOF
  chmod +x "$DETECT_BIN/mount"

  export PATH="$DETECT_BIN:$PATH"
  export DISKUTIL="$DETECT_BIN/diskutil"
  export PLISTBUDDY="$DETECT_BIN/PlistBuddy"
  export MOUNT="$DETECT_BIN/mount"
  UNLEASH_VOLUME=""
  UNLEASH_FV_PASSWORD_FILE=""
  UNLEASH_FV_KEY_FILE=""
}

@test "resolve_data_volume stdout is only the mount path" {
  _install_detect_mocks ok
  UNLEASH_UNATTENDED=1
  err=$(mktemp)
  path=$(resolve_data_volume 2>"$err")
  [ "$path" = "$DETECT_MOUNT" ]
  case "$path" in
    *$'\n'*) rm -f "$err"; false ;;
    *$'\033'*) rm -f "$err"; false ;;
    *"Locating Data volume"*) rm -f "$err"; false ;;
  esac
  grep -qE 'level=|event=' "$err"
  if grep -q $'\033' <<<"$path"; then
    rm -f "$err"
    false
  fi
  rm -f "$err"
}

@test "unattended with no volume does not read and fails closed" {
  _install_detect_mocks none
  UNLEASH_UNATTENDED=1
  UNLEASH_VOLUME=""
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  resolve_data_volume >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_REASON" = "E_VOLUME_NOT_FOUND" ]
  grep -qE 'level=|event=' "$err"
  if grep -q "Enter Data volume" "$err"; then
    rm -f "$err" "$out"
    false
  fi
  rm -f "$err" "$out"
}

@test "read-only Data after mount -uw is E_VOLUME_RO" {
  _install_detect_mocks ok
  UNLEASH_UNATTENDED=1
  chmod a-w "$DETECT_MOUNT"
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  resolve_data_volume >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_REASON" = "E_VOLUME_RO" ]
  grep -qE 'level=|event=' "$err"
  rm -f "$err" "$out"
}

@test "unattended locked volume with no secret is E_FV_LOCKED" {
  _install_detect_mocks locked
  UNLEASH_UNATTENDED=1
  UNLEASH_VOLUME=""
  UNLEASH_FV_PASSWORD_FILE=""
  UNLEASH_FV_KEY_FILE=""
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  resolve_data_volume >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_REASON" = "E_FV_LOCKED" ]
  grep -qE 'level=|event=' "$err"
  if grep -q "Enter Data volume" "$err"; then
    rm -f "$err" "$out"
    false
  fi
  [ ! -f "$DETECT_BIN/unlock.args" ]
  rm -f "$err" "$out"
}

@test "password-file unlock uses -stdinpassphrase and stdout is only the mount" {
  _install_detect_mocks locked
  UNLEASH_UNATTENDED=1
  pw=$(mktemp)
  printf 'test-fv-secret\n' > "$pw"
  UNLEASH_FV_PASSWORD_FILE="$pw"
  err=$(mktemp)
  path=$(resolve_data_volume 2>"$err")
  [ "$path" = "$DETECT_MOUNT" ]
  case "$path" in
    *$'\n'*) rm -f "$err" "$pw"; false ;;
    *Unlocked*) rm -f "$err" "$pw"; false ;;
    *"Locating Data volume"*) rm -f "$err" "$pw"; false ;;
  esac
  grep -qx -- '-stdinpassphrase' "$DETECT_BIN/unlock.args"
  if grep -qx -- '-passphrase' "$DETECT_BIN/unlock.args"; then
    rm -f "$err" "$pw"
    false
  fi
  if grep -qx -- '-recoverykeyfile' "$DETECT_BIN/unlock.args"; then
    rm -f "$err" "$pw"
    false
  fi
  if grep -q 'test-fv-secret' "$DETECT_BIN/unlock.args"; then
    rm -f "$err" "$pw"
    false
  fi
  grep -q 'test-fv-secret' "$DETECT_BIN/unlock.stdin"
  rm -f "$err" "$pw"
}

@test "recovery-key-file unlock uses -stdinpassphrase and never puts key on argv" {
  _install_detect_mocks locked
  UNLEASH_UNATTENDED=1
  key=$(mktemp)
  printf 'test-fv-key\n' > "$key"
  UNLEASH_FV_KEY_FILE="$key"
  err=$(mktemp)
  path=$(resolve_data_volume 2>"$err")
  [ "$path" = "$DETECT_MOUNT" ]
  grep -qx -- '-stdinpassphrase' "$DETECT_BIN/unlock.args"
  if grep -qx -- '-passphrase' "$DETECT_BIN/unlock.args"; then
    rm -f "$err" "$key"
    false
  fi
  if grep -qx -- '-recoverykeyfile' "$DETECT_BIN/unlock.args"; then
    rm -f "$err" "$key"
    false
  fi
  if grep -q 'test-fv-key' "$DETECT_BIN/unlock.args"; then
    rm -f "$err" "$key"
    false
  fi
  grep -q 'test-fv-key' "$DETECT_BIN/unlock.stdin"
  rm -f "$err" "$key"
}

@test "failed unlock is E_FV_UNLOCK_FAILED with empty stdout" {
  _install_detect_mocks unlockfail
  UNLEASH_UNATTENDED=1
  pw=$(mktemp)
  printf 'test-fv-secret\n' > "$pw"
  UNLEASH_FV_PASSWORD_FILE="$pw"
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  resolve_data_volume >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_REASON" = "E_FV_UNLOCK_FAILED" ]
  rm -f "$err" "$out" "$pw"
}
