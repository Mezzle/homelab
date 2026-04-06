#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

STACKS=(infra monitoring)

case "${1:-help}" in
  up-all)
    for s in "${STACKS[@]}"; do echo "=== Starting $s ===" && ./"$s"/stack.sh up; done ;;
  down-all)
    for s in "${STACKS[@]}"; do echo "=== Stopping $s ===" && ./"$s"/stack.sh down; done ;;
  restart-all)
    for s in "${STACKS[@]}"; do echo "=== Restarting $s ===" && ./"$s"/stack.sh restart; done ;;
  update-all)
    for s in "${STACKS[@]}"; do echo "=== Updating $s ===" && ./"$s"/stack.sh update; done ;;
  status)
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort ;;
  help|*)
    cat <<'EOF'
Usage: ./stacks.sh <command>

  up-all          Start all stacks
  down-all        Stop all stacks
  restart-all     Restart all stacks
  update-all      Pull and recreate all stacks
  status          Show all container status
  help            Show this help
EOF
    ;;
esac
