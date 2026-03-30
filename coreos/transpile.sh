#!/usr/bin/env bash
###############################################################################
# transpile.sh — Convert Butane YAML to Ignition JSON
#
# Pulls secrets from 1Password and substitutes them into .bu files before
# running butane. The .bu files stay publishable with CHANGEME placeholders;
# real values only appear in the generated .ign files (which are gitignored).
#
# Usage:
#   ./transpile.sh                          # transpile all .bu files
#   ./transpile.sh pancake.bu               # transpile a specific file
#
# Prerequisites:
#   - butane (https://coreos.github.io/butane/)
#       brew install butane                     # macOS
#       sudo dnf install butane                 # Fedora
#   - 1Password CLI (https://developer.1password.com/docs/cli/get-started/)
#       brew install 1password-cli              # macOS
#   - Secrets stored in 1Password vault "Homelab", item "coreos":
#       SSH_PUBKEY   — your full SSH public key (e.g. ssh-ed25519 AAAA... user@host)
#       TS_AUTHKEY   — Tailscale auth key (https://login.tailscale.com/admin/settings/keys)
#       HDD_DISK_ID  — 1TB HDD disk ID for pancake (find with: ls -l /dev/disk/by-id/)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OP_VAULT="Homelab"
OP_ITEM="coreos"

###############################################################################
# Load secrets from 1Password
###############################################################################
declare -A SUBS

if command -v op &>/dev/null; then
  echo "Loading secrets from 1Password (vault: $OP_VAULT, item: $OP_ITEM)..."

  read_secret() {
    local field="$1"
    local value
    value=$(op read "op://$OP_VAULT/$OP_ITEM/$field" 2>/dev/null) || {
      echo "  WARNING: Could not read $field from 1Password"
      return 1
    }
    echo "$value"
  }

  if value=$(read_secret "SSH_PUBKEY"); then
    SUBS["ssh-ed25519 CHANGEME mez@laptop"]="$value"
  fi

  if value=$(read_secret "TS_AUTHKEY"); then
    SUBS["tskey-auth-CHANGEME"]="$value"
  fi

  if value=$(read_secret "HDD_DISK_ID"); then
    SUBS["CHANGEME-1TB-HDD-ID"]="$value"
  fi

  echo "  ${#SUBS[@]} substitution(s) loaded"
else
  echo "WARNING: 1Password CLI (op) not found — transpiling with placeholder values."
  echo "  Install: brew install 1password-cli"
  echo "  Docs:    https://developer.1password.com/docs/cli/get-started/"
  echo ""
fi

###############################################################################
# Apply substitutions to a .bu file, returning the processed content
###############################################################################
apply_secrets() {
  local content
  content=$(cat "$1")

  for placeholder in "${!SUBS[@]}"; do
    content="${content//"$placeholder"/"${SUBS[$placeholder]}"}"
  done

  echo "$content"
}

###############################################################################
# Transpile a single .bu file
###############################################################################
transpile() {
  local src="$1"
  local dest="${src%.bu}.ign"

  echo "Transpiling: $src → $dest"

  if command -v butane &>/dev/null; then
    apply_secrets "$src" | butane --pretty --strict -d . > "$dest"
  else
    echo "  butane not found locally, using Docker..."
    apply_secrets "$src" | docker run --rm -i quay.io/coreos/butane:release \
      --pretty --strict > "$dest"
  fi

  echo "  ✓ $(wc -c < "$dest" | tr -d ' ') bytes written"
}

if [[ $# -gt 0 ]]; then
  transpile "$1"
else
  for bu_file in *.bu; do
    [[ -f "$bu_file" ]] || continue
    transpile "$bu_file"
  done
fi

echo ""
echo "Done. To install Fedora CoreOS with this config:"
echo "  coreos-installer install /dev/sdX --ignition-file <name>.ign"
echo ""
echo "Or to test in a VM:"
echo "  coreos-installer download --platform qemu"
echo "  qemu-system-x86_64 -m 2048 -fw_cfg name=opt/com.coreos/config,file=<name>.ign ..."
