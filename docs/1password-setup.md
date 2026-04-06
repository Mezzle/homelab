# 1Password Secrets Setup

All secrets are stored in a **1Password vault called "Homelab"**. Two systems read from it:

- **`transpile.sh`** reads from the `coreos` item to substitute placeholders in Butane configs
- **`sync-secrets.sh`** reads from per-stack items to populate Docker `.env` files

## Prerequisites

```bash
# Install 1Password CLI
brew install 1password-cli              # macOS
sudo rpm-ostree install 1password-cli   # CoreOS (requires reboot)

# Sign in (laptop — interactive)
op signin

# Or set a service account token (servers — non-interactive)
echo "OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxx" | sudo tee /etc/1password-service-account.env
sudo chmod 600 /etc/1password-service-account.env
```

Create a Service Account at: https://my.1password.com → Developer → Service Accounts
Grant it **read access** to the Homelab vault.

## Items to create

Create each item below in the **Homelab** vault. The item name must match exactly.

---

### `gitops` — Git SSH deploy key

Used by `gitops-sync.sh` to authenticate `git pull` over SSH.

| Field | Example value | Notes |
|---|---|---|
| `SSH_DEPLOY_KEY` | `-----BEGIN OPENSSH PRIVATE KEY-----...` | GitHub deploy key (read-only) |

**Setup:**

1. Generate a dedicated deploy key:
   ```bash
   ssh-keygen -t ed25519 -f /tmp/gitops-deploy -N "" -C "gitops-deploy-key"
   ```
2. Add the **public** key to your GitHub repo → Settings → Deploy Keys (read-only access)
3. Store the **private** key in 1Password:
   ```bash
   op item create --vault Homelab --category "Secure Note" --title "gitops" \
     "SSH_DEPLOY_KEY[note]=$(cat /tmp/gitops-deploy)"
   ```
4. Clean up:
   ```bash
   rm /tmp/gitops-deploy /tmp/gitops-deploy.pub
   ```

```bash
# Verify
op read "op://Homelab/gitops/SSH_DEPLOY_KEY" | head -1
# Should print: -----BEGIN OPENSSH PRIVATE KEY-----
```

---

### `coreos` — OS provisioning

Used by `transpile.sh` to replace CHANGEME placeholders in `.bu` files.

| Field | Example value | Where to get it |
|---|---|---|
| `SSH_PUBKEY` | `ssh-ed25519 AAAA...xyz mez@laptop` | `cat ~/.ssh/id_ed25519.pub` |
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys) |
| `HDD_DISK_ID` | `ata-WDC_WD10JPVX_22JC3T0_WX81E64XXXXX` | `ls -l /dev/disk/by-id/ \| grep -v part` on pancake |

```bash
# Verify
op read "op://Homelab/coreos/SSH_PUBKEY"
op read "op://Homelab/coreos/TS_AUTHKEY"
op read "op://Homelab/coreos/HDD_DISK_ID"
```

---

### `pancake/arr` — Media automation

