#!/usr/bin/env bash
set -euo pipefail

log() { printf '[powder-update] %s\n' "$*"; }

log "Updating Ubuntu packages"
sudo apt-get update
sudo apt-get upgrade -y

log "Updating dotfiles and Mise tools"
chezmoi update
mise upgrade

log "Updating the T3 background service"
npx t3@latest service update
npx t3@latest service status

if [[ -f /var/run/reboot-required ]]; then
  log "A reboot is required. It has not been performed."
fi
