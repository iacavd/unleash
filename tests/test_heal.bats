#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/result.sh'
  load '../lib/detect.sh'
  load '../lib/suppress.sh'
  load '../lib/heal.sh'
  VERSION="2.0.0"
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  TEST_DIR=$(mktemp -d)
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/private/etc"
  mkdir -p "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings"
  mkdir -p "$TEST_DIR/private/var/db/com.apple.xpc.launchd"
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  DRY_RUN=false
}

teardown() {
  chmod -R u+w "$TEST_DIR" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}

@test "heal_suppress detects clean state" {
  suppress_enrollment "$TEST_DIR" 2>/dev/null || true
  run heal_suppress "$TEST_DIR" 2>/dev/null
  [[ "$output" == *"intact"* ]] || [[ "$output" == *"no action"* ]]
}

@test "heal_suppress detects dirty state" {
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound"
  touch "$TEST_DIR/private/etc/hosts"
  run heal_suppress "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordFound" ]
}

@test "heal_suppress fixes missing hosts block" {
  echo "" > "$TEST_DIR/private/etc/hosts"
  run heal_suppress "$TEST_DIR" 2>/dev/null || true
  run grep -c "iprofiles.apple.com" "$TEST_DIR/private/etc/hosts"
  [ "$output" -gt 0 ]
}

@test "install_persist_launchdaemon creates plist" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
}

@test "install_persist_launchdaemon creates sentinel file" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ -f "$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed" ]
}

@test "is_persist_installed returns true after install" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  run is_persist_installed "$TEST_DIR"
  [ "$status" -eq 0 ]
}

@test "remove_persist_launchdaemon removes plist and sentinel" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  remove_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist" ]
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed" ]
}

@test "is_persist_installed returns false after removal" {
  install_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  remove_persist_launchdaemon "$TEST_DIR" 2>/dev/null || true
  run is_persist_installed "$TEST_DIR"
  [ "$status" -ne 0 ]
}

@test "persist plist ProgramArguments is live /Library/Unleash/unleash not USB" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib" "$USB/data" "$USB/state"
  printf '%s\n' '#!/bin/bash' 'echo usb' > "$USB/unleash"
  printf '%s\n' '# lib' > "$USB/lib/heal.sh"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  install_persist_launchdaemon "$TEST_DIR"
  plist="$TEST_DIR/Library/LaunchDaemons/com.unleash.heal.plist"
  [ -f "$plist" ]
  grep -F '<string>/Library/Unleash/unleash</string>' "$plist"
  grep -F '<string>heal</string>' "$plist"
  grep -F '<string>--unattended</string>' "$plist"
  grep -F '<string>--log-file</string>' "$plist"
  grep -F '<string>/Library/Unleash/logs/heal.log</string>' "$plist"
  grep -F '<integer>300</integer>' "$plist"
  if grep -q '/bin/bash' "$plist"; then
    echo "plist must not use /bin/bash -c" >&2
    return 1
  fi
  if grep -F "$USB" "$plist"; then
    echo "plist must not embed USB path" >&2
    return 1
  fi
  if grep -q 'i-own-this-device' "$plist"; then
    echo "heal daemon must not take --i-own-this-device" >&2
    return 1
  fi
  [ -f "$TEST_DIR/Library/Unleash/unleash" ]
  rm -rf "$USB"
}

@test "persist copy does not copy USB state/intent into dest state" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib" "$USB/data" "$USB/state"
  printf '%s\n' '#!/bin/bash' > "$USB/unleash"
  printf '%s\n' '# lib' > "$USB/lib/heal.sh"
  printf '%s\n' 'secret-intent' > "$USB/state/intent"
  printf '%s\n' 'usb-journal' > "$USB/state/journal"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  install_persist_launchdaemon "$TEST_DIR"
  [ -f "$TEST_DIR/Library/Unleash/unleash" ]
  [ -f "$TEST_DIR/Library/Unleash/lib/heal.sh" ]
  [ ! -f "$TEST_DIR/Library/Unleash/state/intent" ]
  [ ! -f "$TEST_DIR/Library/Unleash/state/journal" ]
  rm -rf "$USB"
}

