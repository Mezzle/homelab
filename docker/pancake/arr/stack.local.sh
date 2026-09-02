#!/usr/bin/env bash
# arr-specific commands, dispatched from the shared scripts/stack.sh
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-help}" in
  backup)         docker exec backup /bin/bash /backup.sh ;;
  backup-verify)  docker exec backup /bin/bash /backup.sh --verify ;;
  recyclarr-sync) docker exec recyclarr recyclarr sync ;;
  bootstrap)      ./scripts/bootstrap.sh ;;
  bootstrap-dry)  ./scripts/bootstrap.sh --dry ;;
  clean)          docker system prune -f --volumes=false ;;
  help)
    cat <<'HELP'

arr commands:
  backup          Run a manual backup
  backup-verify   Verify the latest backup
  recyclarr-sync  Trigger an immediate Recyclarr sync
  bootstrap       Run first-time auto-configuration
  bootstrap-dry   Preview what bootstrap would configure
  clean           Remove stopped containers and dangling images
HELP
    ;;
  *) echo "Unknown command: $1" >&2; exit 1 ;;
esac
