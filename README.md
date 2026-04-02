# Homelab

Infrastructure-as-code for a multi-machine homelab running [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS + Docker + NVIDIA + Tailscale) with GitOps deployment.

## Architecture

```
┌─────────────────────────────────────────────┐  ┌──────────────────────────────┐
│  pancake (laptop)                           │  │  charm (mac mini)            │
│  i7-5700HQ · 16GB · GTX 970M               │  │  i5-4260U · 4GB              │
│                                             │  │                              │
│  ┌─────────┐ ┌────────┐ ┌───────┐          │  │  ┌───────────┐ ┌──────────┐  │
│  │   arr   │ │ immich │ │ music │          │  │  │   home    │ │monitoring│  │
│  │ Plex    │ │ Photos │ │ Music │ ┌──────┐ │  │  │ Mosquitto │ │ AdGuard  │  │
│  │ Sonarr  │ │ ML/GPU │ │ Asst  │ │infra │ │  │  │ Scrypted  │ │ AG Sync  │  │
│  │ Radarr  │ │ Pgvec  │ │       │ │Dockge│ │  │  │ Z2M       │ │          │  │
│  │ Prowlarr│ │ Redis  │ │       │ │ Diun │ │  │  │ MySQL     │ │          │  │
│  │ +more   │ │        │ │       │ │      │ │  │  │           │ │          │  │
│  └─────────┘ └────────┘ └───────┘ └──────┘ │  │  └───────────┘ └──────────┘  │
│                                             │  │                              │
│  SSD: OS + Docker + appdata                 │  │  SSD: everything (480GB)     │
│  HDD: media, photos, rclone cache           │  │                              │
└─────────────────────────────────────────────┘  └──────────────────────────────┘
         │                                                │
         └──────────────── Tailscale mesh ────────────────┘
                                │
         ┌──────────────────────┼──────────────────────┐
         │                      │                      │
   ┌───────────┐  ┌──────────────────────────┐  ┌──────────┐
   │  powder   │  │         Other            │  │ Clients  │
   │  (OCI)    │  │                          │  │ phones,  │
   │  Ampere   │  │  Dell — Home Assistant   │  │ laptops  │
   │  A1 ARM   │  │  Pi — AdGuard (primary)  │  │          │
   │           │  │                          │  │          │
   │ Uptime    │  └──────────────────────────┘  └──────────┘
   │  Kuma     │
   │ Alert-    │
   │  manager  │
   └───────────┘
     Oracle Cloud
     Always Free
```

## Directory structure

```
├── coreos/                          # OS provisioning
│   ├── pancake.bu              #   Laptop — Butane config
│   ├── charm.bu               #   Mac Mini — Butane config
│   ├── powder.bu              #   Oracle Cloud ARM — Butane config
│   ├── os-configs/                  #   Live-updatable OS configs
│   │   ├── sysctl-90-arr-tuning.conf
│   │   ├── docker-daemon.json
│   │   └── sshd-50-hardening.conf
│   └── transpile.sh                 #   .bu → .ign converter
├── docker/                          # Docker Compose stacks
│   ├── pancake/                #   Laptop stacks
│   │   ├── arr/                     #     Media automation
│   │   ├── immich/                  #     Photo management
│   │   ├── music/                   #     Music Assistant
│   │   └── infra/                   #     Homepage + Dockge + Diun
│   ├── charm/                 #   Mac Mini stacks
│   │   ├── infra/                   #     Dockge agent
│   │   ├── home/                    #     MQTT, cameras, Zigbee, MySQL
│   │   └── monitoring/              #     AdGuard + AG Sync
│   └── powder/                #   Oracle Cloud stacks
│       ├── infra/                   #     Dockge agent
│       └── monitoring/              #     Uptime Kuma + Alertmanager
├── docs/
│   ├── 1password-setup.md           #   Secrets reference & verification
│   └── powder-setup.md              #   Oracle Cloud deployment guide
├── scripts/
│   ├── gitops-sync.sh               #   Auto-pull + apply from git
│   ├── sync-secrets.sh              #   1Password → .env sync
│   └── notify.sh                    #   Discord notification helper
└── README.md
```

Each stack follows the same pattern:

```
stack-name/
├── docker-compose.yml        # The stack definition
├── .env.example              # Template for secrets (committed)
├── .env                      # Actual secrets (git-ignored)
├── Makefile                  # make up/down/logs/status/etc
├── appdata/                  # Container data (git-ignored)
├── config/                   # Config files (committed)
│   └── tailscale/            # Tailscale serve configs
└── scripts/                  # Stack-specific scripts
```

