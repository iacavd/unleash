#!/usr/bin/env bats
# Tests for dscl.sh - run with: bats tests/test_dscl.bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/dscl.sh'
  TEST_DIR=$(mktemp -d)
  mkdir -p "$TEST_DIR/private/var/db/dslocal/nodes/Default"
  DSCL_BIN=""
  UNLEASH_UNATTENDED=0
}

teardown() {
  rm -rf "$TEST_DIR"
  if [ -n "${DSCL_BIN:-}" ] && [ -d "$DSCL_BIN" ]; then
    rm -rf "$DSCL_BIN"
  fi
  unset DSCL FDESETUP
}

_install_dscl_mock() {
  local mode="$1"
  DSCL_BIN=$(mktemp -d)
  cat > "$DSCL_BIN/dscl" <<EOF
#!/bin/bash
printf '%s\n' "\$@" >> "$DSCL_BIN/dscl.args"
if [ "\$1" = "-f" ]; then
  shift 2
fi
cmd="\${2-}"
userpath="\${3-}"
attr="\${4-}"
val="\${5-}"
case "\$cmd" in
  -list)
    case "$mode" in
      fail)
        exit 1
        ;;
      taken501)
        echo "nobody 501"
        exit 0
        ;;
      full)
        i=501
        while [ "\$i" -lt 600 ]; do
          echo "u\$i \$i"
          i=\$((i + 1))
        done
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  -read)
    if [ "$mode" = "create_missing" ]; then
      exit 1
    fi
    if [ -f "$DSCL_BIN/users" ] && grep -qx "\$userpath" "$DSCL_BIN/users"; then
      if [ "\$attr" = "UniqueID" ]; then
        echo "UniqueID: \$(cat "$DSCL_BIN/uid" 2>/dev/null || echo 501)"
        exit 0
      fi
      echo "RecordName: mock"
      exit 0
    fi
    exit 1
    ;;
  -create)
    echo "\$userpath" >> "$DSCL_BIN/users"
    if [ "\$attr" = "UniqueID" ]; then
      if [ "$mode" = "create_nuid" ]; then
        exit 1
      fi
      echo "\$val" > "$DSCL_BIN/uid"
    fi
    exit 0
    ;;
  -passwd)
    cat > "$DSCL_BIN/passwd.stdin" || true
    exit 0
    ;;
  -append|-delete)
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$DSCL_BIN/dscl"
  export DSCL="$DSCL_BIN/dscl"
}

_install_fde_mock() {
  local rc="${1:-1}"
  [ -n "$DSCL_BIN" ] || DSCL_BIN=$(mktemp -d)
  cat > "$DSCL_BIN/fdesetup" <<EOF
#!/bin/bash
printf '%s\n' "\$@" > "$DSCL_BIN/fde.args"
cat > "$DSCL_BIN/fde.stdin" || true
exit $rc
EOF
  chmod +x "$DSCL_BIN/fdesetup"
  export FDESETUP="$DSCL_BIN/fdesetup"
}

@test "dscl_node returns correct path" {
  run dscl_node "$TEST_DIR"
  [ "$output" = "$TEST_DIR/private/var/db/dslocal/nodes/Default" ]
}

@test "find_available_uid returns 501 for empty node" {
  _install_dscl_mock free
  local node
  node=$(dscl_node "$TEST_DIR")
  err=$(mktemp)
  uid=$(find_available_uid "$node" 2>"$err")
  [ "$uid" = "501" ]
  rm -f "$err"
}

@test "find_available_uid does not emit 501 as fallback when 501 is taken" {
  _install_dscl_mock taken501
  local node
  node=$(dscl_node "$TEST_DIR")
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  find_available_uid "$node" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(cat "$out")" = "502" ]
  if grep -qx 501 "$out"; then
    rm -f "$err" "$out"
    false
  fi
  rm -f "$err" "$out"
}

@test "find_available_uid fails closed when 501-599 are taken" {
  _install_dscl_mock full
  local node
  node=$(dscl_node "$TEST_DIR")
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  find_available_uid "$node" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_DSCL_FAIL" ]
  if grep -q 501 "$out"; then
    rm -f "$err" "$out"
    false
  fi
  rm -f "$err" "$out"
}

@test "find_available_uid fails closed when dscl list exits 1" {
  _install_dscl_mock fail
  local node
  node=$(dscl_node "$TEST_DIR")
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  find_available_uid "$node" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_DSCL_FAIL" ]
  if grep -q 501 "$out"; then
    rm -f "$err" "$out"
    false
  fi
  rm -f "$err" "$out"
}

@test "create_admin_user fails E_DSCL_FAIL if user missing after create" {
  _install_dscl_mock create_missing
  node=$(dscl_node "$TEST_DIR")
  rc=0
  create_admin_user "$node" "$TEST_DIR" "alice" "Alice" "goodpass" "502" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_DSCL_FAIL" ]
}

@test "create_admin_user fails E_DSCL_FAIL if UniqueID create fails" {
  _install_dscl_mock create_nuid
  node=$(dscl_node "$TEST_DIR")
  rc=0
  create_admin_user "$node" "$TEST_DIR" "alice" "Alice" "goodpass" "502" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_DSCL_FAIL" ]
}

@test "create_admin_user journals user_created after -create even if later attrs fail" {
  load '../lib/detect.sh'
  load '../lib/backup.sh'
  load '../lib/pipeline.sh'
  DATA_ROOT="$TEST_DIR"
  journal_begin apply "$TEST_DIR"
  _install_dscl_mock create_nuid
  node=$(dscl_node "$TEST_DIR")
  rc=0
  create_admin_user "$node" "$TEST_DIR" "alice" "Alice" "goodpass" "502" || rc=$?
  [ "$rc" -eq 1 ]
  grep -q 'user_created=alice' "$TEST_DIR/Library/Unleash/state/journal"
}

@test "create_admin_user verifies user exists after create" {
  _install_dscl_mock create_ok
  node=$(dscl_node "$TEST_DIR")
  rc=0
  create_admin_user "$node" "$TEST_DIR" "alice" "Alice" "goodpass" "502" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$RESULT_STATUS" = "ok" ]
  [ -d "$TEST_DIR/Users/alice" ]
}

@test "create_admin_user does not put password on dscl argv" {
  _install_dscl_mock create_ok
  node=$(dscl_node "$TEST_DIR")
  create_admin_user "$node" "$TEST_DIR" "alice" "Alice" "s3cret-pass" "502"
  [ "$RESULT_STATUS" = "ok" ]
  if grep -q "s3cret-pass" "$DSCL_BIN/dscl.args"; then
    false
  fi
  grep -q "s3cret-pass" "$DSCL_BIN/passwd.stdin"
}

@test "add_to_filevault unattended skips with S_FV_ADD immediately" {
  UNLEASH_UNATTENDED=1
  _install_fde_mock 0
  add_to_filevault "alice" "s3cret-pass"
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_FV_ADD" ]
  [ ! -f "$DSCL_BIN/fde.args" ]
}

@test "add_to_filevault unattended without password skips and does not claim success" {
  UNLEASH_UNATTENDED=1
  _install_fde_mock 0
  add_to_filevault "alice"
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_FV_ADD" ]
  [ ! -f "$DSCL_BIN/fde.args" ]
}
