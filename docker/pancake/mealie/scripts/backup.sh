#!/usr/bin/env bash
###############################################################################
# backup.sh — Back up Mealie's data directory to the NAS
#
# Runs inside the mealie-backup container (on start, then every 24h). It can
# also be triggered manually: docker exec mealie-backup /bin/bash /backup.sh
#
# Takes a live-safe sqlite3 .backup of mealie.db and tars it with the rest of
# /app/data (recipe images and other assets).
#
# Restore:
#   docker compose stop mealie
#   docker run --rm -v mealie_data:/data -v /var/mnt/nas/backup:/nas:ro alpine \
#     sh -c 'rm -rf /data/* && tar -xzf /nas/backups/mealie/mealie-<date>.tar.gz -C /data'
#   docker compose start mealie
#
# Environment (set in docker-compose.yml):
#   BACKUP_RETENTION_DAYS — days to keep backups (default: 14)
###############################################################################
set -euo pipefail

BACKUP_DIR="/nas/backups/mealie"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
TARBALL="$BACKUP_DIR/mealie-$(date +%Y-%m-%d_%H%M).tar.gz"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

log() { echo "[backup] $(date '+%H:%M:%S') $*"; }

if [[ ! -f /data/mealie.db ]]; then
  log "ERROR: /data/mealie.db not found"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

# Copy everything except the live database files, then add a consistent
# snapshot of the database in their place.
tar -cf - -C /data . | tar -xf - -C "$STAGING"
rm -f "$STAGING"/mealie.db*
sqlite3 /data/mealie.db ".backup '$STAGING/mealie.db'"

if ! tar -czf "$TARBALL.tmp" -C "$STAGING" .; then
  rm -f "$TARBALL.tmp"
  log "ERROR: tar failed"
  exit 1
fi
mv "$TARBALL.tmp" "$TARBALL"
log "Wrote $TARBALL ($(du -h "$TARBALL" | cut -f1))"

find "$BACKUP_DIR" -name "mealie-*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -delete