## Quick start

### Initial setup (one-time per machine)

```bash
# 1. On your laptop, transpile the Butane config
cd coreos
./transpile.sh pancake.bu    # or charm.bu, powder.bu

# 2. Install Fedora CoreOS on the target machine
coreos-installer install /dev/sda --ignition-file pancake.ign

# 3. Reboot, then SSH in
ssh mez@<ip>

# 4. Clone this repo
cd /srv
git clone <repo-url> .

# 5. Configure secrets for each stack
cd docker/pancake/arr && cp .env.example .env && vim .env
cd ../immich && cp .env.example .env && vim .env
# ... repeat for each stack

# 6. Start everything
make -C docker/pancake/arr up
make -C docker/pancake/immich up
# ... or use the systemd services (they auto-start on boot)
```

### Day-to-day operations

```bash
# On the server
make -C docker/pancake/arr status     # Check a stack
make -C docker/pancake/arr logs s=sonarr  # Tail specific service logs

# From your laptop (push-to-deploy)
vim docker/pancake/arr/docker-compose.yml  # Edit
git add -A && git commit && git push     # Push
# → gitops-sync picks it up within 5 minutes
```

## Adding a new stack

You do NOT need to update Butane configs or systemd units. Just:

### 1. Create the stack directory

```bash
mkdir -p docker/pancake/my-new-stack/{appdata,config}
```

### 2. Create the compose file

```yaml
# docker/pancake/my-new-stack/docker-compose.yml
services:
  my-service:
    image: whatever/image:latest
    restart: unless-stopped
    volumes:
      - ./appdata:/data
    # ... your config
```

### 3. Create the env template

```bash
# docker/pancake/my-new-stack/.env.example
SOME_SECRET=change-me
```

### 4. (Optional) Add a Makefile

Copy any existing stack's Makefile — they're all identical except the project name in `status:`.

### 5. (Optional) Add Tailscale access

Create `config/tailscale/<service>/serve.json` and add a `ts-<service>` sidecar to your compose file. Copy from any existing stack.

### 6. Deploy

```bash
# Option A: Push to git (auto-deploys via gitops-sync)
git add docker/pancake/my-new-stack
git commit -m "Add my-new-stack"
git push

# Option B: Manual (on the server)
cd /srv/docker/pancake/my-new-stack  # /srv is the repo root
cp .env.example .env && vim .env
docker compose up -d

# Option C: Via Dockge UI
# Navigate to https://dockge.<tailnet>.ts.net
# Dockge can see /srv/docker/* and manage stacks from the web UI
```

### Where to store data

| Data type | Where | Why |
|---|---|---|
| **App config/databases** | `./appdata/` (on SSD) | Fast I/O for SQLite/Postgres, backed up by the backup container |
| **Media files** (video, photos) | `/mnt/storage/...` (on HDD) | Large files, sequential reads, HDD is fine |
| **Secrets** | `.env` file (git-ignored) | Never committed. See 1Password section below. |
| **Container config** | `./config/` (committed) | Versioned, deployed via git |

### What about Dockge / Portainer?

**Dockge** is included in the `infra` stack. It mounts `/srv/docker` read-only so it can see all stacks on this server. Use it for:
- Viewing container status, logs, and resource usage
- Quick restarts or pulls when you don't want to SSH in
- Browsing compose files

**Don't use Dockge as the source of truth** — the git repo is. If you edit a compose file in Dockge, the next gitops-sync will overwrite it. Edit in git, push, let it deploy.

If you prefer Portainer, swap it in for Dockge in the infra stack. Same principle applies: use it for visibility, not as the config source.

### Launching ad-hoc containers

For quick experiments or one-off containers that don't need to be in git:

```bash
# Just run them directly
docker run -d --name test-thing -p 8080:8080 whatever/image

# Or create a stack in a local-only directory
mkdir -p /srv/docker/scratch/my-experiment
cd /srv/docker/scratch/my-experiment
# compose file here — it won't be in git, won't be synced
```

The `scratch/` directory isn't part of any server's stack tree, so gitops-sync ignores it. Dockge will still see it.

## Secrets management with 1Password

Instead of manually copying `.env` files to each machine, use a **1Password Service Account** to pull secrets automatically.

### Setup