| Field | Example value | Notes |
|---|---|---|
| `SEEDBOX_HOST` | `sb42.seedbox.io` | Seedbox SSH hostname |
| `SEEDBOX_USER` | `mez` | Seedbox SSH username |
| `SEEDBOX_PORT` | `22` | |
| `SEEDBOX_REMOTE_PATH` | `/home/mez/downloads` | Path on the seedbox |
| `NAS_HOST` | `192.168.1.100` | LAN IP of your NAS |
| `NAS_SHARE` | `media` | SMB share for media files |
| `NAS_BACKUP_SHARE` | `backup` | SMB share for backups |
| `NAS_USER` | `mez` | NAS SMB username |
| `NAS_PASS` | `hunter2` | NAS SMB password |
| `PIA_USER` | `p1234567` | PIA VPN username |
| `PIA_PASS` | `pia-password` | PIA VPN password |
| `PLEX_CLAIM` | *(leave empty)* | Grab fresh from https://plex.tv/claim at deploy time (expires in 4 min) |
| `SONARR_API_KEY` | *(fill after first boot)* | Sonarr UI → Settings → General |
| `RADARR_API_KEY` | *(fill after first boot)* | Radarr UI → Settings → General |
| `DISCORD_WEBHOOK_URL` | `https://discord.com/api/webhooks/...` | Optional. Server Settings → Integrations → Webhooks |
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | [Tailscale admin → Keys](https://login.tailscale.com/admin/settings/keys) |

```bash
# Verify
op item get "pancake/arr" --vault Homelab --fields label=SEEDBOX_HOST,label=NAS_HOST,label=PIA_USER,label=TS_AUTHKEY
```

---

### `pancake/immich` — Photo management

| Field | Example value | Notes |
|---|---|---|
| `IMMICH_VERSION` | `release` | Or pin: `v2.6.3` |
| `NAS_HOST` | `192.168.1.100` | |
| `NAS_PHOTOS_SHARE` | `photos` | SMB share for photos |
| `NAS_PHOTOS_USER` | `immich` | |
| `NAS_PHOTOS_PASS` | `nas-password` | |
| `DB_DATA_LOCATION` | `./appdata/postgres` | Local path for Postgres data |
| `DB_USERNAME` | `postgres` | |
| `DB_PASSWORD` | `aR4nd0mStr1ng` | **Alphanumeric only** (A-Za-z0-9) |
| `DB_DATABASE_NAME` | `immich` | |
| `IMMICH_TRANSCODING_BACKEND` | `nvenc` | `nvenc` for NVIDIA, `cpu` otherwise |
| `IMMICH_ML_BACKEND` | `cuda` | `cuda` for NVIDIA, `cpu` otherwise |
| `IMMICH_ML_IMAGE_SUFFIX` | `-cuda` | `-cuda`, `-openvino`, or blank for cpu |
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "pancake/immich" --vault Homelab --fields label=DB_PASSWORD,label=NAS_HOST,label=TS_AUTHKEY
```

---

### `pancake/music` — Music Assistant

| Field | Example value | Notes |
|---|---|---|
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "pancake/music" --vault Homelab --fields label=TS_AUTHKEY
```

---

### `pancake/infra` — Homepage + Portainer + Diun

| Field | Example value | Notes |
|---|---|---|
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |
| `TAILNET` | `tail1234` | Your tailnet name (before `.ts.net`) |
| `SONARR_API_KEY` | *(fill after first boot)* | Sonarr UI → Settings → General |
| `RADARR_API_KEY` | *(fill after first boot)* | Radarr UI → Settings → General |
| `PROWLARR_API_KEY` | *(fill after first boot)* | Prowlarr UI → Settings → General |
| `PLEX_TOKEN` | `abc123...` | [Finding your Plex token](https://support.plex.tv/articles/204059436/) |
| `IMMICH_API_KEY` | *(fill after first boot)* | Immich → User Settings → API Keys |
| `ADGUARD_USER` | `admin` | charm's AdGuard replica |
| `ADGUARD_PASS` | `password` | |

```bash
# Verify
op item get "pancake/infra" --vault Homelab --fields label=TS_AUTHKEY,label=TAILNET,label=SONARR_API_KEY
```

---

### `charm/infra` — Portainer agent

| Field | Example value | Notes |
|---|---|---|
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "charm/infra" --vault Homelab --fields label=TS_AUTHKEY
```

---

### `charm/home` — MQTT, Zigbee, MySQL

| Field | Example value | Notes |
|---|---|---|
| `MQTT_USER` | `homeassistant` | Mosquitto username |
| `MQTT_PASS` | `mqttP4ssw0rd` | Mosquitto password |
| `MYSQL_ROOT_PASSWORD` | `r00tP4ssw0rd` | Random string |
| `MYSQL_DATABASE` | `homeassistant` | |
| `MYSQL_USER` | `homeassistant` | |
| `MYSQL_PASSWORD` | `haP4ssw0rd` | Random string |
| `Z2M_ADAPTER_HOST` | `192.168.1.50` | IP of your Zigbee coordinator |
| `Z2M_ADAPTER_PORT` | `6638` | |
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "charm/home" --vault Homelab --fields label=MQTT_USER,label=MYSQL_ROOT_PASSWORD,label=Z2M_ADAPTER_HOST,label=TS_AUTHKEY
```

---

### `charm/monitoring` — AdGuard backup DNS

| Field | Example value | Notes |
|---|---|---|
| `ADGUARD_PRIMARY_URL` | `http://192.168.1.5:3000` | Pi-hosted primary AdGuard instance |
| `ADGUARD_PRIMARY_USER` | `admin` | |
| `ADGUARD_PRIMARY_PASS` | `adguard-password` | |
| `ADGUARD_REPLICA_USER` | `admin` | |
| `ADGUARD_REPLICA_PASS` | `replica-password` | |
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "charm/monitoring" --vault Homelab --fields label=ADGUARD_PRIMARY_URL,label=TS_AUTHKEY
```

---

### `powder/infra` — Portainer agent

| Field | Example value | Notes |
|---|---|---|
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "powder/infra" --vault Homelab --fields label=TS_AUTHKEY
```

---

### `powder/monitoring` — External monitoring (Oracle Cloud)

| Field | Example value | Notes |
|---|---|---|
| `TS_AUTHKEY` | `tskey-auth-kG4F9a...` | |

```bash
# Verify
op item get "powder/monitoring" --vault Homelab --fields label=TS_AUTHKEY
```

---

## Verify everything at once

Run this to check all items exist and have the expected fields:

```bash
#!/usr/bin/env bash
# Quick check that all 1Password items are configured
set -euo pipefail

VAULT="Homelab"
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

check() {
  local item="$1"
  shift
  echo "Checking: $item"
  for field in "$@"; do
    if value=$(op read "op://$VAULT/$item/$field" 2>/dev/null) && [[ -n "$value" ]]; then
      echo -e "  ${GREEN}OK${NC}  $field"
    else
      echo -e "  ${RED}MISSING${NC}  $field"
    fi
  done
}

check "gitops" SSH_DEPLOY_KEY

check "coreos" SSH_PUBKEY TS_AUTHKEY HDD_DISK_ID

check "pancake/arr" SEEDBOX_HOST SEEDBOX_USER SEEDBOX_PORT SEEDBOX_REMOTE_PATH \
  NAS_HOST NAS_SHARE NAS_BACKUP_SHARE NAS_USER NAS_PASS \
  PIA_USER PIA_PASS TS_AUTHKEY

check "pancake/immich" IMMICH_VERSION NAS_HOST NAS_PHOTOS_SHARE NAS_PHOTOS_USER \
  NAS_PHOTOS_PASS DB_DATA_LOCATION DB_USERNAME DB_PASSWORD DB_DATABASE_NAME \
  IMMICH_TRANSCODING_BACKEND IMMICH_ML_BACKEND IMMICH_ML_IMAGE_SUFFIX TS_AUTHKEY

check "pancake/music" TS_AUTHKEY
check "pancake/infra" TS_AUTHKEY TAILNET SONARR_API_KEY RADARR_API_KEY \
  PROWLARR_API_KEY PLEX_TOKEN IMMICH_API_KEY ADGUARD_USER ADGUARD_PASS
check "charm/infra" TS_AUTHKEY

check "charm/home" MQTT_USER MQTT_PASS MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD \
  Z2M_ADAPTER_HOST Z2M_ADAPTER_PORT TS_AUTHKEY

check "charm/monitoring" ADGUARD_PRIMARY_URL ADGUARD_PRIMARY_USER ADGUARD_PRIMARY_PASS \
  ADGUARD_REPLICA_USER ADGUARD_REPLICA_PASS TS_AUTHKEY

check "powder/infra" TS_AUTHKEY
check "powder/monitoring" TS_AUTHKEY

echo ""
echo "Done. Fix any MISSING fields above, then run:"
echo "  ./scripts/sync-secrets.sh        # sync Docker .env files"
echo "  cd coreos && ./transpile.sh      # transpile Butane configs"
```

## Notes

- **TS_AUTHKEY** appears in every item. Use a single reusable + ephemeral key tagged with an ACL tag and paste it everywhere. When you rotate it, update all items.
- **PLEX_CLAIM** expires 4 minutes after generation. Don't store it — grab a fresh one from https://plex.tv/claim right before first boot.
- **SONARR_API_KEY / RADARR_API_KEY** aren't available until after first boot. Start the arr stack once, grab the keys from each app's UI, then update 1Password.
- **DB_PASSWORD** for Immich must be alphanumeric only (no special characters) due to Postgres connection string parsing.
- **Secrets sync automatically** during gitops-sync. When you add a new secret to 1Password, the next sync pulls it into `.env` before restarting stacks.
- Tailscale key docs: https://tailscale.com/kb/1085/auth-keys
- 1Password CLI reference: https://developer.1password.com/docs/cli/reference
- 1Password secret references: https://developer.1password.com/docs/cli/secret-references
