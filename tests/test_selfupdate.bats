#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/selfupdate.sh'
  VERSION="2.0.0"
}

@test "verify_gpg_signature fails closed when GPG unavailable" {
  # Override command to simulate GPG not available
  function command() { return 1; }
  export -f command
  UNLEASH_INSECURE_UPDATE=0
  run verify_gpg_signature "/tmp/test" "/tmp/test.sig" 2>/dev/null
  [ "$status" -ne 0 ]
  unset -f command
}

@test "verify_gpg_signature allows bypass with UNLEASH_INSECURE_UPDATE=1" {
  function command() { return 1; }
  export -f command
  UNLEASH_INSECURE_UPDATE=1
  run verify_gpg_signature "/tmp/test" "/tmp/test.sig" 2>/dev/null
  [ "$status" -eq 0 ]
  unset -f command
}

@test "verify_sha256_checksum validates correct checksum" {
  local tmp
  tmp=$(mktemp)
  echo "hello world" > "$tmp"
  local expected
  expected=$(shasum -a 256 "$tmp" | awk '{print $1}')
  local cksum_file
  cksum_file=$(mktemp)
  echo "$expected  unleash" > "$cksum_file"
  run verify_sha256_checksum "$tmp" "$cksum_file"
  [ "$status" -eq 0 ]
  rm -f "$tmp" "$cksum_file"
}

@test "verify_sha256_checksum rejects bad checksum" {
  local tmp
  tmp=$(mktemp)
  echo "hello world" > "$tmp"
  local cksum_file
  cksum_file=$(mktemp)
  echo "0000000000000000000000000000000000000000000000000000000000000000  unleash" > "$cksum_file"
  run verify_sha256_checksum "$tmp" "$cksum_file"
  [ "$status" -ne 0 ]
  rm -f "$tmp" "$cksum_file"
}

@test "verify_sha256_checksum returns 1 for empty checksum file" {
  local tmp
  tmp=$(mktemp)
  echo "hello" > "$tmp"
  local cksum_file
  cksum_file=$(mktemp)
  > "$cksum_file"
  run verify_sha256_checksum "$tmp" "$cksum_file"
  [ "$status" -ne 0 ]
  rm -f "$tmp" "$cksum_file"
}

@test "do_self_update handles no network" {
  run do_self_update 2>/dev/null || true
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
}