1. Create a 1Password Service Account at https://my.1password.com → Developer → Service Accounts
2. Create a vault called "Homelab" and grant the service account read access
3. Store each stack's secrets as items:
   - Item name: `docker/pancake/arr` (matches the stack path)
   - Fields: `SEEDBOX_HOST`, `PIA_USER`, `NAS_HOST`, etc.

4. Save the service account token on each machine:

```bash
# One-time, on each server
echo "OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxx" | sudo tee /etc/1password-service-account.env
sudo chmod 600 /etc/1password-service-account.env
```

### How it works

The `gitops-sync.sh` script (and the bootstrap helper below) can pull secrets from 1Password and write `.env` files. Install the 1Password CLI on CoreOS:

```bash
# Layer the 1password-cli onto CoreOS (one-time)
sudo rpm-ostree install 1password-cli
sudo systemctl reboot
```

Then use the included sync script:

```bash
# Sync all stacks for this server
./scripts/sync-secrets.sh

# Sync a specific stack
./scripts/sync-secrets.sh docker/pancake/arr
```

This means you:
1. Store secrets in 1Password once
2. Install the service account token on each machine once
3. Run `sync-secrets.sh` to populate all `.env` files
4. The gitops-sync can optionally call this before deploying

## Tailscale service map

After deployment, all services are accessible via Tailscale with automatic HTTPS:

### pancake (laptop)

| Service | Tailnet URL |
|---|---|
| Plex | `https://plex.<tailnet>.ts.net` |
| Sonarr | `https://sonarr.<tailnet>.ts.net` |
| Radarr | `https://radarr.<tailnet>.ts.net` |
| Prowlarr | `https://prowlarr.<tailnet>.ts.net` |
| Bazarr | `https://bazarr.<tailnet>.ts.net` |
| Immich | `https://immich.<tailnet>.ts.net` |
| Music Assistant | `https://music.<tailnet>.ts.net` |
| Homepage | `https://homepage.<tailnet>.ts.net` |
| Dockge | `https://dockge.<tailnet>.ts.net` |
| Prometheus | `https://prometheus.<tailnet>.ts.net` |

### charm (mac mini)

| Service | Tailnet URL |
|---|---|
| Dockge (agent) | `https://dockge-charm.<tailnet>.ts.net` |
| Zigbee2MQTT | `https://z2m.<tailnet>.ts.net` |
| Scrypted | `https://scrypted.<tailnet>.ts.net` |
| AdGuard Home | `https://adguard.<tailnet>.ts.net` |

### powder (Oracle Cloud — ARM)

| Service | Tailnet URL |
|---|---|
| Dockge (agent) | `https://dockge-powder.<tailnet>.ts.net` |
| Uptime Kuma | `https://uptime-kuma.<tailnet>.ts.net` |
| Alertmanager | `https://alertmanager.<tailnet>.ts.net` |

### Other

| Service | Location |
|---|---|
| Home Assistant | Dell box (direct) |
| AdGuard (primary) | Raspberry Pi (direct) |
| Mosquitto (MQTT) | `mosquitto.<tailnet>.ts.net:1883` |
| MySQL | `charm:3306` (LAN only) |

## OS management

All machines run [uCore](https://github.com/ublue-os/ucore), an opinionated Fedora CoreOS image with Docker, Tailscale, and cockpit pre-installed.

- **pancake:** `ucore-minimal:stable-nvidia-lts` (NVIDIA LTS drivers for Maxwell GPU)
- **charm:** `ucore-minimal:stable`
- **powder:** `ucore-minimal:stable` (aarch64 / ARM)

On first boot, the Butane config auto-rebases from stock CoreOS to uCore (two reboots). After that, Docker, Tailscale, and cockpit are available immediately.

### Updates

```bash
rpm-ostree status              # Current and previous OS versions
rpm-ostree upgrade             # Pull latest uCore image
sudo systemctl reboot          # Apply after upgrade
```

### Rollback

If an update breaks something, the previous version is still on disk:

```bash
sudo rpm-ostree rollback
sudo systemctl reboot
```

### Management

```bash
# Cockpit web UI (enabled by default)
# https://pancake:9090 or https://charm:9090 or https://powder:9090

# Tailscale SSH (enabled by default)
ssh pancake               # via tailnet hostname

# Toolbox for a temporary mutable environment
toolbox enter
# now you're in a Fedora container with dnf, gcc, etc.
```
