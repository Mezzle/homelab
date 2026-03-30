#!/usr/bin/env bash
###############################################################################
# bootstrap.sh — Post-Ignition setup for Fedora CoreOS (uCore) servers
#
# Run this once after first boot + uCore rebase is complete.
# SSH in via Tailscale (host-level TS is configured by Ignition).
#
# What it does:
#   1. Installs 1Password CLI (binary — not in Fedora repos)
#   2. Sets up the 1Password service account token
#   3. Clones the git repo to /srv
#   4. Syncs secrets from 1Password into .env files
#   5. Starts all Docker stacks
#
# Usage:
#   ssh mez@<hostname>
#   curl -sL <raw-url>/scripts/bootstrap.sh | bash -s -- <server-dir>
#
# Or after cloning the repo:
#   ./scripts/bootstrap.sh docker/powder
#
# Prerequisites:
#   - uCore rebase complete (both unsigned + signed stages)
#   - Tailscale connected (SSH in via tailnet)
#   - GitHub deploy key added to the repo
###############################################################################
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn() { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
fail() { echo -e "${RED}[bootstrap]${NC} $*"; exit 1; }

REPO_URL="git@github.com:mezzle/homelab.git"
REPO_DIR="/srv"
TOKEN_FILE="/etc/1password-service-account.env"

###############################################################################
# Parse args
###############################################################################
SERVER_DIR="${1:-}"
if [[ -z "$SERVER_DIR" ]]; then
  fail "Usage: $0 <server-dir>  (e.g., docker/powder)"
fi

###############################################################################
# Step 1: Install 1Password CLI
###############################################################################
if command -v op &>/dev/null; then
  log "1Password CLI already installed: $(op --version)"
else
  log "Installing 1Password CLI..."

  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  OP_ARCH="amd64" ;;
    aarch64) OP_ARCH="arm64" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
  esac

  TMPDIR=$(mktemp -d)
  trap "rm -rf $TMPDIR" EXIT

  curl -sSL "https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.3/op_linux_${OP_ARCH}_v2.30.3.zip" \
    -o "$TMPDIR/op.zip"

  # uCore may not have unzip — use Python
  python3 -c "import zipfile; zipfile.ZipFile('$TMPDIR/op.zip').extract('op', '$TMPDIR')"
  chmod +x "$TMPDIR/op"
  sudo mv "$TMPDIR/op" /usr/local/bin/op

  log "1Password CLI installed: $(op --version)"
fi

###############################################################################
# Step 2: Set up 1Password service account token
###############################################################################
if [[ -f "$TOKEN_FILE" ]]; then
  log "1Password token file already exists: $TOKEN_FILE"
else
  log "Setting up 1Password service account token..."
  echo ""
  warn "Create a service account at: https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount"
  warn "Grant it read access to the 'Homelab' vault."
  echo ""
  read -rp "Paste the service account token (ops_...): " TOKEN

  if [[ ! "$TOKEN" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    fail "Token looks invalid. Expected alphanumeric string."
  fi

  echo "OP_SERVICE_ACCOUNT_TOKEN=$TOKEN" | sudo tee "$TOKEN_FILE" > /dev/null
  sudo chmod 644 "$TOKEN_FILE"
  log "Token saved to $TOKEN_FILE"
fi

###############################################################################
# Step 3: Clone the repo
###############################################################################
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Repo already cloned at $REPO_DIR"
  cd "$REPO_DIR"
  for key in ~/.ssh/deploy_key ~/.ssh/id_ed25519; do
    if [[ -f "$key" ]]; then
      export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes"
      break
    fi
  done
  git pull --ff-only || warn "git pull failed — continuing with existing state"
else
  log "Cloning repo to $REPO_DIR..."
  warn "Make sure a deploy key is added to the GitHub repo."
  warn "Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/deploy_key -N ''"
  echo ""

  # Find the SSH deploy key
  DEPLOY_KEY=""
  for key in ~/.ssh/deploy_key ~/.ssh/id_ed25519; do
    if [[ -f "$key" ]]; then
      DEPLOY_KEY="$key"
      break
    fi
  done

  if [[ -z "$DEPLOY_KEY" ]]; then
    warn "No SSH key found. You may need to set one up first."
    warn "Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/deploy_key -N ''"
    read -rp "Press Enter to continue or Ctrl+C to abort..."
  fi

  if [[ -n "$DEPLOY_KEY" ]]; then
    GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
      git clone "$REPO_URL" "$REPO_DIR"
  else
    git clone "$REPO_URL" "$REPO_DIR"
  fi
  log "Repo cloned"
fi

###############################################################################
# Step 4: Sync secrets
###############################################################################
log "Syncing secrets for $SERVER_DIR..."
for stack_dir in "$REPO_DIR/$SERVER_DIR"/*/; do
  [[ -f "$stack_dir/.env.example" ]] || continue
  stack_name="$SERVER_DIR/$(basename "$stack_dir")"
  "$REPO_DIR/scripts/sync-secrets.sh" "$stack_name" || warn "$stack_name secrets sync had issues"
done

###############################################################################
# Step 5: Start stacks
###############################################################################
log "Starting Docker stacks..."
for stack_dir in "$REPO_DIR/$SERVER_DIR"/*/; do
  [[ -f "$stack_dir/docker-compose.yml" ]] || continue
  stack_name=$(basename "$stack_dir")
  log "Starting $stack_name..."
  docker compose -f "$stack_dir/docker-compose.yml" up -d --remove-orphans || warn "$stack_name failed to start"
done

log ""
log "Bootstrap complete! Verify with:"
log "  docker ps"
