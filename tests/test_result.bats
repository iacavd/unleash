#!/usr/bin/env bats
# Tests for result.sh - run with: bats tests/test_result.bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
}

@test "result_skip under set -e does not abort caller" {
  set -euo pipefail
  result_skip S_SIP_LIVE dep_wipe sip "DEP wipe skipped under SIP"
  continued=$(echo after-skip)
  [ "$continued" = "after-skip" ]
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_SIP_LIVE" ]
}

@test "result_fail under set -e does not abort caller" {
  set -euo pipefail
  result_fail E_DSCL_FAIL dscl create "user create failed"
  continued=$(echo after-fail)
  [ "$continued" = "after-fail" ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_DSCL_FAIL" ]
}

@test "result_ok sets RESULT_STATUS=ok and empty reason" {
  set -euo pipefail
  result_ok persist copy "copied binary"
  [ "$RESULT_STATUS" = "ok" ]
  [ -z "$RESULT_REASON" ]
}

@test "json_escape preserves spaces in volume path" {
  got=$(json_escape "/Volumes/Macintosh HD - Data")
  [ "$got" = "/Volumes/Macintosh HD - Data" ]
  case "$got" in
    *'"'*) false ;;
  esac
}

@test "json_escape of quote backslash and newline" {
  input='foo"bar\baz'
  input="${input}"$'\n'"qux"
  got=$(json_escape "$input")
  expected='foo\"bar\\baz\nqux'
  [ "$got" = "$expected" ]
}

@test "emit_json is valid JSON with spacey volume and quoted next" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not available"
  fi
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
assert obj["ok"] is False
'
}

@test "result_ok writes nothing to stdout" {
  stdout_only=$(result_ok a b c 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "result_skip writes nothing to stdout" {
  stdout_only=$(result_skip S_SIP_LIVE a b c 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "result_fail writes nothing to stdout" {
  stdout_only=$(result_fail E_DSCL_FAIL a b c 2>/dev/null)
  [ -z "$stdout_only" ]
}

@test "json_escape writes escaped string to stdout" {
  got=$(json_escape 'say "hi"' 2>/dev/null)
  [ "$got" = 'say \"hi\"' ]
}
