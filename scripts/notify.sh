#!/usr/bin/env bash
###############################################################################
# notify.sh — Discord notification helper
#
# Source this in other scripts:
#   source "$(dirname "$0")/../scripts/notify.sh"  # or wherever it lives
#
# Then call:
#   notify critical "Backup failed" "sonarr.db could not be backed up"
#   notify warning  "Disk space low" "/mnt/storage is at 87%"
#   notify success  "Backup complete" "4 databases, 12MB total"
#   notify info     "GitOps sync"    "Updated arr stack (3 files changed)"
#
# Requires DISCORD_WEBHOOK_URL in the environment. If unset, notifications
# are silently skipped (scripts still work without Discord configured).
###############################################################################

notify() {
  local level="$1" title="$2" message="${3:-}"
  local webhook_url="${DISCORD_WEBHOOK_URL:-}"

  # Skip silently if no webhook configured
  [[ -z "$webhook_url" ]] && return 0

  local color
  case "$level" in
    critical) color=16711680 ;;  # red
    warning)  color=16776960 ;;  # yellow
    success)  color=65280    ;;  # green
    info)     color=3447003  ;;  # blue
    *)        color=8421504  ;;  # grey
  esac

  local hostname
  hostname=$(hostname -s 2>/dev/null || echo "homelab")

  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

  # Post to Discord — fire and forget, never fail the calling script
  curl -sf -H "Content-Type: application/json" -d "{
    \"embeds\": [{
      \"title\": \"${title}\",
      \"description\": \"${message}\",
      \"color\": ${color},
      \"footer\": {\"text\": \"${hostname}\"},
      \"timestamp\": \"${timestamp}\"
    }]
  }" "$webhook_url" >/dev/null 2>&1 || true
}

# Load webhook URL from common locations if not already set
if [[ -z "${DISCORD_WEBHOOK_URL:-}" ]]; then
  for f in /etc/discord-webhook.env "$HOME/.discord-webhook.env"; do
    if [[ -f "$f" ]]; then
      source "$f"
      break
    fi
  done
fi
