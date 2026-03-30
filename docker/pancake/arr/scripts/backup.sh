#!/usr/bin/env bash
###############################################################################
# backup.sh — Safely back up arr stack databases and configs to NAS
#
# Uses sqlite3 .backup for safe live database snapshots (no corruption risk).
# Creates a dated tarball on the NAS mount and prunes old backups.
#
# This script runs inside the backup container via cron. It can also be
# triggered manually: docker exec backup /bin/bash /backup.sh
#
# Modes:
#   /backup.sh           — run backup (default, called by cron)
#   /backup.sh --verify  — verify the latest backup (monthly cron)
#
# Environment (set in docker-compose.yml):
#   BACKUP_RETENTION_DAYS — days to keep backups (default: 7)
#   DISCORD_WEBHOOK_URL   — Discord webhook for notifications (optional)
###############################################################################
set -euo pipefail

BACKUP_DIR="/nas/backups/arr"
STAGING_DIR="/tmp/backup-staging"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
DATE=$(date +%Y-%m-%d_%H%M)
TARBALL="arr-backup-${DATE}.tar.gz"
ERRORS=0

log() { echo "[backup] $(date '+%H:%M:%S') $*"; }

# Discord notification helper (inline — can't source host scripts from container)
notify() {
  local level="$1" title="$2" message="${3:-}"
  local webhook_url="${DISCORD_WEBHOOK_URL:-}"
  [[ -z "$webhook_url" ]] && return 0
  local color
  case "$level" in
    critical) color=16711680 ;; warning) color=16776960 ;;
    success)  color=65280 ;;    *)       color=3447003 ;;
  esac
  curl -sf -H "Content-Type: application/json" -d "{
    \"embeds\": [{
      \"title\": \"${title}\",
      \"description\": \"${message}\",
      \"color\": ${color},
      \"footer\": {\"text\": \"arr-backup\"},
      \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
    }]
  }" "$webhook_url" >/dev/null 2>&1 || true
}

