#!/usr/bin/env bash
set -euo pipefail

KEY_PATH="${HOME}/.ssh/id_ed25519_powder_signing"
KEY_TITLE="powder commit signing"
KEY_REF="${POWDER_SIGNING_KEY_REF:-op://Homelab/powder-signing-key/private key?ssh-format=openssh}"

install -d -m 0700 "${HOME}/.ssh"

if [[ ! -f "$KEY_PATH" ]]; then
  if command -v op >/dev/null 2>&1 && [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && op read "$KEY_REF" > "$KEY_PATH" 2>/dev/null; then
    echo "Restored signing key from 1Password."
  else
    ssh-keygen -q -t ed25519 -N '' -C "$KEY_TITLE" -f "$KEY_PATH"
    echo "Generated a new signing key. Store the private key in the Homelab vault as an SSH Key item named powder-signing-key, then rerun this script on rebuilds."
  fi
fi
chmod 600 "$KEY_PATH"
if [[ ! -f "${KEY_PATH}.pub" ]]; then
  ssh-keygen -y -f "$KEY_PATH" > "${KEY_PATH}.pub"
fi
chmod 644 "${KEY_PATH}.pub"

git config --global gpg.format ssh
git config --global user.signingkey "${KEY_PATH}.pub"
git config --global commit.gpgsign true

if command -v gh >/dev/null 2>&1; then
  gh ssh-key add "${KEY_PATH}.pub" --type signing --title "$KEY_TITLE" 2>/dev/null \
    || echo "Register ${KEY_PATH}.pub as a signing key in GitHub if it is not already registered."
fi

echo "Signing key configured: ${KEY_PATH}.pub"
