#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/web.sh'
}

@test "generate_html_dashboard generates HTML string" {
  run generate_html_dashboard
  [ "$status" -eq 0 ]
  [[ "$output" =~ "<!DOCTYPE html>" ]]
}

@test "generate_prometheus_metrics generates metrics" {
  run generate_prometheus_metrics
  [ "$status" -eq 0 ]
  [[ "$output" =~ "unleash_firewall_active" ]]
}
