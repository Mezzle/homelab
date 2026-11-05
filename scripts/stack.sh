#!/usr/bin/env bash
set -euo pipefail

# This script is invoked through docker/<host>/<stack>/stack.sh symlinks, so
# $0 (not BASH_SOURCE) identifies the stack directory.
cd "$(dirname "$0")"

case "${1:-help}" in
  up)       docker compose up -d ;;
  down)     docker compose down ;;
  restart)  docker compose restart ${2:-} ;;
  pull)     docker compose pull ;;
  update)   docker compose pull && docker compose up -d --remove-orphans ;;
  logs)     docker compose logs -f --tail=100 ${2:-} ;;
  status)   docker compose ps ;;
  health)   docker compose ps --format json ;;
  help)
    cat <<'HELP'
Usage: ./stack.sh <command> [service]

  up              Start all services
  down            Stop all services
  restart [svc]   Restart all services (or one service)
  pull            Pull images
  update          Pull and recreate changed containers
  logs [svc]      Tail logs (or one service)
  status          Show this stack's containers
  health          Show this stack's container state as JSON
  help            Show this help
HELP
    [[ -x ./stack.local.sh ]] && ./stack.local.sh help
    ;;
  *)
    if [[ -x ./stack.local.sh ]]; then
      ./stack.local.sh "$@"
    else
      echo "Unknown command: $1" >&2
      exit 1
    fi
    ;;
esac
