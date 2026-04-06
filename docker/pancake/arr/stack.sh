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
  status)   docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort ;;
  health)   docker ps --format "{{.Names}}\t{{.Status}}" | grep -E "(healthy|unhealthy|starting)" | sort ;;
  backup)   docker exec backup /bin/bash /backup.sh ;;
  recyclarr-sync) docker exec recyclarr recyclarr sync ;;
  bootstrap)      ./scripts/bootstrap.sh ;;
  bootstrap-dry)  ./scripts/bootstrap.sh --dry ;;
  clean)    docker system prune -f --volumes=false ;;
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
  health          Show only health status
  backup          Run a manual backup
  recyclarr-sync  Trigger an immediate Recyclarr sync
  bootstrap       Run first-time auto-configuration
  bootstrap-dry   Preview what bootstrap would configure
  clean           Remove stopped containers and dangling images
  help            Show this help
EOF
    ;;
esac
