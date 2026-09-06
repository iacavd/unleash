#!/usr/bin/env bats

setup() {
  load '../lib/colors.sh'
  load '../lib/webhook.sh'
}

@test "send_webhook_alert fails gracefully without webhook url" {
  run send_webhook_alert "generic" ""
  [ "$status" -ne 0 ]
}
