#!/usr/bin/env bats
# Contract tests from BUILD_SPEC testing strategy that can run in CI.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  UNLEASH="$ROOT/unleash"
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
  load '../lib/firewall.sh'
  load '../lib/ma_detect.sh'
  load '../lib/automate.sh'
  load '../lib/doctor.sh'
  load '../lib/check.sh'
  load '../lib/status.sh'
  VERSION="2.0.0"
  SCRIPT_DIR="$ROOT"
  LIB_DIR="$ROOT/lib"
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/private/var/db/dslocal/nodes/Default"
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
  UNLEASH_GATE=0
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

@test "auto-all without passing --unattended still UNLEASH_UNATTENDED=1" {
  UNLEASH_UNATTENDED=0
  UNLEASH_CREATE_ADMIN=0
  run cmd_auto_all
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_INTENT_MISSING
}

@test "password file 1234 is E_DEFAULT_PASSWORD" {
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=1
  UNLEASH_USERNAME="alice"
  UNLEASH_PASSWORD_FILE="$TEST_DIR/pw"
  printf '1234\n' > "$UNLEASH_PASSWORD_FILE"
  run cmd_apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_DEFAULT_PASSWORD
}

@test "unattended missing volume does not read and is E_VOLUME_NOT_FOUND" {
  UNLEASH_VOLUME="/no/such/Macintosh HD - Data"
  UNLEASH_UNATTENDED=1
  run cmd_apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_VOLUME_NOT_FOUND
}

@test "unattended without sidecar/intent is E_INTENT_MISSING" {
  UNLEASH_UNATTENDED=1
  run cmd_apply
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_INTENT_MISSING
}

@test "resolver RO exit 2 no BEGIN" {
  resolve_data_volume() {
    result_fail E_VOLUME_RO detect remount "Data volume is read-only after mount -uw"
    return 1
  }
  _write_intent
  UNLEASH_UNATTENDED=1
  run pipeline_run
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_VOLUME_RO
  if [ -f "$TEST_DIR/Library/Unleash/state/journal" ]; then
    ! grep -q 'op=BEGIN' "$TEST_DIR/Library/Unleash/state/journal"
  fi
}

@test "apply dry-run creates zero files" {
  _write_intent
  UNLEASH_UNATTENDED=1
  UNLEASH_DRY_RUN=1
  DRY_RUN=true
  before=$(find "$TEST_DIR" | sort)
  run cmd_apply
  after=$(find "$TEST_DIR" | sort)
  [ "$status" -eq 0 ]
  [ "$before" = "$after" ]
}

@test "--json spacey volume plus quoted next loads with python" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  base=$(mktemp -d)
  vol="$base/Macintosh HD - Data"
  mkdir -p "$vol/private/var/db/dslocal/nodes/Default"
  UNLEASH_VOLUME="$vol"
  UNLEASH_UNATTENDED=1
  UNLEASH_JSON=1
  run cmd_apply
  rm -rf "$base"
  [ "$status" -eq 2 ]
  json_line=$(printf '%s\n' "$output" | grep '^{' | tail -1)
  printf '%s\n' "$json_line" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
assert obj["volume"].endswith("Macintosh HD - Data") or "Macintosh HD - Data" in obj["volume"]
assert obj["exit"] == 2
assert "next" in obj
'
  RESULT_STATUS=skip
  RESULT_REASON=S_SIP_LIVE
  RESULT_MSG="DEP remains"
  json=$(emit_json 3 'Boot Recovery and run: "unleash recovery"' "/Volumes/Macintosh HD - Data")
  printf '%s\n' "$json" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
assert obj["volume"] == "/Volumes/Macintosh HD - Data"
assert "\"unleash recovery\"" in obj["next"]
assert obj["exit"] == 3
'
}

@test "HTTP 000 is not reachable" {
  run http_code_reachable 000
  [ "$status" -ne 0 ]
  run http_code_reachable 200
  [ "$status" -eq 0 ]
  if grep -n '000' "$ROOT/lib/check.sh" | grep -q 'reachable'; then
    # 000 may appear in a comment or the helper; it must not be OR-ed with 200 as reachable.
    if grep -E '000.*=.*"200"|"200".*=.*000' "$ROOT/lib/check.sh"; then
      echo "curl-000 still treated as reachable" >&2
      return 1
    fi
  fi
}

@test "no pkill in status audit report source" {
  if grep -nE '(^|[[:space:]])pkill([[:space:]]|$)' "$ROOT/lib/status.sh"; then
    echo "status.sh must not pkill" >&2
    return 1
  fi
  if grep -nE '(^|[[:space:]])pkill([[:space:]]|$)' "$ROOT/lib/report.sh"; then
    echo "report.sh must not pkill" >&2
    return 1
  fi
  if grep -A 20 '^cmd_audit()' "$ROOT/unleash" | grep -q pkill; then
    echo "cmd_audit must not pkill" >&2
    return 1
  fi
  grep -A 15 '^cmd_audit()' "$ROOT/unleash" | grep -q cmd_status
}

@test "./unleash apply --unattended --json --volume spacey is JSON" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
  base=$(mktemp -d)
  vol="$base/Macintosh HD - Data"
  mkdir -p "$vol/private/var/db/dslocal/nodes/Default"
  run "$UNLEASH" apply --unattended --json --volume "$vol"
  rc=$status
  rm -rf "$base"
  [ "$rc" -eq 2 ]
  json_line=$(printf '%s\n' "$output" | grep '^{' | tail -1)
  printf '%s\n' "$json_line" | python3 -c '
import json, sys
obj = json.loads(sys.stdin.read())
assert "Macintosh HD - Data" in obj["volume"]
assert obj["exit"] == 2
'
}

@test "./unleash status --json dirty fixture is exit 3" {
  run "$UNLEASH" status --json --volume "$TEST_DIR"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q '{'
  echo "$output" | grep -q 'probes'
  ! echo "$output" | grep -q 'unhandled error'
}

@test "./unleash status with RecordFound and no org does not trap" {
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  cat > "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>
EOF
  run "$UNLEASH" status --volume "$TEST_DIR"
  ! echo "$output" | grep -q 'unhandled error'
  [ "$status" -eq 3 ] || [ "$status" -eq 0 ]
}

@test "./unleash status --json planted fixture is exit 0" {
  load '../lib/suppress.sh'
  suppress_enrollment "$TEST_DIR"
  persist_copy "$TEST_DIR"
  mkdir -p "$TEST_DIR/private/etc/pf.anchors/com.unleash"
  printf 'block drop from any to 17.0.0.0/8\n' > "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  run "$UNLEASH" status --json --volume "$TEST_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'probes'
}

@test "./unleash auto-all --volume fixture without intent is E_INTENT_MISSING" {
  run "$UNLEASH" auto-all --volume "$TEST_DIR"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_INTENT_MISSING
}

@test "doctor --gate missing libs is exit 2 E_PREFLIGHT_TOOLS" {
  LIB_DIR="/nonexistent-unleash-libs"
  SCRIPT_DIR="/nonexistent-unleash-libs"
  UNLEASH_UNATTENDED=0
  UNLEASH_VOLUME="$TEST_DIR"
  run run_doctor --gate
  [ "$status" -eq 2 ]
  echo "$output" | grep -q E_PREFLIGHT_TOOLS
}

@test "./unleash doctor --gate process exit is 0 or 2 never 1" {
  run "$UNLEASH" doctor --gate
  [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}
