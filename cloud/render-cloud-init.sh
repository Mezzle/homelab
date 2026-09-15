#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${1:-}"
SOURCE="$ROOT_DIR/cloud/$HOST/cloud-init.yaml"
OUTPUT="$ROOT_DIR/cloud/$HOST/cloud-init.rendered.yaml"

if [[ -z "$HOST" || ! -f "$SOURCE" ]]; then
  echo "Usage: $0 <powder|watch>" >&2
  exit 1
fi

if ! command -v op >/dev/null 2>&1; then
  echo "1Password CLI is required to read Homelab/coreos/SSH_PUBKEY" >&2
  exit 1
fi

SSH_PUBKEY="$(op read 'op://Homelab/coreos/SSH_PUBKEY')"
if [[ "$SSH_PUBKEY" != ssh-* ]]; then
  echo "The SSH_PUBKEY value does not look like an OpenSSH public key" >&2
  exit 1
fi

TS_AUTHKEY="$(op read 'op://Homelab/coreos/TS_AUTHKEY')"
if [[ "$TS_AUTHKEY" != tskey-* ]]; then
  echo "The TS_AUTHKEY value does not look like a Tailscale auth key" >&2
  exit 1
fi

SSH_PUBKEY="$SSH_PUBKEY" TS_AUTHKEY="$TS_AUTHKEY" perl -0pe '
  s|ssh-ed25519 CHANGEME mez\@laptop|$ENV{SSH_PUBKEY}|g;
  s|tskey-auth-CHANGEME|$ENV{TS_AUTHKEY}|g;
' \
  "$SOURCE" > "$OUTPUT"
chmod 600 "$OUTPUT"
echo "Wrote $OUTPUT"
echo "The rendered file contains your SSH public key and Tailscale auth key."
echo "It is mode 600 and ignored by Git. Delete it after the instance joins the tailnet."
