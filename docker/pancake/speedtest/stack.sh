#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-help}" in
  up)       docker compose up -d ;;
  down)     docker compose down ;;
  restart)  docker compose restart ${2:-} ;;
  pull)     docker compose pull ;;
  update)   docker compose pull && docker compose up -d --remove-orphans ;;
  logs)     docker compose logs -f --tail=100 ${2:-} ;;
  status)   docker ps --filter "label=com.docker.compose.project=speedtest" --format "table {{.Names}}\t{{.Status}}" | sort ;;
  help|*)
    cat <<'EOF'
Usage: ./stack.sh <command> [service]

  up              Start all services
  down            Stop all services
  restart [svc]   Restart all services (or a specific one)
  pull            Pull latest images
  update          Pull latest images and recreate changed containers
  logs [svc]      Tail logs (or a specific service)
  status          Show container status
  help            Show this help
EOF
    ;;
esac
