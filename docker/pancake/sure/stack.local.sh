#!/usr/bin/env bash
set -euo pipefail

case "${1:-help}" in
  backup) docker exec sure-backup /bin/bash /backup.sh ;;
  help)
    cat <<'HELP'

sure commands:
  backup          Run a manual database backup
HELP
    ;;
  *) echo "Unknown command: $1" >&2; exit 1 ;;
esac
