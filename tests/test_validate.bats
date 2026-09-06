#!/usr/bin/env bats
# Tests for validate.sh - run with: bats tests/test_validate.bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/validate.sh'
  UNLEASH_ALLOW_WEAK=0
  UNLEASH_USERNAME=""
  UNLEASH_PASSWORD_FILE=""
  UNLEASH_UNATTENDED=0
  UNLEASH_CREATE_ADMIN=0
  VALIDATE_TMP=""
}

teardown() {
  if [ -n "${VALIDATE_TMP:-}" ] && [ -d "$VALIDATE_TMP" ]; then
    rm -rf "$VALIDATE_TMP"
  fi
}

@test "validate_username accepts valid usernames" {
  run validate_username "apple"
  [ "$status" -eq 0 ]
  run validate_username "test-user"
  [ "$status" -eq 0 ]
  run validate_username "test_user"
  [ "$status" -eq 0 ]
}

@test "validate_username rejects empty" {
  run validate_username ""
  [ "$status" -eq 1 ]
}

@test "validate_username rejects long names" {
  local long="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  run validate_username "$long"
  [ "$status" -eq 1 ]
}

@test "validate_username rejects special chars" {
  run validate_username "user name"
  [ "$status" -eq 1 ]
  run validate_username "user.name"
  [ "$status" -eq 1 ]
}

@test "validate_password accepts valid passwords of min 8" {
  run validate_password "password"
  [ "$status" -eq 0 ]
  run validate_password "correct horse battery staple"
  [ "$status" -eq 0 ]
}

@test "validate_password rejects empty" {
  run validate_password ""
  [ "$status" -eq 1 ]
}

@test "validate_password rejects short" {
  run validate_password "ab"
  [ "$status" -eq 1 ]
  run validate_password "1234567"
  [ "$status" -eq 1 ]
}

@test "validate_password rejects 1234 unless allow-weak" {
  UNLEASH_ALLOW_WEAK=0
  run validate_password "1234"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "1234"
}

@test "validate_password accepts 1234 when UNLEASH_ALLOW_WEAK=1 and warns" {
  UNLEASH_ALLOW_WEAK=1
  run validate_password "1234"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "weak"
}

@test "password_from_file reads and trims newline" {
  VALIDATE_TMP=$(mktemp -d)
  printf 's3cret!!\n' > "$VALIDATE_TMP/pw"
  got=$(password_from_file "$VALIDATE_TMP/pw")
  [ "$got" = "s3cret!!" ]
}

@test "password_from_file rejects empty file" {
  VALIDATE_TMP=$(mktemp -d)
  : > "$VALIDATE_TMP/pw"
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  password_from_file "$VALIDATE_TMP/pw" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_REASON" = "E_CREDS_REQUIRED" ]
  rm -f "$err" "$out"
}

@test "password_from_file rejects missing file" {
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  password_from_file "/no/such/password.file" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_REASON" = "E_CREDS_REQUIRED" ]
  rm -f "$err" "$out"
}

@test "password_from_file of 1234 is E_DEFAULT_PASSWORD" {
  VALIDATE_TMP=$(mktemp -d)
  printf '1234\n' > "$VALIDATE_TMP/pw"
  UNLEASH_ALLOW_WEAK=0
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  password_from_file "$VALIDATE_TMP/pw" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_DEFAULT_PASSWORD" ]
  rm -f "$err" "$out"
}

@test "password_from_file of 1234 with allow-weak still warns" {
  VALIDATE_TMP=$(mktemp -d)
  printf '1234\n' > "$VALIDATE_TMP/pw"
  UNLEASH_ALLOW_WEAK=1
  err=$(mktemp)
  got=$(password_from_file "$VALIDATE_TMP/pw" 2>"$err")
  [ "$got" = "1234" ]
  grep -qi "weak" "$err"
  rm -f "$err"
}

@test "password_from_file rejects short non-default password" {
  VALIDATE_TMP=$(mktemp -d)
  printf 'abcdefg\n' > "$VALIDATE_TMP/pw"
  err=$(mktemp)
  out=$(mktemp)
  rc=0
  password_from_file "$VALIDATE_TMP/pw" >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  [ ! -s "$out" ]
  rm -f "$err" "$out"
}

@test "prompt_password empty input does not become 1234" {
  err=$(mktemp)
  prompt_password got 2>"$err" <<'EOF'

goodpass
EOF
  [ "$got" = "goodpass" ]
  grep -q "cannot be empty" "$err"
  rm -f "$err"
}

@test "prompt_username empty input does not become Apple" {
  prompt_username got <<'EOF'

alice
EOF
  [ "$got" = "alice" ]
}

@test "unattended create-admin missing --username is E_CREDS_REQUIRED" {
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=1
  UNLEASH_USERNAME=""
  UNLEASH_PASSWORD_FILE="/tmp/pw"
  rc=0
  require_create_admin_creds || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_CREDS_REQUIRED" ]
}

@test "unattended create-admin missing --password-file is E_CREDS_REQUIRED" {
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=1
  UNLEASH_USERNAME="alice"
  UNLEASH_PASSWORD_FILE=""
  rc=0
  require_create_admin_creds || rc=$?
  [ "$rc" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_CREDS_REQUIRED" ]
}

@test "unattended create-admin with username and password-file is ok" {
  UNLEASH_UNATTENDED=1
  UNLEASH_CREATE_ADMIN=1
  UNLEASH_USERNAME="alice"
  UNLEASH_PASSWORD_FILE="/tmp/pw"
  rc=0
  require_create_admin_creds || rc=$?
  [ "$rc" -eq 0 ]
}
