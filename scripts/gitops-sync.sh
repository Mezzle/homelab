#!/usr/bin/env bash
###############################################################################
# gitops-sync.sh — Pull from git and apply changes automatically
#
# Called by the gitops-sync.timer systemd unit every 5 minutes.
# Requires GITOPS_SERVER_DIR to be set (in the systemd unit) to identify
# which server's stacks to manage.
#
# What it does:
#   1. git pull the repo
#   2. Sync secrets from 1Password → .env files
#   3. For each stack that changed → docker compose up -d
#   4. If OS config files changed → apply + reload
#   5. Logs everything to journald
###############################################################################
set -euo pipefail

REPO_DIR="/srv"
LOCK_FILE="/tmp/gitops-sync.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN_FILE="/etc/1password-service-account.env"
VAULT="Homelab"
OP_ITEM="gitops"

log() { echo "[gitops-sync] $*"; }

# Load Discord notification helper if available
if [[ -f "$SCRIPT_DIR/notify.sh" ]]; then
  source "$SCRIPT_DIR/notify.sh"
else
  notify() { :; }  # no-op if helper not available
fi

# Prevent concurrent runs
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  log "Another sync is already running, skipping"
  exit 0
fi

cd "$REPO_DIR"

if [[ ! -d .git ]]; then
  log "ERROR: $REPO_DIR is not a git repository"
  exit 1
fi

###############################################################################
# Determine which server this is
###############################################################################
# Every host must set GITOPS_SERVER_DIR in its gitops-sync.service unit.
if [[ -z "${GITOPS_SERVER_DIR:-}" ]]; then
  log "ERROR: GITOPS_SERVER_DIR is not set. Configure it in the gitops-sync.service systemd unit."
  exit 1
fi
SERVER_DIR="$GITOPS_SERVER_DIR"

if [[ ! -d "$REPO_DIR/$SERVER_DIR" ]]; then
  log "ERROR: Server directory $REPO_DIR/$SERVER_DIR does not exist"
  exit 1
fi

log "Server: $SERVER_DIR (host: $(hostname -s))"

###############################################################################
# SSH identity from 1Password
###############################################################################
# Fetch the deploy key from 1Password so git pull can authenticate.
# The key lives in a tmpfile that is cleaned up on exit.
SSH_KEY_FILE=""
cleanup() { [[ -n "$SSH_KEY_FILE" ]] && rm -f "$SSH_KEY_FILE"; }
trap cleanup EXIT

setup_git_ssh() {
  # Load 1Password service account token
  if [[ -f "$TOKEN_FILE" ]]; then
    if ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=[a-zA-Z0-9_-]+$' "$TOKEN_FILE"; then
      log "ERROR: $TOKEN_FILE has unexpected format"
      return 1
    fi
    source "$TOKEN_FILE"
    export OP_SERVICE_ACCOUNT_TOKEN
  elif [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    log "WARNING: No 1Password token — using system SSH config for git"
    return 0
  fi

  if ! command -v op &>/dev/null; then
    log "WARNING: 1Password CLI (op) not found — using system SSH config for git"
    return 0
  fi

  SSH_KEY_FILE=$(mktemp /tmp/gitops-ssh-XXXXXX)
  chmod 600 "$SSH_KEY_FILE"

  if ! op read "op://$VAULT/$OP_ITEM/SSH_DEPLOY_KEY" > "$SSH_KEY_FILE" 2>/dev/null; then
    rm -f "$SSH_KEY_FILE"
    SSH_KEY_FILE=""
    log "WARNING: Could not read deploy key from 1Password ($VAULT/$OP_ITEM/SSH_DEPLOY_KEY) — using system SSH config"
    return 0
  fi

  export GIT_SSH_COMMAND="ssh -i $SSH_KEY_FILE -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  log "Using SSH deploy key from 1Password"
}

setup_git_ssh

###############################################################################
# Step 1: Pull changes
###############################################################################
BEFORE=$(git rev-parse HEAD)

git fetch --quiet origin
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse @{u})

if [[ "$LOCAL" == "$REMOTE" ]]; then
  log "Already up to date ($LOCAL)"
  exit 0
fi

log "Changes detected: $LOCAL → $REMOTE"
git pull --quiet --ff-only origin

AFTER=$(git rev-parse HEAD)
CHANGED_FILES=$(git diff --name-only "$BEFORE" "$AFTER")
log "Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  /'

###############################################################################
# Step 2: Sync secrets from 1Password
###############################################################################
# Pull latest secrets into .env files before restarting stacks, so new
# env vars added in the pull are populated before docker compose reads them.
if [[ -f "$SCRIPT_DIR/sync-secrets.sh" ]]; then
  log "Syncing secrets from 1Password..."
  if ! "$SCRIPT_DIR/sync-secrets.sh" 2>&1; then
    log "WARNING: Secret sync failed — continuing with existing .env files"
  fi
