#!/usr/bin/env bash
###############################################################################
# seed-uptime-kuma.sh — wrapper for the Python seed script
#
# Uptime Kuma uses Socket.IO, not REST, so we need the Python API client.
#
# Usage:
#   pip install uptime-kuma-api
#   UPK_USER=admin UPK_PASS=password TAILNET=tail1234 ./scripts/seed-uptime-kuma.sh
#
# Or call the Python script directly:
#   python scripts/seed-uptime-kuma.py
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

if [[ ! -d "$VENV_DIR" ]]; then
  echo "Creating virtualenv at $VENV_DIR..."
  python3 -m venv "$VENV_DIR"
fi

# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

if ! python3 -c "import uptime_kuma_api" 2>/dev/null; then
  echo "Installing uptime-kuma-api..."
  pip3 install --quiet uptime-kuma-api
fi

exec python3 "$SCRIPT_DIR/seed-uptime-kuma.py" "$@"
