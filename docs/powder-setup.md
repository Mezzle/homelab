# Powder Setup Guide

Step-by-step instructions for deploying powder (Oracle Cloud Always Free — Ampere A1).

Powder runs external monitoring (Uptime Kuma) and a Portainer agent, connected to the homelab via Tailscale.

## Prerequisites

On your **laptop** (macOS):

```bash
# 1Password CLI (for transpiling Butane configs)
brew install 1password-cli

# Butane (Butane → Ignition transpiler)
brew install butane

# OCI CLI (Oracle Cloud Infrastructure)
brew install oci-cli
# Then configure: oci setup config
```

An **Oracle Cloud** account with Always Free tier:
- Sign up at https://cloud.oracle.com (credit card required, never charged for Always Free)
- Note your tenancy OCID and home region

## Step 1: Create the OCI instance

### 1a. Download the Fedora CoreOS image

```bash
# Get the latest stable oraclecloud aarch64 image URL
curl -s https://builds.coreos.fedoraproject.org/streams/stable.json \
  | jq -r '.architectures.aarch64.artifacts.oraclecloud.formats["qcow2.xz"].disk.location'

# Download and decompress
wget <url-from-above>
xz -d fedora-coreos-*-oraclecloud.aarch64.qcow2.xz
```

### 1b. Import as a custom image in OCI

1. Go to **OCI Console → Compute → Custom Images → Import Image**
2. Upload the `.qcow2` file to an Object Storage bucket first, then import from there
3. Settings:
   - **Name:** `fedora-coreos-stable-aarch64`
   - **Operating system:** Linux
   - **Image type:** QCOW2
   - **Launch mode:** Paravirtualized
   - **Shape compatibility:** VM.Standard.A1.Flex (Ampere)

Or via CLI:

```bash
# Upload to Object Storage
oci os object put \
  --bucket-name <your-bucket> \
  --file fedora-coreos-*-oraclecloud.aarch64.qcow2 \
  --name fcos-aarch64.qcow2

# Import as custom image
oci compute image import from-object \
  --compartment-id <your-compartment-ocid> \
  --bucket-name <your-bucket> \
  --name fcos-aarch64.qcow2 \
  --display-name "fedora-coreos-stable-aarch64" \
  --source-image-type QCOW2 \
  --launch-mode PARAVIRTUALIZED
```

### 1c. Transpile the Butane config

```bash
cd coreos
./transpile.sh powder.bu
# Outputs: powder.ign
```

This pulls your SSH key and Tailscale auth key from 1Password automatically.

### 1d. Launch the instance

1. **OCI Console → Compute → Instances → Create Instance**
2. Settings:
   - **Name:** `powder`
   - **Image:** Select your imported `fedora-coreos-stable-aarch64`
   - **Shape:** VM.Standard.A1.Flex — **2 OCPUs, 12 GB RAM** (Always Free allowance)
   - **Boot volume:** 100 GB (Always Free includes 200 GB total)
   - **Networking:** Default VCN, public subnet, assign public IP
   - **SSH keys:** Skip (handled by Ignition)
3. **Advanced options → Initialization script:**
   - Select **"Paste cloud-init script"** (OCI passes this as userdata)
   - Paste the **entire contents** of `powder.ign`

Or via CLI:

```bash
oci compute instance launch \
  --compartment-id <your-compartment-ocid> \
  --availability-domain <your-ad> \
  --shape VM.Standard.A1.Flex \
  --shape-config '{"ocpus": 2, "memoryInGBs": 12}' \
  --image-id <your-custom-image-ocid> \
  --subnet-id <your-subnet-ocid> \
  --assign-public-ip true \
  --display-name powder \
  --metadata "{\"user_data\": \"$(base64 -i powder.ign)\"}"
```

> **Note:** OCI userdata has a 32 KB limit. `powder.ign` should be well under this. If it somehow exceeds it, host the file on Object Storage and use a shim Ignition config that references it.

### 1e. Open firewall ports

By default, OCI's security list blocks most inbound traffic. You need to allow Tailscale (and optionally SSH for initial setup):

1. **OCI Console → Networking → VCN → Security Lists → Default**
2. Add **ingress rules**:

| Source | Protocol | Port | Purpose |
|---|---|---|---|
| `0.0.0.0/0` | UDP | 41641 | Tailscale WireGuard |
| `0.0.0.0/0` | TCP | 22 | SSH (can remove after Tailscale is up) |