else
  log "WARNING: sync-secrets.sh not found — skipping secret sync"
fi

###############################################################################
# Step 3: Apply Docker stack changes
###############################################################################
# Find all stacks for this server that have changes
STACKS_TO_UPDATE=()

for stack_dir in "$REPO_DIR/$SERVER_DIR"/*/; do
  [[ -f "$stack_dir/docker-compose.yml" ]] || continue
  stack_name=$(basename "$stack_dir")
  rel_path="$SERVER_DIR/$stack_name"

  # Check if any files in this stack changed
  if echo "$CHANGED_FILES" | grep -q "^$rel_path/"; then
    STACKS_TO_UPDATE+=("$stack_dir")
    log "Stack changed: $stack_name"
  fi
done

FAILED_STACKS=()
for stack_dir in "${STACKS_TO_UPDATE[@]}"; do
  stack_name=$(basename "$stack_dir")
  log "Updating stack: $stack_name"
  (
    cd "$stack_dir"
    docker compose pull --quiet 2>&1 | grep -v "up to date" || true
    docker compose up -d --remove-orphans 2>&1
  )
  if [[ $? -ne 0 ]]; then
    log "ERROR: Stack failed: $stack_name"
    FAILED_STACKS+=("$stack_name")
  else
    log "Stack updated: $stack_name"
  fi
done

if [[ ${#FAILED_STACKS[@]} -gt 0 ]]; then
  log "WARNING: ${#FAILED_STACKS[@]} stack(s) failed to update: ${FAILED_STACKS[*]}"
fi

if [[ ${#STACKS_TO_UPDATE[@]} -eq 0 ]]; then
  log "No stack changes for $SERVER_DIR"
fi

###############################################################################
# Step 4: Apply OS config changes
#
# Reads coreos/os-configs/manifest.conf for file mappings.
# Shared files (no directory prefix) apply to all servers.
# Per-server files (e.g. pancake/motd.sh) apply only to that host.
###############################################################################
HOSTNAME=$(hostname -s)
MANIFEST="$REPO_DIR/coreos/os-configs/manifest.conf"
OS_CONFIGS_DIR="$REPO_DIR/coreos/os-configs"
declare -A RELOAD_ACTIONS

apply_os_file() {
  local src="$1" dest="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || return 1
  if [[ -f "$dest" ]] && diff -q "$src" "$dest" >/dev/null 2>&1; then
    return 1
  fi
  log "Updating OS config: $dest"
  sudo install -D -m "$mode" "$src" "$dest"
}

if [[ -f "$MANIFEST" ]] && echo "$CHANGED_FILES" | grep -q "^coreos/os-configs/"; then
  while read -r src dest mode action; do
    # Skip comments and blank lines
    [[ -z "$src" || "$src" == \#* ]] && continue

    # Per-server files: only apply if the prefix matches this hostname
    src_dir=$(dirname "$src")
    if [[ "$src_dir" != "." ]]; then
      [[ "$src_dir" != "$HOSTNAME" ]] && continue
    fi

    # Only process files that actually changed
    if ! echo "$CHANGED_FILES" | grep -q "^coreos/os-configs/$src$"; then
      continue
    fi

    if apply_os_file "$OS_CONFIGS_DIR/$src" "$dest" "${mode:-0644}"; then
      [[ -n "${action:-}" ]] && RELOAD_ACTIONS["$action"]=1
    fi
  done < "$MANIFEST"

  # Run reload actions
  [[ -n "${RELOAD_ACTIONS[sysctl]:-}" ]] && { log "Reloading sysctl..."; sudo sysctl --system --quiet && log "  sysctl OK" || log "  ERROR: sysctl reload failed"; }
  [[ -n "${RELOAD_ACTIONS[docker]:-}" ]] && { log "Reloading Docker..."; sudo systemctl reload docker && log "  docker OK" || log "  ERROR: docker reload failed"; }
  [[ -n "${RELOAD_ACTIONS[sshd]:-}" ]]   && { log "Reloading SSH..."; sudo systemctl reload sshd && log "  sshd OK" || log "  ERROR: sshd reload failed"; }
fi

log "Sync complete: $BEFORE → $AFTER"

# Notify on failure only — successful syncs are silent
if [[ ${#FAILED_STACKS[@]} -gt 0 ]]; then
  notify critical "GitOps sync failed" "${#FAILED_STACKS[@]} stack(s) failed: ${FAILED_STACKS[*]}. Check: journalctl -u gitops-sync.service"
  exit 1
fi
exit 0