###############################################################################
# Verify mode — test that the latest backup is restorable
###############################################################################
if [[ "${1:-}" == "--verify" ]]; then
  log "=== Backup verification ==="
  LATEST=$(find "$BACKUP_DIR" -name "arr-backup-*.tar.gz" -type f 2>/dev/null | sort | tail -1)

  if [[ -z "$LATEST" ]]; then
    log "ERROR: No backups found in $BACKUP_DIR"
    notify critical "Backup verification failed" "No backup files found in $BACKUP_DIR"
    exit 1
  fi

  VERIFY_DIR="/tmp/backup-verify"
  rm -rf "$VERIFY_DIR"
  mkdir -p "$VERIFY_DIR"

  log "Verifying: $(basename "$LATEST")"

  # Extract
  if ! tar -xzf "$LATEST" -C "$VERIFY_DIR"; then
    log "ERROR: Failed to extract $LATEST"
    notify critical "Backup verification failed" "Could not extract $(basename "$LATEST")"
    rm -rf "$VERIFY_DIR"
    exit 1
  fi

  # Verify each SQLite database
  VERIFY_OK=true
  for db_file in "$VERIFY_DIR"/*.db; do
    [[ -f "$db_file" ]] || continue
    db_name=$(basename "$db_file")
    if sqlite3 "$db_file" "PRAGMA integrity_check;" | grep -q "^ok$"; then
      log "  OK: $db_name (integrity check passed)"
    else
      log "  FAIL: $db_name (integrity check FAILED)"
      VERIFY_OK=false
    fi
    # Verify we can read tables
    TABLE_COUNT=$(sqlite3 "$db_file" ".tables" 2>/dev/null | wc -w)
    log "  OK: $db_name ($TABLE_COUNT tables readable)"
  done

  rm -rf "$VERIFY_DIR"

  if $VERIFY_OK; then
    BACKUP_AGE=$(( ($(date +%s) - $(stat -c %Y "$LATEST" 2>/dev/null || stat -f %m "$LATEST")) / 86400 ))
    log "Verification passed. Latest backup is ${BACKUP_AGE} day(s) old."
    notify success "Backup verification passed" "$(basename "$LATEST") — all databases intact, ${BACKUP_AGE}d old"
  else
    log "ERROR: Verification FAILED — some databases are corrupt"
    notify critical "Backup verification FAILED" "One or more databases in $(basename "$LATEST") failed integrity check"
    exit 1
  fi
  exit 0
fi

###############################################################################
# Back up SQLite databases safely
###############################################################################
mkdir -p "$BACKUP_DIR" "$STAGING_DIR"

backup_db() {
  local name="$1" db_path="$2"
  local dest="$STAGING_DIR/${name}.db"

  if [[ ! -f "$db_path" ]]; then
    log "SKIP: $name database not found at $db_path"
    return 0
  fi

  log "Backing up $name database..."
  if sqlite3 "$db_path" ".backup '$dest'"; then
    log "  OK: $name ($(du -h "$dest" | cut -f1))"
  else
    log "  WARN: $name backup failed (database may be locked), copying raw file"
    cp "$db_path" "$dest"
    ((ERRORS++))
  fi
}

###############################################################################
# Back up config files
###############################################################################
backup_config() {
  local name="$1" config_path="$2"
  local dest="$STAGING_DIR/${name}-config"

  if [[ ! -d "$config_path" && ! -f "$config_path" ]]; then
    log "SKIP: $name config not found at $config_path"
    return 0
  fi

  log "Backing up $name config..."
  mkdir -p "$dest"

  if [[ -d "$config_path" ]]; then
    find "$config_path" -maxdepth 2 \( -name "*.xml" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" -o -name "*.conf" \) \
      -exec cp --parents {} "$dest/" \; 2>/dev/null || true
  else
    cp "$config_path" "$dest/"
  fi
}

###############################################################################
# Run backups
###############################################################################
log "Starting backup (retention: ${RETENTION_DAYS} days)..."

backup_db "sonarr" "/appdata/sonarr/sonarr.db"
backup_config "sonarr" "/appdata/sonarr"

backup_db "radarr" "/appdata/radarr/radarr.db"
backup_config "radarr" "/appdata/radarr"

backup_db "prowlarr" "/appdata/prowlarr/prowlarr.db"
backup_config "prowlarr" "/appdata/prowlarr"

backup_db "bazarr" "/appdata/bazarr/db/bazarr.db"
backup_config "bazarr" "/appdata/bazarr"

backup_config "plex" "/appdata/plex"

###############################################################################
# Create tarball
###############################################################################
log "Compressing to $TARBALL..."
tar -czf "$BACKUP_DIR/$TARBALL" -C "$STAGING_DIR" .
TARBALL_SIZE=$(du -h "$BACKUP_DIR/$TARBALL" | cut -f1)
log "Created $TARBALL ($TARBALL_SIZE)"

###############################################################################
# Cleanup staging
###############################################################################
rm -rf "$STAGING_DIR"

###############################################################################
# Prune old backups
###############################################################################
PRUNED=0
while IFS= read -r old_backup; do
  [[ -z "$old_backup" ]] && continue
  rm -f "$old_backup"
  ((PRUNED++))
done < <(find "$BACKUP_DIR" -name "arr-backup-*.tar.gz" -mtime "+${RETENTION_DAYS}" 2>/dev/null)

[[ $PRUNED -gt 0 ]] && log "Pruned $PRUNED old backup(s)"

TOTAL=$(find "$BACKUP_DIR" -name "arr-backup-*.tar.gz" 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
log "Done. $TOTAL backup(s) on disk ($TOTAL_SIZE total)"

###############################################################################
# Notify
###############################################################################
if [[ $ERRORS -gt 0 ]]; then
  notify warning "Backup completed with warnings" "$TARBALL ($TARBALL_SIZE) — $ERRORS database(s) used raw copy instead of sqlite3 .backup"
else
  notify success "Backup complete" "$TARBALL ($TARBALL_SIZE) — $TOTAL backups on disk ($TOTAL_SIZE)"
fi
