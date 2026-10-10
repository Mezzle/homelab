#!/usr/bin/env bash
###############################################################################
# backup.sh — Dump the Sure Postgres database to the NAS
#
# Runs inside the sure-backup container (on start, then every 24h). It can
# also be triggered manually: docker exec sure-backup /bin/bash /backup.sh
#
# Restore:
#   gunzip -c sure-<date>.sql.gz | docker exec -i sure-db \
#     psql -U sure_user -d sure_production
#
# Environment (set in docker-compose.yml):
#   BACKUP_RETENTION_DAYS — days to keep backups (default: 14)
###############################################################################
set -euo pipefail

BACKUP_DIR="/nas/backups/sure"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
DUMP="$BACKUP_DIR/sure-$(date +%Y-%m-%d_%H%M).sql.gz"

log() { echo "[backup] $(date '+%H:%M:%S') $*"; }

mkdir -p "$BACKUP_DIR"

if ! PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h db -U "$POSTGRES_USER" --clean --if-exists "$POSTGRES_DB" | gzip > "$DUMP.tmp"; then
  rm -f "$DUMP.tmp"
  log "ERROR: pg_dump failed"
  exit 1
fi
mv "$DUMP.tmp" "$DUMP"
log "Wrote $DUMP ($(du -h "$DUMP" | cut -f1))"

find "$BACKUP_DIR" -name "sure-*.sql.gz" -type f -mtime +"$RETENTION_DAYS" -delete
