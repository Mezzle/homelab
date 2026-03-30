#!/usr/bin/env bash
###############################################################################
# bootstrap.sh — Auto-configure cross-service connections after first boot
#
# Links Prowlarr → Sonarr/Radarr, configures FlareSolverr proxy,
# connects Bazarr → Sonarr/Radarr, sets up Plex notifications,
# and triggers an initial Recyclarr sync.
#
# Prerequisites:
#   - All arr services must be running and healthy
#   - API keys are auto-extracted from container config files
#
# Usage:
#   ./scripts/bootstrap.sh         # Run all configuration
#   ./scripts/bootstrap.sh --dry   # Preview without making changes
###############################################################################
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry" ]] && DRY_RUN=true

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "[bootstrap] $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}~${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*"; }

###############################################################################
# Helper: extract API keys from running containers
###############################################################################
get_xml_api_key() {
  local container="$1"
  docker exec "$container" grep -oP '<ApiKey>\K[^<]+' /config/config.xml 2>/dev/null || echo ""
}

get_bazarr_api_key() {
  docker exec bazarr cat /config/config/config.yaml 2>/dev/null | grep -oP 'apikey:\s*\K\S+' || echo ""
}

###############################################################################
# Helper: make API calls (respects --dry mode)
###############################################################################
api_call() {
  local method="$1" url="$2" data="${3:-}"
  if $DRY_RUN; then
    log "  [DRY] $method $url"
    [[ -n "$data" ]] && log "  [DRY] Body: $data"
    return 0
  fi
  local args=(-s -o /dev/null -w "%{http_code}" -X "$method" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}" "$url"
}

api_get() {
  local url="$1"
  curl -s -H "Content-Type: application/json" "$url"
}

###############################################################################
# Wait for services to be ready
###############################################################################
wait_for_service() {
  local name="$1" url="$2" max_attempts="${3:-30}"
  local attempt=0
  log "Waiting for $name..."
  while [[ $attempt -lt $max_attempts ]]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      ok "$name is ready"
      return 0
    fi
    ((attempt++))
    sleep 2
  done
  fail "$name not ready after $((max_attempts * 2))s"
  return 1
}

###############################################################################
# Extract API keys
###############################################################################
log "Extracting API keys..."

SONARR_KEY=$(get_xml_api_key sonarr)
RADARR_KEY=$(get_xml_api_key radarr)
PROWLARR_KEY=$(get_xml_api_key prowlarr)
BAZARR_KEY=$(get_bazarr_api_key)

[[ -z "$SONARR_KEY" ]] && { fail "Could not extract Sonarr API key"; exit 1; }
[[ -z "$RADARR_KEY" ]] && { fail "Could not extract Radarr API key"; exit 1; }
[[ -z "$PROWLARR_KEY" ]] && { fail "Could not extract Prowlarr API key"; exit 1; }
[[ -z "$BAZARR_KEY" ]] && { fail "Could not extract Bazarr API key"; exit 1; }

ok "Sonarr:   ${SONARR_KEY:0:8}..."
ok "Radarr:   ${RADARR_KEY:0:8}..."
ok "Prowlarr: ${PROWLARR_KEY:0:8}..."
ok "Bazarr:   ${BAZARR_KEY:0:8}..."

# Service URLs (internal Docker network)
SONARR_URL="http://sonarr:8989"
RADARR_URL="http://radarr:7878"
PROWLARR_URL="http://gluetun:9696"
BAZARR_URL="http://bazarr:6767"
PLEX_URL="http://host-gateway:32400"
FLARESOLVERR_URL="http://flaresolverr:8191"

###############################################################################
# Wait for all services
###############################################################################
wait_for_service "Sonarr"     "$SONARR_URL/api/v3/system/status?apikey=$SONARR_KEY"
wait_for_service "Radarr"     "$RADARR_URL/api/v3/system/status?apikey=$RADARR_KEY"
wait_for_service "Prowlarr"   "$PROWLARR_URL/api/v1/system/status?apikey=$PROWLARR_KEY"
wait_for_service "Bazarr"     "$BAZARR_URL/api/system/status?apikey=$BAZARR_KEY"

###############################################################################
# 1. Configure root folders
###############################################################################
log "Configuring root folders..."

