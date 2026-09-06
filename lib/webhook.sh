#!/usr/bin/env bash
# Unleash — Multi-Channel Webhook Alerting Module
# Supports Discord, Slack, Telegram, Ntfy.sh, and Generic JSON Webhooks.

set -euo pipefail

send_webhook_alert() {
  local service_type="${1:-generic}"
  local webhook_url="${2:-}"
  local message="${3:-Unleash Alert Triggered}"
  local title="${4:-Unleash Alert}"

  if [ -z "$webhook_url" ]; then
    warn "Webhook URL is required."
    return 1
  fi

  info "Dispatching notification via $service_type..."

  case "$service_type" in
    discord)
      local payload
      payload=$(cat <<EOF
{
  "embeds": [
    {
      "title": "$title",
      "description": "$message",
      "color": 15158332,
      "footer": { "text": "Unleash Alert Engine" },
      "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    }
  ]
}
EOF
)
      curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$webhook_url" >/dev/null && success "Discord alert sent." || warn "Failed to send Discord alert."
      ;;

    slack)
      local payload
      payload=$(cat <<EOF
{
  "blocks": [
    {
      "type": "header",
      "text": { "type": "plain_text", "text": "$title" }
    },
    {
      "type": "section",
      "text": { "type": "mrkdwn", "text": "$message" }
    }
  ]
}
EOF
)
      curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$webhook_url" >/dev/null && success "Slack alert sent." || warn "Failed to send Slack alert."
      ;;

    telegram)
      # webhook_url format: <bot_token>/<chat_id>
      local bot_token chat_id
      bot_token=$(echo "$webhook_url" | cut -d'/' -f1)
      chat_id=$(echo "$webhook_url" | cut -d'/' -f2)

      if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        warn "Telegram webhook URL format must be 'BOT_TOKEN/CHAT_ID'"
        return 1
      fi

      local api_url="https://api.telegram.org/bot${bot_token}/sendMessage"
      curl -s -X POST "$api_url" -d "chat_id=${chat_id}" -d "text=🔻 *${title}*%0A${message}" -d "parse_mode=Markdown" >/dev/null && success "Telegram alert sent." || warn "Failed to send Telegram alert."
      ;;

    ntfy)
      curl -s -H "Title: $title" -d "$message" "$webhook_url" >/dev/null && success "Ntfy alert sent." || warn "Failed to send Ntfy alert."
      ;;

    generic|*)
      local payload
      payload=$(cat <<EOF
{
  "event": "unleash_alert",
  "title": "$title",
  "message": "$message",
  "hostname": "$(hostname)",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)
      curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$webhook_url" >/dev/null && success "Generic webhook alert sent." || warn "Failed to send generic webhook alert."
      ;;
  esac
}
