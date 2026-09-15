#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run this script as the development user, not root." >&2
  exit 1
fi

log() { printf '[powder-bootstrap] %s\n' "$*"; }

install_op() {
  if command -v op >/dev/null 2>&1; then
    log "1Password CLI is already installed"
    return
  fi
  case "$(uname -m)" in
    aarch64) op_arch=arm64 ;;
    x86_64) op_arch=amd64 ;;
    *) echo "Unsupported architecture for 1Password CLI" >&2; exit 1 ;;
  esac
  tmp_dir="$(mktemp -d)"
  curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.3/op_linux_${op_arch}_v2.30.3.zip" \
    -o "$tmp_dir/op.zip"
  python3 -c "import zipfile; zipfile.ZipFile('$tmp_dir/op.zip').extract('op', '$tmp_dir')"
  sudo install -m 0755 "$tmp_dir/op" /usr/local/bin/op
  rm -rf "$tmp_dir"
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker is already installed"
    sudo usermod -aG docker "$USER"
    return
  fi

  log "Installing Docker Engine"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  . /etc/os-release
  arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$arch" "$VERSION_CODENAME" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale is already installed"
  else
    log "Installing Tailscale"
    curl -fsSL https://tailscale.com/install.sh | sh
  fi

  if ! tailscale status >/dev/null 2>&1; then
    log "Authenticate this host in the browser"
    sudo tailscale up --hostname=powder --ssh
  fi
}

install_mise_and_tools() {
  if [[ ! -x "$HOME/.local/bin/mise" ]]; then
    log "Installing mise"
    curl -fsSL https://mise.run | sh
  fi

  export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
  grep -Fq 'mise activate bash --shims' "$HOME/.profile" 2>/dev/null \
    || printf '\neval "$(~/.local/bin/mise activate bash --shims)"\n' >> "$HOME/.profile"
  grep -Fq 'mise activate bash"' "$HOME/.bashrc" 2>/dev/null \
    || printf '\neval "$(~/.local/bin/mise activate bash)"\n' >> "$HOME/.bashrc"

  log "Installing Node.js 24"
  "$HOME/.local/bin/mise" use --global node@24
  "$HOME/.local/bin/mise" reshim

  log "Installing Codex, Claude Code, and T3 Code"
  npm install --global @openai/codex @anthropic-ai/claude-code t3
}

install_docker
install_tailscale
install_op
install_mise_and_tools

sudo install -D -m 0644 "$(dirname "$0")/../../systemd/powder/docker-prune.service" \
  /etc/systemd/system/docker-prune.service
sudo install -D -m 0644 "$(dirname "$0")/../../systemd/powder/docker-prune.timer" \
  /etc/systemd/system/docker-prune.timer
sudo systemctl daemon-reload
sudo systemctl enable --now docker-prune.timer

log "Installed versions"
node --version
npm --version
codex --version
claude --version
t3 --version
log "Sign out and back in once so Docker group membership takes effect."
log "Then add powder in T3 Code with Settings > Connections > Remote Environments > SSH."
log "JetBrains Gateway can use the same SSH target and a project under /workspaces."
