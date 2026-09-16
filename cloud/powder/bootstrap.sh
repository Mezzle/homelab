#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  echo "Run this script as mez, not root." >&2
  exit 1
fi

log() { printf '[powder-bootstrap] %s\n' "$*"; }

install_op() {
  command -v op >/dev/null 2>&1 && return
  local op_arch tmp_dir
  case "$(uname -m)" in
    aarch64) op_arch=arm64 ;;
    x86_64) op_arch=amd64 ;;
    *) echo "Unsupported architecture for 1Password CLI" >&2; exit 1 ;;
  esac
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN
  curl -fsSL "https://cache.agilebits.com/dist/1P/op2/pkg/v2.30.3/op_linux_${op_arch}_v2.30.3.zip" -o "$tmp_dir/op.zip"
  python3 -c "import zipfile; zipfile.ZipFile('$tmp_dir/op.zip').extract('op', '$tmp_dir')"
  sudo install -m 0755 "$tmp_dir/op" /usr/local/bin/op
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$VERSION_CODENAME" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  sudo usermod -aG docker "$USER"
  sudo systemctl enable --now docker
}

install_chezmoi() {
  if ! command -v chezmoi >/dev/null 2>&1; then
    sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
  fi
  log "Applying Mezzle/dotfiles. Select this as a development machine when prompted."
  chezmoi init --apply Mezzle
}

store_service_account_token() {
  local token_file="$HOME/.config/1password/service-account.env" token
  if [[ -f "$token_file" ]]; then
    return
  fi
  install -d -m 0700 "$HOME/.config/1password"
  read -r -s -p "Paste Powder's read-only 1Password service account token: " token
  printf '\n'
  [[ "$token" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Token format is invalid." >&2; exit 1; }
  umask 077
  printf 'OP_SERVICE_ACCOUNT_TOKEN=%q\n' "$token" > "$token_file"
  unset token
}

install_docker
install_op
store_service_account_token
install_chezmoi
sudo chsh -s /usr/bin/zsh "$USER"

log "Bootstrap complete. Sign out and back in so Docker group membership and zsh apply."
log "Then run cloud/powder/setup-signing-key.sh and the T3 service setup in the runbook."
