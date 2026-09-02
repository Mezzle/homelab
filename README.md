# Homelab

Infrastructure-as-code for a three-machine homelab running [uCore](https://github.com/ublue-os/ucore) (Fedora CoreOS + Docker + Tailscale) with push-to-deploy via git.

## Architecture

```
┌─────────────────────────────────────────────┐  ┌──────────────────────────────┐
│  pancake (laptop)                           │  │  charm (mac mini)            │
│  i7-5700HQ · 16GB · GTX 970M                │  │  i5-4260U · 4GB              │
│                                             │  │                              │
│  arr        Plex, Sonarr, Radarr, Prowlarr, │  │  home        Mosquitto, MySQL│
│             Bazarr, Recyclarr, Scrypted,    │  │  monitoring  AdGuard replica │
│             gluetun, rclone, backup         │  │  infra       DockTail,       │
│  immich     Photos, ML (GPU), Postgres      │  │              Portainer agent │
│  music      Music Assistant                 │  │                              │
│  speedtest  Speedtest Tracker               │  └──────────────────────────────┘
│  infra      DockTail, Portainer, Homepage,  │
│             Diun                            │  ┌──────────────────────────────┐
│                                             │  │  powder (Oracle Cloud ARM)   │
│  SSD: OS + Docker + appdata                 │  │  Ampere A1 · 12GB · off-site │
│  HDD: rclone cache, music                   │  │                              │
│  NAS (CIFS): media, photos, backups         │  │  monitoring  Uptime Kuma     │
└─────────────────────────────────────────────┘  │  agent       Hermes Agent    │
                                                 │  infra       DockTail,       │
   Other: Home Assistant (Dell), AdGuard (Pi)    │              Portainer agent │
                                                 └──────────────────────────────┘
                       all connected over the Tailscale mesh
```

## Directory structure

```
├── coreos/                     # OS provisioning
│   ├── pancake.bu, charm.bu, powder.bu   Butane configs (first boot only)
│   ├── transpile.sh            #   .bu → .ign, substituting secrets from 1Password
│   └── os-configs/             #   Files both Butane and gitops-sync install
│       ├── manifest.conf       #     source → destination map for gitops-sync
│       ├── common/             #     systemd units for every host (stack@, gitops, backup…)
│       ├── pancake/ charm/ powder/       per-host files, units and drop-ins
│       └── *.conf, *.json      #     shared sshd / sysctl / docker daemon config
├── docker/<host>/<stack>/      # One Docker Compose stack per directory
│   ├── docker-compose.yml
│   ├── .env.example            #   keys synced from 1Password into .env (git-ignored)
│   ├── stack.sh -> scripts/stack.sh
│   ├── stack.local.sh          #   optional stack-specific commands (arr has one)
│   ├── config/                 #   committed config files
│   ├── scripts/                #   stack-specific scripts
│   └── appdata/                #   container data (git-ignored)
├── scripts/
│   ├── gitops-sync.sh          # timer: pull, sync secrets, apply changed stacks + OS configs
│   ├── sync-secrets.sh         # 1Password → .env
│   ├── container-heartbeat.sh  # timer: container health + disk usage → Uptime Kuma push
│   ├── backup-host.sh          # timer: nightly appdata + database backups
│   ├── bootstrap.sh            # first-time host setup after Ignition
│   ├── validate.sh             # what CI runs: compose config, butane, manifest, shellcheck
│   ├── stack.sh / stacks.sh    # shared wrappers (symlinked from each stack / host dir)
│   └── notify.sh               # Discord helper sourced by the others
├── docs/
│   ├── 1password-setup.md      # every 1Password item and field
│   ├── powder-setup.md         # Oracle Cloud deployment walkthrough
│   └── hermes-agent-plan.md    # the ops agent on powder
└── AGENTS.md                   # gotchas for anyone (human or agent) editing this repo
```

## How deployment works

1. Push to `main`.
2. Every host runs `gitops-sync.timer` every 5 minutes. It pulls, syncs `.env` files from 1Password, runs `docker compose up -d` for any stack whose directory changed, and installs any changed file listed in `coreos/os-configs/manifest.conf` (with the matching reload).
3. Failures post to Discord once per failure streak, and once more on recovery.

Butane configs only run on first boot. Anything a host might need updated later lives in `coreos/os-configs/` and is referenced from the `.bu` files with `local:` / `contents_local:`, so a fresh install and gitops-sync install the same bytes. `scripts/gitops-sync.sh --apply-os-configs` installs every manifest entry regardless of what changed; use it on a host that predates a unit.

Stacks start on boot through the `stack@<name>.service` template, which runs `compose up -d` on start and `compose stop` on stop. It never pulls, so upgrades are explicit (`stack.sh update`, prompted by Diun), and it never removes networks, so stacks that share one can't race on boot. A stopped container is exempt from `restart: unless-stopped`, which is what makes the mount ordering in the drop-ins hold. Mount and ordering dependencies are drop-ins under `coreos/os-configs/<host>/stack@<name>.service.d/`.

## Day to day

```bash
# On a host
/srv/docker/pancake/arr/stack.sh status
/srv/docker/pancake/arr/stack.sh logs sonarr
/srv/docker/pancake/arr/stack.sh update      # pull + recreate this stack
/srv/docker/pancake/stacks.sh status         # every container on the host
journalctl -u gitops-sync.service -f

# From your laptop
./scripts/validate.sh                        # before pushing
git push                                     # deploys within 5 minutes
```

### Adding a stack

1. Create `docker/<host>/<stack>/docker-compose.yml` and `.env.example`. Copy the `x-logging`, `x-healthcheck-defaults` anchors and the `docktail.service.*` labels from a neighbour.
2. `ln -s ../../../scripts/stack.sh docker/<host>/<stack>/stack.sh`
3. Add the 1Password item `docker.<host>.<stack>` with a field per key in `.env.example` (see `docs/1password-setup.md`).
4. Add `stack@<stack>.service` to the host's `.bu` so a reinstall starts it, and once on the live host: `sudo systemctl enable stack@<stack>.service`.
5. If the infra stack's DockTail needs to reach it, add the network to `docker/<host>/infra/docker-compose.yml` and to the infra `order.conf` drop-in.
6. Push.

### Where data lives

| Data | Where | Backup |
|---|---|---|
| App config and databases | `./appdata/` on the SSD | `backup.timer` nightly (all stacks); arr has its own sqlite-safe container |
| Media, photos | NAS over CIFS, mounted by systemd on pancake | NAS |
| rclone cache, music | `/var/mnt/storage` (pancake HDD) | none, rebuildable |
| Secrets | `.env`, synced from 1Password | 1Password |

Backups land in `/var/mnt/nas/backup/<host>/` on pancake and `/var/backups/homelab/<host>/` on charm and powder. Each host pushes a heartbeat to the `host-backup (<host>)` Uptime Kuma monitor, so a backup that stops running alerts. The charm and powder copies are on the same disk as the data; shipping them off-host is an open item.

Portainer is a viewer. The repo is the source of truth; anything edited in Portainer is overwritten on the next sync.

## Secrets

Secrets live in the 1Password vault `Homelab`. Each stack has an item named after its path with dots, `docker.pancake.arr`, and one field per key in `.env.example`. `sync-secrets.sh` writes them into `.env` on every gitops run, so adding a key is: add it to `.env.example`, add the field in 1Password, push. Non-secret configuration belongs in the compose file as a `${VAR:-default}`, not in 1Password.

Full item list and verification snippet: `docs/1password-setup.md`.

## Monitoring

| Layer | Tool | Catches |
|---|---|---|
| Reachability | Uptime Kuma on powder (off-site) | host or service down, internet or power outage |
| Container health | `container-heartbeat.timer` → Kuma push monitors | background containers with no port, unhealthy healthchecks |
| Disk | same timer, `disk:` entries | `/var` (and pancake's HDD) at 90% |
| Backups | `backup-host.sh` → Kuma push monitor | backup silently not running |
| Stale NAS mounts | `nas-mount-check.timer` on pancake | CIFS ESTALE while systemd still says mounted |
| Image updates | Diun | new tags, daily |
| Sync failures | `gitops-sync.sh` ERR trap → Discord | pull can't fast-forward, missing `op`, bad manifest |

## Tailscale services

DockTail publishes any container carrying `docktail.service.*` labels as a Tailscale Service at `https://<name>.<tailnet>.ts.net`. Names in use: plex, sonarr, radarr, prowlarr, bazarr, scrypted, immich, music, homepage, portainer, speedtest (pancake); adguard-backup, mosquitto, portainer-charm (charm); uptime-kuma, hermes, portainer-powder (powder).

## OS management

All hosts run uCore. pancake uses `ucore-minimal:stable-nvidia-lts` for the Maxwell GPU, charm `ucore-minimal:stable`, powder `ucore:stable` on aarch64.

```bash
rpm-ostree status              # current and previous deployments
rpm-ostree upgrade && sudo systemctl reboot
sudo rpm-ostree rollback && sudo systemctl reboot
```

powder cannot take OS upgrades or package layering: its 350M `/boot` has no room for a second aarch64 deployment. Run things there in containers. The 1Password CLI is a hand-placed binary in `/usr/local/bin` for the same reason; `scripts/bootstrap.sh` does that.

Fresh install: `cd coreos && ./transpile.sh <host>.bu`, install with the resulting `.ign`, wait for the two uCore rebase reboots, then run `scripts/bootstrap.sh docker/<host>` on the host. powder specifics are in `docs/powder-setup.md`.