# Sonarr — /data/media/tv
EXISTING=$(api_get "$SONARR_URL/api/v3/rootfolder?apikey=$SONARR_KEY")
if echo "$EXISTING" | grep -q "/data/media/tv"; then
  ok "Sonarr root folder already configured"
else
  STATUS=$(api_call POST "$SONARR_URL/api/v3/rootfolder?apikey=$SONARR_KEY" \
    '{"path":"/data/media/tv","qualityProfileId":1,"metadataProfileId":1}')
  [[ "$STATUS" == "201" || "$DRY_RUN" == "true" ]] && ok "Sonarr root folder: /data/media/tv" || fail "Sonarr root folder ($STATUS)"
fi

# Radarr — /data/media/movies
EXISTING=$(api_get "$RADARR_URL/api/v3/rootfolder?apikey=$RADARR_KEY")
if echo "$EXISTING" | grep -q "/data/media/movies"; then
  ok "Radarr root folder already configured"
else
  STATUS=$(api_call POST "$RADARR_URL/api/v3/rootfolder?apikey=$RADARR_KEY" \
    '{"path":"/data/media/movies","qualityProfileId":1,"metadataProfileId":1}')
  [[ "$STATUS" == "201" || "$DRY_RUN" == "true" ]] && ok "Radarr root folder: /data/media/movies" || fail "Radarr root folder ($STATUS)"
fi

###############################################################################
# 2. Prowlarr → Sonarr/Radarr app sync
###############################################################################
log "Configuring Prowlarr app sync..."

# Check existing apps
EXISTING_APPS=$(api_get "$PROWLARR_URL/api/v1/applications?apikey=$PROWLARR_KEY")

# Prowlarr → Sonarr
if echo "$EXISTING_APPS" | grep -q "Sonarr"; then
  ok "Prowlarr → Sonarr already configured"
