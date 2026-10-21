#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run this script as mez, not root." >&2
  exit 1
fi

REPO_URL="${REPO_URL:-git@github.com:mezzle/homelab.git}"
REPO_DIR="${REPO_DIR:-/srv}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { printf '[watch-bootstrap] %s\n' "$*"; }

install_op() {
  if command -v op >/dev/null 2>&1; then
    return
  fi
  tmp_dir="$(mktemp -d)"
  curl -fsSL https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.3/op_linux_amd64_v2.30.3.zip \
    -o "$tmp_dir/op.zip"
  python3 -c "import zipfile; zipfile.ZipFile('$tmp_dir/op.zip').extract('op', '$tmp_dir')"
  sudo install -m 0755 "$tmp_dir/op" /usr/local/bin/op
  rm -rf "$tmp_dir"
}

configure_gitops_credentials() {
  token_file=/etc/1password-service-account.env
  if [[ ! -f "$token_file" ]]; then
    read -rsp "1Password Homelab service-account token: " token
    echo
    [[ "$token" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "Invalid token format" >&2; exit 1; }
    printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$token" \
      | sudo tee "$token_file" >/dev/null
    sudo chown root:mez "$token_file"
    sudo chmod 640 "$token_file"
  fi
  # shellcheck disable=SC1090
  source "$token_file"
  export OP_SERVICE_ACCOUNT_TOKEN
}

install_op
configure_gitops_credentials

if ! command -v tailscale >/dev/null 2>&1; then
  log "Installing Tailscale"
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if ! tailscale status >/dev/null 2>&1; then
  sudo tailscale up --hostname=watch --ssh
fi

if [[ "$ROOT_DIR" != "$REPO_DIR" ]]; then
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    sudo install -d -o "$USER" -g "$USER" -m 0755 "$REPO_DIR"
    deploy_key="$(mktemp)"
    trap 'rm -f "$deploy_key"' EXIT
    op read 'op://Homelab/gitops/SSH_DEPLOY_KEY' > "$deploy_key"
    chmod 600 "$deploy_key"
    GIT_SSH_COMMAND="ssh -i $deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
      git clone "$REPO_URL" "$REPO_DIR"
    rm -f "$deploy_key"
    trap - EXIT
  fi
  ROOT_DIR="$REPO_DIR"
fi

sudo install -D -m 0644 "$ROOT_DIR/systemd/watch/monitoring-stack.service" \
  /etc/systemd/system/monitoring-stack.service
sudo install -D -m 0644 "$ROOT_DIR/systemd/watch/gitops-sync.service" \
  /etc/systemd/system/gitops-sync.service
sudo install -D -m 0644 "$ROOT_DIR/systemd/watch/gitops-sync.timer" \
  /etc/systemd/system/gitops-sync.timer
sudo systemctl daemon-reload
sudo systemctl enable --now monitoring-stack.service gitops-sync.timer

sudo tailscale serve --bg --https=443 http://127.0.0.1:3001

log "watch is running. Restore the Kuma backup before retiring powder."
log "Open https://watch.$(tailscale status --json | jq -r '.MagicDNSSuffix')/"
