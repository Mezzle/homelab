#!/usr/bin/env bash
set -euo pipefail

case "${1:-help}" in
  backup) docker exec mealie-backup /bin/bash /backup.sh ;;
  help)
    cat <<'HELP'

mealie commands:
  backup          Run a manual backup
HELP
    ;;
  *) echo "Unknown command: $1" >&2; exit 1 ;;
esac
