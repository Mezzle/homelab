# 1Password secrets

All secrets are in the 1Password vault **Homelab**. Two things read it:

- `coreos/transpile.sh` reads the `coreos` item to substitute placeholders in Butane configs.
- `scripts/sync-secrets.sh` reads one item per stack to populate that stack's `.env`.

## Item naming

Stack items are named after the stack path with dots: `docker.pancake.arr`, `docker.charm.home`. This is what `sync-secrets.sh` computes from the directory; `op://Homelab/docker.pancake.arr/PIA_USER` is the reference form. Fields are the keys in the stack's `.env.example`. Keys missing from 1Password are left alone in `.env`, so optional values can stay unset.

Keep non-secret configuration out of 1Password. A `${VAR:-default}` in the compose file is visible in git; a field in a vault is not.

## Prerequisites

```bash
brew install 1password-cli        # laptop
op signin

# servers: a service account token, installed by scripts/bootstrap.sh into
echo "OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxx" | sudo tee /etc/1password-service-account.env
sudo chmod 600 /etc/1password-service-account.env
```

The `op` binary on servers is downloaded by `bootstrap.sh` into `/usr/local/bin`, where systemd can find it.

Create the service account at https://my.1password.com → Developer → Service Accounts, with read access to Homelab.

## Items

### `gitops`

| Field | Notes |
|---|---|
| `SSH_DEPLOY_KEY` | private half of a read-only GitHub deploy key, used by `gitops-sync.sh` for `git pull` |

```bash
ssh-keygen -t ed25519 -f /tmp/gitops-deploy -N "" -C "gitops-deploy-key"
# add /tmp/gitops-deploy.pub to GitHub → Settings → Deploy keys (read-only)
op item create --vault Homelab --category "Secure Note" --title "gitops" \
  "SSH_DEPLOY_KEY[note]=$(cat /tmp/gitops-deploy)"
rm /tmp/gitops-deploy /tmp/gitops-deploy.pub
```

### `coreos`

| Field | Where to get it |
|---|---|
| `SSH_PUBKEY` | `cat ~/.ssh/id_ed25519.pub` |
| `TS_AUTHKEY` | Tailscale admin → Keys, reusable + ephemeral, tagged |
| `HDD_DISK_ID` | `ls -l /dev/disk/by-id/ \| grep -v part` on pancake |

### `docker.pancake.arr`

| Field | Notes |
|---|---|
| `SEEDBOX_HOST`, `SEEDBOX_USER`, `SEEDBOX_PORT`, `SEEDBOX_REMOTE_PATH` | rclone SFTP mount |
| `PIA_USER`, `PIA_PASS`, `PIA_REGION` | gluetun |
| `PLEX_CLAIM` | leave empty; grab a fresh one at https://plex.tv/claim right before first boot, it expires in 4 minutes |
| `SONARR_API_KEY`, `RADARR_API_KEY` | after first boot, from each app's Settings → General; used by Recyclarr |
| `DISCORD_WEBHOOK_URL` | optional, backup notifications |

NAS credentials are not here. They are host files, `/etc/nas-arr.credentials` and `/etc/nas-photos.credentials`, read by the systemd CIFS mounts in `coreos/pancake.bu`.

### `docker.pancake.immich`

| Field | Notes |
|---|---|
| `DB_PASSWORD` | alphanumeric only |
| `DB_USERNAME`, `DB_DATABASE_NAME`, `DB_DATA_LOCATION` | defaults in compose are fine |
| `IMMICH_TRANSCODING_BACKEND`, `IMMICH_ML_BACKEND`, `IMMICH_ML_IMAGE_SUFFIX` | `nvenc` / `cuda` / `-cuda` on pancake |

`IMMICH_VERSION` is pinned in the compose file, not here.

### `docker.pancake.infra`

| Field | Notes |
|---|---|
| `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET` | OAuth client with Services write, for DockTail |
| `TAILNET` | tailnet name before `.ts.net` |
| `SONARR_API_KEY`, `RADARR_API_KEY`, `PROWLARR_API_KEY`, `PLEX_TOKEN`, `IMMICH_API_KEY`, `PORTAINER_API_KEY` | Homepage widgets |
| `ADGUARD_USER`, `ADGUARD_PASS` | Homepage AdGuard widget |

### `docker.pancake.speedtest`

| Field | Notes |
|---|---|
| `APP_KEY` | `echo "base64:$(openssl rand -base64 32)"` |

### `docker.pancake.music`

No secrets.

### `docker.pancake.sure`

| Field | Notes |
|---|---|
| `SECRET_KEY_BASE` | Generate with `openssl rand -hex 64` |
| `POSTGRES_PASSWORD` | Generate with `openssl rand -hex 24`; keep fixed after database initialization |

### `docker.charm.infra`

| Field | Notes |
|---|---|
| `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET` | DockTail |

### `docker.charm.home`

| Field | Notes |
|---|---|
| `MQTT_USER`, `MQTT_PASS` | Mosquitto |
| `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` | Home Assistant recorder |
| `Z2M_ADAPTER_HOST`, `Z2M_ADAPTER_PORT` | Zigbee coordinator (z2m is currently commented out) |

### `docker.charm.monitoring`

| Field | Notes |
|---|---|
| `ADGUARD_PRIMARY_URL`, `ADGUARD_PRIMARY_USER`, `ADGUARD_PRIMARY_PASS` | the Pi |
| `ADGUARD_REPLICA_USER`, `ADGUARD_REPLICA_PASS` | this instance |

### `docker.watch.monitoring`

No stack-local secrets. Tailscale Serve publishes its loopback-only port.

## Verify

```bash
#!/usr/bin/env bash
set -euo pipefail
VAULT=Homelab
check() {
  local item="$1"; shift
  echo "Checking: $item"
  for field in "$@"; do
    if value=$(op read "op://$VAULT/$item/$field" 2>/dev/null) && [[ -n "$value" ]]; then
      echo "  OK       $field"
    else
      echo "  MISSING  $field"
    fi
  done
}
check gitops SSH_DEPLOY_KEY
check coreos SSH_PUBKEY TS_AUTHKEY HDD_DISK_ID
check docker.pancake.arr SEEDBOX_HOST SEEDBOX_USER SEEDBOX_PORT SEEDBOX_REMOTE_PATH PIA_USER PIA_PASS
check docker.pancake.immich DB_PASSWORD IMMICH_TRANSCODING_BACKEND IMMICH_ML_BACKEND IMMICH_ML_IMAGE_SUFFIX
check docker.pancake.infra TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET TAILNET
check docker.pancake.speedtest APP_KEY
check docker.pancake.sure SECRET_KEY_BASE POSTGRES_PASSWORD
check docker.charm.infra TAILSCALE_OAUTH_CLIENT_ID TAILSCALE_OAUTH_CLIENT_SECRET
check docker.charm.home MQTT_USER MQTT_PASS MYSQL_ROOT_PASSWORD MYSQL_PASSWORD
check docker.charm.monitoring ADGUARD_PRIMARY_URL ADGUARD_PRIMARY_USER ADGUARD_PRIMARY_PASS ADGUARD_REPLICA_USER ADGUARD_REPLICA_PASS
```

## Notes

- Secrets sync during every gitops run, before stacks restart, so a new field is in `.env` before compose reads it.
- `sync-secrets.sh` never deletes a key from `.env`. To remove one, edit the host's `.env` by hand.
- Tailscale key docs: https://tailscale.com/kb/1085/auth-keys
- 1Password secret references: https://developer.1password.com/docs/cli/secret-references
