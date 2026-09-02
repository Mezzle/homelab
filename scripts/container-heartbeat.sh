#!/usr/bin/env bash
###############################################################################
# container-heartbeat.sh — push container health and disk usage to Uptime Kuma
#
# Background containers (recyclarr, rclone-seedbox, backup, docktail, …) have
# no HTTP port for Kuma to probe. This script runs on each host from a timer,
# inspects every container it's told to watch, and pings that container's
# Kuma PUSH monitor with up/down. Filesystems are checked the same way.
#
# Health logic per container:
#   - not present / not running        -> push status=down
#   - running, has healthcheck:
#         healthy                      -> push status=up
#         starting                     -> push status=up  (grace; don't alarm)
#         unhealthy                    -> push status=down
#   - running, no healthcheck          -> push status=up  (running is all we have)
#
# Disk logic: usage at or above DISK_THRESHOLD percent -> push status=down,
# with the percentage in the message.
#
# A monitor going Down stops nothing here — Kuma flips the monitor and fires
# the Discord + Hermes-agent webhooks. Kuma's own "No heartbeat in the time
# window" also covers the case where THIS host or the timer dies (the push
# simply stops), so a dead heartbeat script is itself an alert.
#
# Config: a token map file, one "<name><TAB><pushtoken>" per line, at
#   /srv/docker/<host>/monitoring/heartbeat-tokens.env
# (deployed out of band; NOT committed). Lines starting with # and blank
# lines are ignored. <name> is one of:
#   <container>       docker container name (may differ from the Kuma monitor
#                     name, e.g. "docktail" -> the "docktail (pancake)" monitor)
#   disk:<mountpoint> filesystem to check, e.g. disk:/var or disk:/var/mnt/storage
#                     (/ is composefs on Fedora CoreOS and always reads 100%;
#                     /var is the real disk)
#   host-backup       reserved for backup-host.sh; skipped here. (A container
#                     named "backup" is just a container.)
#
# Kuma push endpoint base is KUMA_PUSH_BASE (default http://powder:3001).
#
# Deployed via coreos/os-configs/manifest.conf; run by container-heartbeat.timer.
###############################################################################
set -uo pipefail

KUMA_PUSH_BASE="${KUMA_PUSH_BASE:-http://powder:3001}"
HOST=$(hostname -s)
TOKEN_MAP="${TOKEN_MAP:-/srv/docker/$HOST/monitoring/heartbeat-tokens.env}"
DISK_THRESHOLD="${DISK_THRESHOLD:-90}"
CURL_TIMEOUT=10

log() { echo "[container-heartbeat] $*"; }

if [[ ! -f "$TOKEN_MAP" ]]; then
  log "ERROR: no token map at $TOKEN_MAP"
  exit 1
fi

# Return the effective status word for a container: up | <state> | unhealthy
container_status() {
  local name="$1" state health
  state=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null) || {
    echo "missing"; return
  }
  if [[ "$state" != "running" ]]; then
    echo "$state"; return
  fi
  health=$(docker inspect "$name" --format '{{if .Config.Healthcheck}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null)
  case "$health" in
    unhealthy) echo "unhealthy" ;;
    *)         echo "up" ;;      # healthy, starting, none, or unknown but running
  esac
}

# Print "up <pct>%" or "down <pct>%" for a mount point.
disk_status() {
  local mount="$1" pct
  pct=$(df --output=pcent "$mount" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -z "$pct" ]]; then
    echo "down not-mounted"; return
  fi
  if (( pct >= DISK_THRESHOLD )); then
    echo "down ${pct}%"
  else
    echo "up ${pct}%"
  fi
}

push() {
  local token="$1" status="$2" msg="$3"
  curl -fsS -m "$CURL_TIMEOUT" -o /dev/null \
    "${KUMA_PUSH_BASE}/api/push/${token}?status=${status}&msg=$(printf '%s' "$msg" | sed 's/%/%25/g;s/ /%20/g')&ping=" \
    2>/dev/null
}

rc=0
while IFS=$'\t' read -r name token; do
  [[ -z "${name// }" || "${name:0:1}" == "#" ]] && continue
  [[ "$name" == "host-backup" ]] && continue
  [[ -z "${token// }" ]] && { log "WARN: no token for '$name' — skipping"; continue; }

  case "$name" in
    disk:*)
      read -r status msg <<< "$(disk_status "${name#disk:}")"
      [[ "$status" == "down" ]] && log "DOWN: $name ($msg)"
      ;;
    *)
      st=$(container_status "$name")
      if [[ "$st" == "up" ]]; then
        status=up; msg=OK
      else
        status=down; msg="$st"
        log "DOWN: $name ($st)"
      fi
      ;;
  esac

  push "$token" "$status" "$msg" || { log "WARN: push failed for $name"; rc=1; }
done < "$TOKEN_MAP"

exit "$rc"