Tailscale will work without port 41641 open (via DERP relay), but direct connections are faster.

## Step 2: Wait for uCore auto-rebase

The instance will boot and immediately begin the uCore auto-rebase process:

1. **First boot:** Stock Fedora CoreOS starts, rebases to unsigned uCore image, reboots (~3-5 min)
2. **Second boot:** Rebases to signed uCore image, reboots (~3-5 min)
3. **Third boot:** uCore is running. Docker, Tailscale, and Cockpit are available.

Monitor progress from the OCI Console serial console, or just wait ~10 minutes.

## Step 3: Verify Tailscale connectivity

After the reboots complete, Tailscale should have authenticated automatically using the auth key from your Ignition config.

```bash
# Check your Tailscale admin console
# https://login.tailscale.com/admin/machines
# You should see "powder" in the machine list

# SSH in via Tailscale
ssh mez@powder
```

If powder doesn't appear in Tailscale after 15 minutes, SSH in via the public IP:

```bash
ssh mez@<public-ip>
# Check Tailscale status
sudo tailscale status
sudo journalctl -u tailscale-auth.service
```

### Approve the exit node

Powder advertises itself as a Tailscale exit node. To use it:

1. Go to https://login.tailscale.com/admin/machines
2. Find `powder` → **...** → **Edit route settings**
3. Toggle **"Use as exit node"**

Then on any client device, select powder as your exit node in the Tailscale app.

## Step 4: Bootstrap

```bash
ssh mez@powder
curl -sL https://raw.githubusercontent.com/Mezzle/homelab/main/scripts/bootstrap.sh \
  | bash -s -- docker/powder
```

The script downloads the 1Password CLI into `/usr/local/bin`, asks for the
service account token, clones the repo to `/srv`, syncs secrets and starts
the stacks.

> `op` must land in `/usr/local/bin`. `rpm-ostree install` does not work on
> powder: /boot has no room for a second deployment. `/usr/local/bin` is on
> systemd's PATH; `~/.local/bin` is not. If `gitops-sync.service` cannot find
> `op` it falls back to the system SSH config, cannot authenticate to GitHub,
> and now notifies Discord instead of failing silently. That silent failure
> kept powder four months behind `main` once.

## Step 5: Start the stacks

The systemd units should auto-start the stacks if the compose files exist. If they haven't started yet:

```bash
# Start everything
/srv/docker/powder/stacks.sh up-all

# Or individually
/srv/docker/powder/infra/stack.sh up
/srv/docker/powder/monitoring/stack.sh up
/srv/docker/powder/agent/stack.sh up

# On boot they start through stack@<name>.service (see coreos/powder.bu)

# Verify
docker ps
```

You should see:
- `docktail` + `portainer-agent` (infra)
- `uptime-kuma` (monitoring)
- `hermes` (agent)

## Step 6: Configure services

### Uptime Kuma — first-time setup

1. Open https://uptime-kuma.\<tailnet\>.ts.net
2. Create an admin account (first visit only)
3. **Add a notification method:**
   - Settings → Notifications → Setup Notification
   - Type: Discord
   - Webhook URL: your Discord webhook URL
   - Click "Test" to verify
4. **Seed all monitors** (from powder, or any machine with access):

```bash
# Install the Python API client (Uptime Kuma uses Socket.IO, not REST)
pip3 install uptime-kuma-api

# Run from your laptop or from powder
cd /srv/docker/powder/monitoring
UPK_USER=<your-utk-username> \
UPK_PASS=<your-utk-password> \
TAILNET=<your-tailnet> \
./scripts/seed-uptime-kuma.sh

# Optional: pass MQTT/MySQL creds for deeper checks
# MQTT_USER=... MQTT_PASS=... MYSQL_USER=... MYSQL_PASS=... \
```

This creates monitors for all services including keyword/JSON validation,
MQTT broker checks, DNS resolution tests, and Tailscale ping.

#### Push monitors: containers, disks, backups

Containers with no HTTP port to probe (recyclarr, rclone-seedbox, backup,
speedtest, portainer, docktail on each host) are watched with Uptime Kuma
**push** monitors. `scripts/container-heartbeat.sh` runs on every host from
`container-heartbeat.timer` each minute, inspects each container's docker
state and health, and pings the matching push monitor up or down. The same
run checks disk usage (`disk:` entries, down at 90%), and
`scripts/backup-host.sh` pings its own monitor after each nightly backup. A
host that stops pushing trips Kuma's "No heartbeat in the time window".

