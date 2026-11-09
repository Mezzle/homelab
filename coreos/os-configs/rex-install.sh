#!/usr/bin/env bash
# Called by GitOps as root. Pass --update to explicitly upgrade Rex.
set -euo pipefail

case "${1:-}" in
  ""|--update) ;;
  *) echo "Usage: $0 [--update]" >&2; exit 2 ;;
esac

id mez >/dev/null
if [[ ! -x /usr/local/bin/rex || "${1:-}" == --update ]]; then
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl --fail --silent --show-error --location \
    https://pkgs.superlogical.com/rex/install.sh -o "$installer"
  # Binary-only works on immutable uCore as well as Ubuntu, on x86 and ARM.
  # Preview is intentional: Rex has no stable Linux release yet.
  sh "$installer" --tarball --channel preview
fi

# /usr/local is writable on uCore; restore its SELinux labels after installation.
if command -v restorecon >/dev/null 2>&1; then
  restorecon /usr/local/bin/rex /etc/rex /etc/rex/accounts.jsonc \
    /etc/pam.d/rex-login-server /etc/systemd/system/rex.service
fi
/usr/local/bin/rex version
systemctl daemon-reload
systemctl enable rex.service
# Apply service changes too; this runs only when a Rex manifest file changes.
systemctl restart rex.service

# Dedicated HTTPS port preserves the host's existing Serve routes.
tailscale serve --bg --https=7297 unix:/run/rex-mez/serve.sock