else
  STATUS=$(api_call POST "$PROWLARR_URL/api/v1/applications?apikey=$PROWLARR_KEY" \
    "{
      \"name\": \"Sonarr\",
      \"syncLevel\": \"fullSync\",
      \"implementation\": \"Sonarr\",
      \"configContract\": \"SonarrSettings\",
      \"fields\": [
        {\"name\": \"prowlarrUrl\", \"value\": \"http://gluetun:9696\"},
        {\"name\": \"baseUrl\", \"value\": \"$SONARR_URL\"},
        {\"name\": \"apiKey\", \"value\": \"$SONARR_KEY\"},
        {\"name\": \"syncCategories\", \"value\": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]}
      ]
    }")
  [[ "$STATUS" == "201" || "$DRY_RUN" == "true" ]] && ok "Prowlarr → Sonarr" || fail "Prowlarr → Sonarr ($STATUS)"
fi

# Prowlarr → Radarr
if echo "$EXISTING_APPS" | grep -q "Radarr"; then
  ok "Prowlarr → Radarr already configured"
else
  STATUS=$(api_call POST "$PROWLARR_URL/api/v1/applications?apikey=$PROWLARR_KEY" \
    "{
      \"name\": \"Radarr\",
      \"syncLevel\": \"fullSync\",
      \"implementation\": \"Radarr\",
      \"configContract\": \"RadarrSettings\",
      \"fields\": [
        {\"name\": \"prowlarrUrl\", \"value\": \"http://gluetun:9696\"},
        {\"name\": \"baseUrl\", \"value\": \"$RADARR_URL\"},
        {\"name\": \"apiKey\", \"value\": \"$RADARR_KEY\"},
        {\"name\": \"syncCategories\", \"value\": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]}
      ]
    }")
  [[ "$STATUS" == "201" || "$DRY_RUN" == "true" ]] && ok "Prowlarr → Radarr" || fail "Prowlarr → Radarr ($STATUS)"
fi

###############################################################################
# 3. FlareSolverr proxy in Prowlarr
###############################################################################
log "Configuring FlareSolverr proxy..."

EXISTING_PROXIES=$(api_get "$PROWLARR_URL/api/v1/indexerproxy?apikey=$PROWLARR_KEY")
if echo "$EXISTING_PROXIES" | grep -q "FlareSolverr"; then
  ok "FlareSolverr proxy already configured"
else
  STATUS=$(api_call POST "$PROWLARR_URL/api/v1/indexerproxy?apikey=$PROWLARR_KEY" \
    "{
      \"name\": \"FlareSolverr\",
      \"implementation\": \"FlareSolverr\",
      \"configContract\": \"FlareSolverrSettings\",
      \"fields\": [
        {\"name\": \"host\", \"value\": \"$FLARESOLVERR_URL\"},
        {\"name\": \"requestTimeout\", \"value\": 60}
      ]
    }")
  [[ "$STATUS" == "201" || "$DRY_RUN" == "true" ]] && ok "FlareSolverr proxy" || fail "FlareSolverr proxy ($STATUS)"
fi

###############################################################################
# 4. Bazarr → Sonarr/Radarr
###############################################################################
log "Configuring Bazarr connections..."

# Get current Bazarr settings
BAZARR_SETTINGS=$(api_get "$BAZARR_URL/api/system/settings?apikey=$BAZARR_KEY")

# Update Sonarr connection
STATUS=$(api_call POST "$BAZARR_URL/api/system/settings?apikey=$BAZARR_KEY" \
  "{
    \"settings\": {
      \"sonarr\": {
        \"ip\": \"sonarr\",
        \"port\": 8989,
        \"apikey\": \"$SONARR_KEY\",
        \"base_url\": \"\",
        \"ssl\": false
      }
    }
  }")
[[ "$STATUS" == "200" || "$STATUS" == "204" || "$DRY_RUN" == "true" ]] && ok "Bazarr → Sonarr" || fail "Bazarr → Sonarr ($STATUS)"

# Update Radarr connection
STATUS=$(api_call POST "$BAZARR_URL/api/system/settings?apikey=$BAZARR_KEY" \
  "{
    \"settings\": {
      \"radarr\": {
        \"ip\": \"radarr\",
        \"port\": 7878,
        \"apikey\": \"$RADARR_KEY\",
        \"base_url\": \"\",
        \"ssl\": false
      }
    }
  }")
[[ "$STATUS" == "200" || "$STATUS" == "204" || "$DRY_RUN" == "true" ]] && ok "Bazarr → Radarr" || fail "Bazarr → Radarr ($STATUS)"

###############################################################################
# 5. Plex notification in Sonarr/Radarr
###############################################################################
log "Configuring Plex notifications..."

for app in sonarr radarr; do
  local_url="http://${app}:$([ "$app" = "sonarr" ] && echo 8989 || echo 7878)"
  local_key=$([ "$app" = "sonarr" ] && echo "$SONARR_KEY" || echo "$RADARR_KEY")

  EXISTING_NOTIFS=$(api_get "$local_url/api/v3/notification?apikey=$local_key")
  if echo "$EXISTING_NOTIFS" | grep -q "Plex"; then
    ok "Plex notification in $app already configured"
  else
    STATUS=$(api_call POST "$local_url/api/v3/notification?apikey=$local_key" \
      "{
        \"name\": \"Plex\",
        \"implementation\": \"PlexServer\",
        \"configContract\": \"PlexServerSettings\",
        \"onDownload\": true,
        \"onUpgrade\": true,
        \"onRename\": true,
        \"fields\": [
          {\"name\": \"host\", \"value\": \"host-gateway\"},
          {\"name\": \"port\", \"value\": 32400},
          {\"name\": \"useSsl\", \"value\": false},
          {\"name\": \"updateLibrary\", \"value\": true}
        ]
      }")
    [[ "$STATUS" == "201" || "$DRY_RUN" == "true" ]] && ok "Plex notification in $app" || fail "Plex notification in $app ($STATUS)"
  fi
done

###############################################################################
# 6. Trigger initial Recyclarr sync
###############################################################################
log "Triggering initial Recyclarr sync..."

if $DRY_RUN; then
  log "  [DRY] docker exec recyclarr recyclarr sync"
else
  if docker exec recyclarr recyclarr sync 2>&1; then
    ok "Recyclarr initial sync complete"
  else
    warn "Recyclarr sync had issues (check logs: docker logs recyclarr)"
  fi
fi

###############################################################################
# Done
###############################################################################
echo ""
log "Bootstrap complete!"
$DRY_RUN && log "(Dry run — no changes were made)"
