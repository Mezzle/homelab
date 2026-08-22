#!/usr/bin/env bash
###############################################################################
# nas-mount-check.sh — detect and repair dead CIFS mounts
#
# A CIFS mount can go stale (ESTALE on the mount root) while systemd still
# reports the unit "active (mounted)". Because the unit never stops, the
# .automount never re-triggers and nothing notices: arr imports fail with
# "Stale file handle" and the backup container loops on mkdir errors, both
# silently. This timer closes that gap.
#
# Repair is not just "restart the mount unit". The kernel reuses an existing
# CIFS superblock for a new mount with identical options (cifs_match_super),
# and containers bind-mounting the path keep the stale superblock alive — so
# a remount silently re-adopts the broken one. Consumers must be stopped
# first. All failing shares on a host are repaired in one pass for the same
# reason: shares sharing a session must all release it together.
#
# Deployed via coreos/os-configs/manifest.conf; run by nas-mount-check.timer.
###############################################################################
set -uo pipefail

MOUNTS=(/var/mnt/nas/media /var/mnt/nas/backup /var/mnt/nas/photos)
NAS_HOST=192.168.5.103
STAT_TIMEOUT=15

log() { echo "[nas-mount-check] $*"; }

# Discord helper — no-op if the webhook isn't configured.
# notify.sh probes "$HOME/.discord-webhook.env", and systemd services get no
# HOME, which trips set -u. Give it one before sourcing.
export HOME="${HOME:-/root}"
if [[ -f /srv/scripts/notify.sh ]]; then
  # shellcheck disable=SC1091
  source /srv/scripts/notify.sh
else
  notify() { :; }
fi

# A healthy mount answers stat immediately. ESTALE fails fast; a wedged
# mount hangs, which the timeout turns into a failure too.
mount_ok() {
  timeout "$STAT_TIMEOUT" stat -c '%i' "$1" >/dev/null 2>&1
}

# Containers bind-mounting a path keep its superblock alive.
consumers_of() {
  local path="$1" c
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    if docker inspect "$c" --format '{{range .Mounts}}{{.Source}}
{{end}}' 2>/dev/null | grep -qxF "$path"; then
      echo "$c"
    fi
  done
}

###############################################################################
# 1. Find broken mounts
###############################################################################
BROKEN=()
for m in "${MOUNTS[@]}"; do
  if mount_ok "$m"; then
    continue
  fi
  log "UNHEALTHY: $m — $(timeout "$STAT_TIMEOUT" stat -c '%i' "$m" 2>&1 | tail -1)"
  BROKEN+=("$m")
done

if [[ ${#BROKEN[@]} -eq 0 ]]; then
  log "all mounts healthy"
  exit 0
fi

###############################################################################
# 2. Don't fight a NAS outage — a down server can't be fixed by remounting
###############################################################################
if ! ping -c2 -W2 "$NAS_HOST" >/dev/null 2>&1; then
  log "NAS $NAS_HOST is unreachable — not attempting repair"
  notify critical "NAS unreachable" "${#BROKEN[@]} mount(s) dead and $NAS_HOST does not respond to ping: ${BROKEN[*]}"
  exit 1
fi

###############################################################################
# 3. Stop every consumer of every broken mount, then remount, then restart
###############################################################################
mapfile -t STOP < <(for m in "${BROKEN[@]}"; do consumers_of "$m"; done | sort -u)

log "repairing: ${BROKEN[*]}"
if [[ ${#STOP[@]} -gt 0 ]]; then
  log "stopping consumers: ${STOP[*]}"
  docker stop "${STOP[@]}" >/dev/null 2>&1
fi

for m in "${BROKEN[@]}"; do
  unit=$(systemd-escape -p --suffix=mount "$m")
  systemctl stop "$unit" >/dev/null 2>&1
done
sleep 2
for m in "${BROKEN[@]}"; do
  unit=$(systemd-escape -p --suffix=mount "$m")
  systemctl start "$unit" >/dev/null 2>&1
done
sleep 2

# Restart consumers regardless of the outcome — leaving them stopped would
# turn a recoverable mount fault into an outage of the whole stack.
if [[ ${#STOP[@]} -gt 0 ]]; then
  log "restarting consumers: ${STOP[*]}"
  docker start "${STOP[@]}" >/dev/null 2>&1
fi

###############################################################################
# 4. Report
###############################################################################
STILL_BROKEN=()
for m in "${BROKEN[@]}"; do
  mount_ok "$m" || STILL_BROKEN+=("$m")
done

if [[ ${#STILL_BROKEN[@]} -gt 0 ]]; then
  log "ERROR: still broken after repair: ${STILL_BROKEN[*]}"
  notify critical "NAS mount repair failed" "Still stale after remount: ${STILL_BROKEN[*]}. Check: journalctl -u nas-mount-check.service"
  exit 1
fi

log "repaired: ${BROKEN[*]}"
notify warning "NAS mount repaired" "Remounted ${BROKEN[*]} and restarted ${#STOP[@]} container(s): ${STOP[*]}"
exit 0
