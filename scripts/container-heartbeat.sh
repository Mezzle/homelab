#!/usr/bin/env bash
###############################################################################
# container-heartbeat.sh — push per-container health to Uptime Kuma
#
# Background containers (recyclarr, rclone-seedbox, backup, docktail, …) have
# no HTTP port for Kuma to probe. Instead this script runs on each host from
# cron, inspects every container it's told to watch, and pings that
# container's Kuma PUSH monitor with up/down.
#
# Health logic per container:
#   - not present / not running        -> push status=down
#   - running, has healthcheck:
#         healthy                      -> push status=up
#         starting                     -> push status=up  (grace; don't alarm)
#         unhealthy                    -> push status=down
#   - running, no healthcheck          -> push status=up  (running is all we have)
#
# A container going Down stops nothing here — Kuma flips the monitor and fires
# the Discord + Hermes-agent webhooks. Kuma's own "No heartbeat in the time
# window" also covers the case where THIS host or cron dies (the push simply
# stops), so a dead heartbeat script is itself an alert.
#
# Config: a token map file, one "container<TAB>pushtoken" per line, at
#   /srv/docker/<host>/monitoring/heartbeat-tokens.env
# (deployed by sync-secrets.sh from 1Password; NOT committed). Lines starting
# with # and blank lines are ignored. "container" is the docker container name;
# it may differ from the Kuma monitor name (e.g. "docktail" here maps to the
# "docktail (pancake)" monitor's token).
#
# Kuma push endpoint base is KUMA_PUSH_BASE (default http://powder:3001).
#
# Deployed via the repo; run by container-heartbeat cron/timer every 60s.
###############################################################################
set -uo pipefail

KUMA_PUSH_BASE="${KUMA_PUSH_BASE:-http://powder:3001}"
TOKEN_MAP="${TOKEN_MAP:-}"
CURL_TIMEOUT=10

log() { echo "[container-heartbeat] $*"; }

# Locate the token map if not given explicitly: try each host's monitoring dir.
if [[ -z "$TOKEN_MAP" ]]; then
  for h in pancake charm powder; do
    cand="/srv/docker/$h/monitoring/heartbeat-tokens.env"
    [[ -f "$cand" ]] && { TOKEN_MAP="$cand"; break; }
  done
fi

if [[ -z "$TOKEN_MAP" || ! -f "$TOKEN_MAP" ]]; then
  log "ERROR: no token map found (looked for /srv/docker/<host>/monitoring/heartbeat-tokens.env)"
  exit 1
fi

# Return the effective status word for a container: up | down | starting-up
container_status() {
  local name="$1" state health
  state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null) || {
    echo "missing"; return
  }
  if [[ "$state" != "running" ]]; then
    echo "$state"; return
  fi
  # running — check health if a healthcheck exists
  health=$(docker inspect "$name" --format '{{if .Config.Healthcheck}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)
  case "$health" in
    healthy|none) echo "up" ;;
    starting)     echo "up" ;;   # startup grace — treat as up, don't alarm
    unhealthy)    echo "unhealthy" ;;
    *)            echo "up" ;;    # unknown health string, but it IS running
  esac
}

push() {
  local token="$1" status="$2" msg="$3"
  curl -fsS -m "$CURL_TIMEOUT" -o /dev/null \
    "${KUMA_PUSH_BASE}/api/push/${token}?status=${status}&msg=$(printf '%s' "$msg" | sed 's/ /%20/g')&ping=" \
    2>/dev/null
}

rc=0
while IFS=$'\t' read -r container token; do
  # skip comments / blanks
  [[ -z "${container// }" || "${container:0:1}" == "#" ]] && continue
  [[ -z "${token// }" ]] && { log "WARN: no token for '$container' — skipping"; continue; }

  st=$(container_status "$container")
  case "$st" in
    up)
      push "$token" up "OK" || { log "WARN: push failed for $container"; rc=1; }
      ;;
    *)
      # missing | exited | unhealthy | restarting | paused | dead ...
      push "$token" down "$st" || { log "WARN: push(down) failed for $container"; rc=1; }
      log "DOWN: $container ($st)"
      ;;
  esac
done < "$TOKEN_MAP"

exit "$rc"
