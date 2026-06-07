#!/usr/bin/env bash
###############################################################################
# validate-compose.sh — Validate Docker Compose files without starting services
#
# Usage:
#   ./scripts/validate-compose.sh                    # validate every stack
#   ./scripts/validate-compose.sh docker/pancake/arr # validate one stack
###############################################################################
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILED=()

validate_stack() {
  local stack_dir="$1"
  local rel_path="${stack_dir#"$REPO_DIR"/}"

  if [[ ! -f "$stack_dir/docker-compose.yml" ]]; then
    echo "[validate-compose] SKIP: $rel_path has no docker-compose.yml"
    return 0
  fi

  echo "[validate-compose] Validating: $rel_path"
  local compose_args=()
  if [[ ! -f "$stack_dir/.env" && -f "$stack_dir/.env.example" ]]; then
    compose_args+=(--env-file .env.example)
  fi

  if (cd "$stack_dir" && docker compose "${compose_args[@]}" config --quiet); then
    echo "[validate-compose] OK: $rel_path"
  else
    echo "[validate-compose] ERROR: $rel_path"
    FAILED+=("$rel_path")
  fi
}

if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    validate_stack "$REPO_DIR/${arg%/}"
  done
else
  while IFS= read -r compose_file; do
    validate_stack "$(dirname "$compose_file")"
  done < <(find "$REPO_DIR/docker" -mindepth 3 -maxdepth 3 -name docker-compose.yml -type f | sort)
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "[validate-compose] Failed stack(s): ${FAILED[*]}"
  exit 1
fi

echo "[validate-compose] All compose files valid"
