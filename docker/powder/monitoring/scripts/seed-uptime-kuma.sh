#!/usr/bin/env bash
###############################################################################
# seed-uptime-kuma.sh — Create monitors for all homelab services
#
# Run once after Uptime Kuma is deployed and you've created an account:
#   ./scripts/seed-uptime-kuma.sh
#
# Prerequisites:
#   - Uptime Kuma running and accessible
#   - You've created an admin account via the web UI
#   - jq installed (brew install jq / apk add jq)
#
# This uses the Uptime Kuma API to create monitors. It's idempotent —
# running it again won't create duplicates (it checks by name first).
###############################################################################
set -euo pipefail

# Configuration — update these
UPK_URL="${UPK_URL:-http://localhost:3001}"
UPK_USER="${UPK_USER:-}"
UPK_PASS="${UPK_PASS:-}"
TAILNET="${TAILNET:-your-tailnet}"

if [[ -z "$UPK_USER" || -z "$UPK_PASS" ]]; then
  echo "Usage: UPK_USER=admin UPK_PASS=password TAILNET=tail1234 $0"
  echo "  UPK_URL defaults to http://localhost:3001"
  exit 1
fi

log() { echo "[seed] $*"; }

###############################################################################
# Login and get token
###############################################################################
log "Logging in to Uptime Kuma at $UPK_URL..."
TOKEN=$(curl -sf "$UPK_URL/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$UPK_USER\",\"password\":\"$UPK_PASS\"}" \
  | jq -r '.token')

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Login failed. Check credentials."
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

###############################################################################
# Helper: create a monitor if it doesn't exist
###############################################################################
existing_monitors() {
  curl -sf "$UPK_URL/api/monitors" -H "$AUTH" | jq -r '.[].name'
}

EXISTING=$(existing_monitors)

add_monitor() {
  local name="$1" url="$2" type="${3:-http}" interval="${4:-60}"

  if echo "$EXISTING" | grep -qxF "$name"; then
    log "SKIP: $name (already exists)"
    return
  fi

  local payload
  payload=$(jq -n \
    --arg name "$name" \
    --arg url "$url" \
    --arg type "$type" \
    --argjson interval "$interval" \
    '{
      name: $name,
      url: $url,
      type: $type,
      interval: $interval,
      retryInterval: 30,
      maxretries: 3,
      accepted_statuscodes: ["200-299"]
    }')

  if curl -sf "$UPK_URL/api/monitors" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null; then
    log "  OK: $name"
  else
    log "FAIL: $name"
  fi
}

###############################################################################
# Create monitors for all services
###############################################################################
log "Creating monitors..."

# pancake services
add_monitor "Plex"            "https://plex.${TAILNET}.ts.net/web"
add_monitor "Sonarr"          "https://sonarr.${TAILNET}.ts.net"
add_monitor "Radarr"          "https://radarr.${TAILNET}.ts.net"
add_monitor "Prowlarr"        "https://prowlarr.${TAILNET}.ts.net"
add_monitor "Bazarr"          "https://bazarr.${TAILNET}.ts.net"
add_monitor "Immich"          "https://immich.${TAILNET}.ts.net"
add_monitor "Music Assistant" "https://music.${TAILNET}.ts.net"
add_monitor "Dockge"          "https://dockge.${TAILNET}.ts.net"
add_monitor "Homepage"        "https://homepage.${TAILNET}.ts.net"

# charm services
add_monitor "Zigbee2MQTT"     "https://z2m.${TAILNET}.ts.net"
add_monitor "Scrypted"        "https://scrypted.${TAILNET}.ts.net"
add_monitor "AdGuard Home"    "https://adguard.${TAILNET}.ts.net"
add_monitor "Dockge (charm)"  "https://dockge-charm.${TAILNET}.ts.net"

# powder services
add_monitor "Alertmanager"    "https://alertmanager.${TAILNET}.ts.net/-/healthy"
add_monitor "Dockge (powder)" "https://dockge-powder.${TAILNET}.ts.net"

# Host-level checks (Tailscale SSH / ping)
add_monitor "pancake (host)"  "pancake" "ping" 120
add_monitor "charm (host)"    "charm"   "ping" 120
add_monitor "powder (host)"   "powder"  "ping" 120

log "Done. Open $UPK_URL to review monitors."
log "Don't forget to set up a notification method (Discord, etc) in the UI."
