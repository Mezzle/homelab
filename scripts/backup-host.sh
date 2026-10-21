#!/usr/bin/env bash
###############################################################################
# backup-host.sh — back up every stack's appdata and databases on this host
#
# Runs nightly from backup.timer (coreos/os-configs/common/). For each stack
# under /srv/docker/<host>/ it writes one tarball of appdata/ into a dated
# directory, dumps databases that live in named volumes or that can't be
# copied consistently while running, prunes old sets, and pings the
# "host-backup (<host>)" Uptime Kuma push monitor so a silent failure alerts.
#
# Destination (BACKUP_DEST, first match wins):
#   1. $BACKUP_DEST from the environment
#   2. /var/mnt/nas/backup/<host>   if the NAS backup share is mounted (pancake)
#   3. /var/backups/homelab/<host>  local fallback (charm)
# The local fallback protects against bad upgrades and accidental deletion,
# not disk loss. Ship it off-host (restic/rclone) when a target is chosen.
#
# Per-stack behaviour:
#   arr      skipped — its own backup container does sqlite-safe backups
#   immich   pg_dumpall from immich-db; appdata/postgres excluded from the tar
#   home     mysqldump --all-databases from the mysql container (named volume)
#   others   tar of appdata/ with the excludes below
# SQLite files in appdata are copied live. They are small and low-write
# here; if one ever matters, add a dump step like the immich one.
#
# Usage:  backup-host.sh            run a backup
#         backup-host.sh --list     show what would be backed up
###############################################################################
set -euo pipefail

HOST=$(hostname -s)
STACKS_DIR="/srv/docker/$HOST"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
DATE=$(date +%Y-%m-%d_%H%M)
TOKEN_MAP="/srv/docker/$HOST/monitoring/heartbeat-tokens.env"
KUMA_PUSH_BASE="${KUMA_PUSH_BASE:-https://watch.${TAILNET:-corgi-justice.ts.net}}"
SKIP_STACKS=(arr)
ERRORS=0

log() { echo "[backup] $(date '+%H:%M:%S') $*"; }

export HOME="${HOME:-/root}"
if [[ -f /srv/scripts/notify.sh ]]; then
  # shellcheck disable=SC1091
  source /srv/scripts/notify.sh
else
  notify() { :; }
fi

# tar excludes, relative to the stack's appdata/ directory
excludes_for() {
  case "$1" in
    immich)  printf '%s\n' './postgres' ;;
    infra)   printf '%s\n' './diun' './portainer/tmp' ;;
    monitoring) printf '%s\n' './adguard/work/data/querylog*' './uptime-kuma/*.db-wal' ;;
    speedtest) printf '%s\n' './log' './www/cache' ;;
    *) ;;
  esac
}

is_skipped() {
  local s
  for s in "${SKIP_STACKS[@]}"; do [[ "$s" == "$1" ]] && return 0; done
  return 1
}

