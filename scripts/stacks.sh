#!/usr/bin/env bash
###############################################################################
# stacks.sh — run a stack.sh command across every stack on this host
#
# Each docker/<host>/ directory has a stacks.sh symlink pointing here.
# Stacks are the subdirectories that contain a docker-compose.yml.
###############################################################################
set -euo pipefail
cd "$(dirname "$0")"

STACKS=()
for f in */docker-compose.yml; do
  [[ -f "$f" ]] && STACKS+=("$(dirname "$f")")
done

each() {
  local verb="$1" cmd="$2" s
  for s in "${STACKS[@]}"; do
    echo "=== $verb $s ==="
    ./"$s"/stack.sh "$cmd"
  done
}

case "${1:-help}" in
  up-all)      each Starting up ;;
  down-all)    each Stopping down ;;
  restart-all) each Restarting restart ;;
  update-all)  each Updating update ;;
  clean)       docker system prune -f --volumes=false ;;
  status)      docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sort ;;
  help|*)
    cat <<HELP
Usage: ./stacks.sh <command>

  up-all          Start all stacks
  down-all        Stop all stacks
  restart-all     Restart all stacks
  update-all      Pull and recreate all stacks
  clean           Remove stopped containers, unused networks and dangling images
                  now (never volumes). docker-prune.timer prunes week-old
                  images every Sunday.
  status          Show all container status
  help            Show this help

Stacks: ${STACKS[*]}
HELP
    ;;
esac