Create the monitors (idempotent) and print their push tokens:

```bash
cd /srv/docker/powder/monitoring
UPK_USER=.. UPK_PASS=.. ./scripts/.venv/bin/python scripts/add-container-monitors.py
# re-print existing tokens:  ... add-container-monitors.py --tokens
```

The timer units and the scripts deploy through git: `coreos/os-configs/manifest.conf`
installs `container-heartbeat.{service,timer}` and `backup.{service,timer}`
on every host. On a host that predates them, enable once:

```bash
sudo systemctl enable --now container-heartbeat.timer backup.timer
```

The token map lives at `/srv/docker/<host>/monitoring/heartbeat-tokens.env`,
one `<name><TAB><token>` per line, mode 600, NOT committed. `<name>` is a
docker container name, `disk:<mountpoint>`, or `host-backup`. Watch `/var`, not
`/`: on Fedora CoreOS `/` is composefs and always reports 100%.

```
recyclarr	abc123
docktail	def456
disk:/var	ghi789
disk:/var/mnt/storage	jkl012
host-backup	mno345
```

`socket-proxy` on pancake has its own hand-installed `socket-proxy-heartbeat.timer`
and is deliberately not in the map.

### Hermes Agent — first-time setup

The dashboard is published as a Tailscale Service and is reachable at
https://hermes.\<tailnet\>.ts.net. Credentials are in 1Password
(`Homelab` → `docker.powder.agent`).

The password is stored in `.env` in plaintext rather than as the scrypt
`PASSWORD_HASH` Hermes also accepts. Compose interpolates `$` in `.env`
values and a scrypt hash is `scrypt$N$r$p$salt$hash`, so the hash arrives in
the container with its `$` segments eaten and every login fails with
"Invalid credentials". Keep the password itself free of `$` too.

No inference provider is configured by the stack — pick one from the
dashboard, or from the container:

```bash
docker exec -it hermes hermes model    # provider + default model
docker exec -it hermes hermes auth     # pooled provider credentials
```

Credentials land in `/opt/data` on the mounted volume, so they survive a
container recreate or image update.

To attach the Hermes desktop app: **Settings → Gateways → Remote gateway**,
URL `https://hermes.\<tailnet\>.ts.net`, then sign in with the same
credentials. The remote host becomes the execution boundary — agent tools,
terminal commands, and file operations all run on powder, not on your laptop.

### Connect Portainer to the primary

From the primary Portainer UI on pancake:

1. Open https://portainer.\<tailnet\>.ts.net
2. Go to **Environments → Add Environment → Agent**
3. URL: `https://portainer-powder.<tailnet>.ts.net`
4. Powder's containers should now appear in the Portainer UI

## Step 7: Verify everything

```bash
# On powder — check all containers are healthy
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check Tailscale
tailscale status

# Check the timers are active
systemctl list-timers gitops-sync.timer container-heartbeat.timer backup.timer docker-prune.timer

# Check from your laptop
curl -s https://uptime-kuma.<tailnet>.ts.net  # Should load
# Portainer agent is TCP on port 9001, not HTTPS
```

## Ongoing maintenance

```bash
# SSH in
ssh mez@powder

# Check stack status
/srv/docker/powder/stacks.sh status

# View logs
/srv/docker/powder/monitoring/stack.sh logs
/srv/docker/powder/monitoring/stack.sh logs uptime-kuma

# OS updates and package layering do not work on powder: /boot (350M) has
# no room for a second aarch64 deployment. Do not try.

# Cockpit web UI
# https://powder:9090

# Everything else is handled by gitops-sync (pulls git every 5 min)
```

## Architecture summary

```
powder (Oracle Cloud Always Free)
├── Ampere A1.Flex — 2 OCPU, 12GB RAM, 100GB disk (aarch64)
├── uCore (Fedora CoreOS + Docker + Tailscale + Cockpit)
├── Tailscale exit node
├── docker/powder/infra/
│   └── Portainer Agent (managed from pancake)
├── docker/powder/monitoring/
│   └── Uptime Kuma (external monitoring of all services)
└── docker/powder/agent/
    └── Hermes Agent (ops agent — see docs/hermes-agent-plan.md)
```