@test "persist sentinel has sha256 from shasum" {
  install_persist_launchdaemon "$TEST_DIR"
  sentinel="$TEST_DIR/Library/LaunchDaemons/.unleash-persist-installed"
  grep -q '^installed=' "$sentinel"
  grep -q '^sha256=' "$sentinel"
  sha=$(awk -F= '/^sha256=/{print $2}' "$sentinel")
  [ -n "$sha" ]
  [ ${#sha} -eq 64 ]
}

@test "persist install removes com.unleash.monitor plist" {
  mkdir -p "$TEST_DIR/Library/LaunchDaemons"
  echo "old-monitor" > "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist"
  install_persist_launchdaemon "$TEST_DIR"
  [ ! -f "$TEST_DIR/Library/LaunchDaemons/com.unleash.monitor.plist" ]
}

@test "persist missing source binary is E_PERSIST_PATH and not success" {
  SCRIPT_DIR="$TEST_DIR/missing-src"
  mkdir -p "$SCRIPT_DIR"
  DATA_ROOT="$TEST_DIR"
  st=0
  persist_copy "$TEST_DIR" || st=$?
  [ "$st" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_PERSIST_PATH" ]
}

@test "probe_hosts requires 0.0.0.0 or :: for three MDM domains" {
  DATA_ROOT="$TEST_DIR"
  : > "$TEST_DIR/private/etc/hosts"
  probe_hosts
  [ "$RESULT_STATUS" = "fail" ]
  printf '0.0.0.0 iprofiles.apple.com\n0.0.0.0 deviceenrollment.apple.com\n0.0.0.0 mdmenrollment.apple.com\n' > "$TEST_DIR/private/etc/hosts"
  probe_hosts
  [ "$RESULT_STATUS" = "ok" ]
}

@test "probe_dep requires cloudConfigRecordNotFound" {
  DATA_ROOT="$TEST_DIR"
  probe_dep
  [ "$RESULT_STATUS" = "fail" ]
  touch "$TEST_DIR/private/var/db/ConfigurationProfiles/Settings/.cloudConfigRecordNotFound"
  probe_dep
  [ "$RESULT_STATUS" = "ok" ]
}

@test "probe_dns skips off live OS with S_NO_DSCACHEUTIL" {
  DATA_ROOT="$TEST_DIR"
  probe_dns
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_NO_DSCACHEUTIL" ]
}

@test "probe_pf Recovery/fixture is S_PF_RECOVERY when anchor exists" {
  DATA_ROOT="$TEST_DIR"
  probe_pf
  [ "$RESULT_STATUS" = "fail" ]
  mkdir -p "$TEST_DIR/private/etc/pf.anchors/com.unleash"
  printf 'block drop from any to 17.0.0.0/8\n' > "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  probe_pf
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_PF_RECOVERY" ]
}

@test "probe_processes off live OS is S_ALREADY_OK not S_NO_PROFILES_CMD" {
  DATA_ROOT="$TEST_DIR"
  probe_processes
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_ALREADY_OK" ]
}

@test "probe_processes missing TSV on live OS fails" {
  _probe_is_live_os() { return 0; }
  _mdm_agents_tsv() { return 1; }
  DATA_ROOT="$TEST_DIR"
  probe_processes
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_VERIFY_FAIL" ]
}

@test "probe_processes TSV running agent fails" {
  _probe_is_live_os() { return 0; }
  printf 'dummy\tdummyagent\t/usr/local/bin/no-such-dummy\t/Library/LaunchDaemons/com.nosuchdummy*\n' > "$TEST_DIR/agents.tsv"
  _mdm_agents_tsv() { printf '%s\n' "$TEST_DIR/agents.tsv"; }
  ps() {
    echo "root 42 0.0 0.0 dummyagent"
  }
  DATA_ROOT="$TEST_DIR"
  probe_processes
  [ "$RESULT_STATUS" = "fail" ]
}

@test "probe_processes TSV binary on Data volume fails" {
  _probe_is_live_os() { return 0; }
  printf 'dummy\tdummyagent\t/usr/local/bin/dummyagent\t/Library/LaunchDaemons/com.dummy*\n' > "$TEST_DIR/agents.tsv"
  _mdm_agents_tsv() { printf '%s\n' "$TEST_DIR/agents.tsv"; }
  mkdir -p "$TEST_DIR/usr/local/bin"
  printf '#!/bin/sh\n' > "$TEST_DIR/usr/local/bin/dummyagent"
  DATA_ROOT="$TEST_DIR"
  probe_processes
  [ "$RESULT_STATUS" = "fail" ]
}

@test "probe_processes TSV launchd glob fails" {
  _probe_is_live_os() { return 0; }
  printf 'dummy\tdummyagent\t/usr/local/bin/no-such-dummy\t/Library/LaunchDaemons/com.dummy*\n' > "$TEST_DIR/agents.tsv"
  _mdm_agents_tsv() { printf '%s\n' "$TEST_DIR/agents.tsv"; }
  printf 'plist' > "$TEST_DIR/Library/LaunchDaemons/com.dummy.agent.plist"
  DATA_ROOT="$TEST_DIR"
  probe_processes
  [ "$RESULT_STATUS" = "fail" ]
}

@test "probe_processes missing profiles on live is S_NO_PROFILES_CMD" {
  _probe_is_live_os() { return 0; }
  printf '# id\tproc_pattern\tbinaries\tlaunch_glob\n' > "$TEST_DIR/agents.tsv"
  _mdm_agents_tsv() { printf '%s\n' "$TEST_DIR/agents.tsv"; }
  PROFILES="/no/such/profiles"
  DATA_ROOT="$TEST_DIR"
  probe_processes
  [ "$RESULT_STATUS" = "skip" ]
  [ "$RESULT_REASON" = "S_NO_PROFILES_CMD" ]
}

@test "probe_processes enrollment Yes plus mdmclient fails" {
  _probe_is_live_os() { return 0; }
  printf '# id\tproc_pattern\tbinaries\tlaunch_glob\n' > "$TEST_DIR/agents.tsv"
  _mdm_agents_tsv() { printf '%s\n' "$TEST_DIR/agents.tsv"; }
  stub=$(mktemp)
  printf '%s\n' '#!/bin/bash' 'echo "Enrolled via DEP: Yes"' 'echo "MDM enrollment: Yes"' > "$stub"
  chmod +x "$stub"
  PROFILES="$stub"
  ps() {
    echo "root 1 0.0 0.0 /usr/libexec/mdmclient"
  }
  DATA_ROOT="$TEST_DIR"
  probe_processes
  rm -f "$stub"
  [ "$RESULT_STATUS" = "fail" ]
}

@test "probe_processes idle mdmclient with enrollment No is ok" {
  _probe_is_live_os() { return 0; }
  printf '# id\tproc_pattern\tbinaries\tlaunch_glob\n' > "$TEST_DIR/agents.tsv"
  _mdm_agents_tsv() { printf '%s\n' "$TEST_DIR/agents.tsv"; }
  stub=$(mktemp)
  printf '%s\n' '#!/bin/bash' 'echo "Enrolled via DEP: No"' 'echo "MDM enrollment: No"' > "$stub"
  chmod +x "$stub"
  PROFILES="$stub"
  ps() {
    echo "root 1 0.0 0.0 /usr/libexec/mdmclient"
  }
  DATA_ROOT="$TEST_DIR"
  probe_processes
  rm -f "$stub"
  [ "$RESULT_STATUS" = "ok" ]
}

@test "run_probes clean pass writes last-good kv and dirty does not overwrite" {
  DATA_ROOT="$TEST_DIR"
  suppress_enrollment "$TEST_DIR"
  persist_copy "$TEST_DIR"
  mkdir -p "$TEST_DIR/private/etc/pf.anchors/com.unleash"
  printf 'block drop from any to 17.0.0.0/8\n' > "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  run_probes
  [ "$RESULT_STATUS" = "ok" ]
  lg="$TEST_DIR/Library/Unleash/state/last-good"
  [ -f "$lg" ]
  grep -q 'probe=hosts status=ok' "$lg"
  grep -q 'probe=dns status=skip reason=S_NO_DSCACHEUTIL' "$lg"
  grep -q 'probe=pf status=skip reason=S_PF_RECOVERY' "$lg"
  cp "$lg" "$TEST_DIR/last-good.clean"
  rm -f "$TEST_DIR/private/etc/hosts"
  run_probes
  [ "$RESULT_STATUS" = "fail" ]
  [ -f "$lg" ]
  cmp -s "$lg" "$TEST_DIR/last-good.clean"
}

@test "last-good write failure does not fail clean run_probes" {
  DATA_ROOT="$TEST_DIR"
  suppress_enrollment "$TEST_DIR"
  persist_copy "$TEST_DIR"
  mkdir -p "$TEST_DIR/private/etc/pf.anchors/com.unleash"
  printf 'block drop from any to 17.0.0.0/8\n' > "$TEST_DIR/private/etc/pf.anchors/com.unleash/mdm"
  journal_last_good_write() { return 1; }
  set -e
  run_probes
  [ "$RESULT_STATUS" = "ok" ]
}

@test "persist not-writable dest is status 1 E_PERSIST_PATH" {
  USB=$(mktemp -d)
  mkdir -p "$USB/lib"
  printf '%s\n' '#!/bin/bash' > "$USB/unleash"
  printf '%s\n' '# lib' > "$USB/lib/heal.sh"
  SCRIPT_DIR="$USB"
  DATA_ROOT="$TEST_DIR"
  mkdir -p "$TEST_DIR/Library/Unleash" "$TEST_DIR/Library/LaunchDaemons"
  chmod a-w "$TEST_DIR/Library/Unleash"
  st=0
  persist_copy "$TEST_DIR" || st=$?
  chmod u+w "$TEST_DIR/Library/Unleash" 2>/dev/null || true
  rm -rf "$USB"
  [ "$st" -eq 1 ]
  [ "$RESULT_STATUS" = "fail" ]
  [ "$RESULT_REASON" = "E_PERSIST_PATH" ]
}