if [[ "${1:-}" == "--list" ]]; then
  for dir in "$STACKS_DIR"/*/; do
    name=$(basename "$dir")
    [[ -f "$dir/docker-compose.yml" ]] || continue
    if is_skipped "$name"; then echo "$name: skipped (own backup)"; continue; fi
    [[ -d "$dir/appdata" ]] && echo "$name: appdata ($(sudo du -sh "$dir/appdata" 2>/dev/null | cut -f1))" || echo "$name: no appdata"
  done
  exit 0
fi

###############################################################################
# Destination
###############################################################################
if [[ -z "${BACKUP_DEST:-}" ]]; then
  # ls triggers the automount; the timeout keeps a dead NAS from hanging us.
  if [[ -d /var/mnt/nas/backup ]] && timeout 15 ls /var/mnt/nas/backup >/dev/null 2>&1; then
    BACKUP_DEST="/var/mnt/nas/backup/$HOST"
  else
    BACKUP_DEST="/var/backups/homelab/$HOST"
  fi
fi
DEST="$BACKUP_DEST/$DATE"
mkdir -p "$DEST"
log "Destination: $DEST"

###############################################################################
# Per-stack backups
###############################################################################
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

dump_immich() {
  container_running immich-db || { log "  SKIP immich-db not running"; return 0; }
  log "  pg_dumpall immich-db"
  if docker exec immich-db sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' | gzip > "$DEST/immich-db.sql.gz"; then
    log "  OK immich-db.sql.gz ($(du -h "$DEST/immich-db.sql.gz" | cut -f1))"
  else
    log "  ERROR pg_dumpall failed"; ERRORS=$((ERRORS + 1))
  fi
}

dump_mysql() {
  container_running mysql || { log "  SKIP mysql not running"; return 0; }
  log "  mysqldump mysql"
  if docker exec mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --all-databases --single-transaction --quick' 2>/dev/null | gzip > "$DEST/mysql.sql.gz"; then
    log "  OK mysql.sql.gz ($(du -h "$DEST/mysql.sql.gz" | cut -f1))"
  else
    log "  ERROR mysqldump failed"; ERRORS=$((ERRORS + 1))
  fi
}

for dir in "$STACKS_DIR"/*/; do
  name=$(basename "$dir")
  [[ -f "$dir/docker-compose.yml" ]] || continue
  if is_skipped "$name"; then log "$name: skipped (has its own backup)"; continue; fi
  log "$name:"

  case "$name" in
    immich) dump_immich ;;
    home)   dump_mysql ;;
  esac

  if [[ -d "$dir/appdata" ]]; then
    exclude_file=$(mktemp)
    excludes_for "$name" > "$exclude_file"
    # Files change under tar for running services; exit 1 (file changed as
    # we read it) is expected and harmless, anything else is an error.
    set +e
    sudo tar -czf "$DEST/$name-appdata.tar.gz" -C "$dir/appdata" --exclude-from="$exclude_file" . 2>/dev/null
    tar_rc=$?
    set -e
    rm -f "$exclude_file"
    if [[ $tar_rc -le 1 ]]; then
      log "  OK $name-appdata.tar.gz ($(du -h "$DEST/$name-appdata.tar.gz" | cut -f1))"
    else
      log "  ERROR tar exited $tar_rc"; ERRORS=$((ERRORS + 1))
    fi
  else
    log "  no appdata directory"
  fi
done

###############################################################################
# Prune, verify, notify
###############################################################################
PRUNED=0
while IFS= read -r old; do
  [[ -z "$old" ]] && continue
  rm -rf "$old"
  PRUNED=$((PRUNED + 1))
done < <(find "$BACKUP_DEST" -mindepth 1 -maxdepth 1 -type d -name '20*' -mtime "+${RETENTION_DAYS}" 2>/dev/null)
[[ $PRUNED -gt 0 ]] && log "Pruned $PRUNED old set(s)"

SET_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
TOTAL_SIZE=$(du -sh "$BACKUP_DEST" 2>/dev/null | cut -f1)
log "Done. This set: $SET_SIZE, all sets: $TOTAL_SIZE, errors: $ERRORS"

# Kuma push: "host-backup" line in the heartbeat token map. Silence alerts.
if [[ -f "$TOKEN_MAP" ]]; then
  token=$(awk -F'\t' '$1=="host-backup"{print $2}' "$TOKEN_MAP")
  if [[ -n "$token" ]]; then
    status=up; [[ $ERRORS -gt 0 ]] && status=down
    curl -fsS -m 10 -o /dev/null "${KUMA_PUSH_BASE}/api/push/${token}?status=${status}&msg=${ERRORS}%20errors%20${SET_SIZE}&ping=" 2>/dev/null \
      || log "WARN: Kuma push failed"
  fi
fi

if [[ $ERRORS -gt 0 ]]; then
  notify critical "Backup completed with errors" "$HOST: $ERRORS error(s) writing $DEST. Check: journalctl -u backup.service"
  exit 1
fi
exit 0
