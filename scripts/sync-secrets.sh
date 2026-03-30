#!/usr/bin/env bash
###############################################################################
# sync-secrets.sh — Pull secrets from 1Password into .env files
#
# Uses a 1Password Service Account to read secrets from a "Homelab" vault
# and populate .env files for each stack.
#
# Prerequisites:
#   - 1Password CLI (op) installed
#   - Service account token in /etc/1password-service-account.env
#   - Secrets stored in 1Password vault "Homelab" with items named to match
#     stack paths (e.g., "pancake/arr")
#
# Usage:
#   ./scripts/sync-secrets.sh                    # sync all stacks
#   ./scripts/sync-secrets.sh docker/pancake/arr   # sync one stack
###############################################################################
set -euo pipefail

REPO_DIR="/srv"
VAULT="Homelab"
TOKEN_FILE="/etc/1password-service-account.env"

# Colours
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "[sync-secrets] $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}~${NC} $*"; }
skip() { echo -e "  ${RED}-${NC} $*"; }

# Load service account token — validate format before sourcing
if [[ -f "$TOKEN_FILE" ]]; then
  if ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$TOKEN_FILE"; then
    log "ERROR: $TOKEN_FILE has unexpected format. Expected: OP_SERVICE_ACCOUNT_TOKEN=<token>"
    exit 1
  fi
  source "$TOKEN_FILE"
  export OP_SERVICE_ACCOUNT_TOKEN
elif [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  : # Already set in environment
else
  log "ERROR: No 1Password service account token found."
  log "  Create $TOKEN_FILE with: OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxx"
  exit 1
fi

# Verify op CLI is available
if ! command -v op &>/dev/null; then
  log "ERROR: 1Password CLI (op) not found."
  log "  Install: sudo rpm-ostree install 1password-cli && sudo systemctl reboot"
  exit 1
fi

# Verify authentication
if ! op vault get "$VAULT" --format json >/dev/null 2>&1; then
  log "ERROR: Cannot access vault '$VAULT'. Check your service account token."
  exit 1
fi

###############################################################################
# Helper: safely update a key=value in a file without sed injection
###############################################################################
set_env_value() {
  local file="$1" key="$2" value="$3"
  local tmpfile
  tmpfile=$(mktemp)

  if grep -q "^${key}=" "$file" 2>/dev/null; then
    # Replace existing line — use awk to avoid sed metacharacter issues
    awk -v k="$key" -v v="$value" 'BEGIN{FS=OFS="="} $1==k{print k,v;next}{print}' "$file" > "$tmpfile"
    mv "$tmpfile" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

###############################################################################
# Sync function
###############################################################################
sync_stack() {
  local stack_dir="$1"
  local stack_name="$2"

  [[ -f "$stack_dir/.env.example" ]] || return

  local env_file="$stack_dir/.env"
  local updated=0
  local skipped=0

  # Ensure .env exists with restricted permissions
  touch "$env_file"
  chmod 600 "$env_file"

  log "Syncing: $stack_name"

  while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    # Extract key name (everything before first =)
    local key="${line%%=*}"
    [[ -z "$key" ]] && continue

    # Try to read from 1Password
    local value
    value=$(op read "op://$VAULT/$stack_name/$key" 2>/dev/null || echo "")

    if [[ -n "$value" ]]; then
      set_env_value "$env_file" "$key" "$value"
      ok "$key"
      ((updated++))
    else
      skip "$key (not found in 1Password)"
      ((skipped++))
    fi
  done < "$stack_dir/.env.example"

  log "  $updated updated, $skipped not found"
}

###############################################################################
# Main
###############################################################################

# Detect server directory — must be explicitly set
SERVER_DIR="${GITOPS_SERVER_DIR:-}"

if [[ $# -gt 0 ]]; then
  # Sync specific stack
  STACK_PATH="$1"
  STACK_DIR="$REPO_DIR/$STACK_PATH"
  if [[ -d "$STACK_DIR" ]]; then
    sync_stack "$STACK_DIR" "$STACK_PATH"
  else
    log "ERROR: Stack not found: $STACK_DIR"
    exit 1
  fi
else
  # Sync all stacks for this server
  if [[ -z "$SERVER_DIR" ]]; then
    log "ERROR: Could not determine server directory. Set GITOPS_SERVER_DIR."
    exit 1
  fi

  log "Syncing all stacks in $SERVER_DIR..."
  for stack_dir in "$REPO_DIR/$SERVER_DIR"/*/; do
    [[ -f "$stack_dir/.env.example" ]] || continue
    stack_name="$SERVER_DIR/$(basename "$stack_dir")"
    sync_stack "$stack_dir" "$stack_name"
  done
fi

log "Done"
