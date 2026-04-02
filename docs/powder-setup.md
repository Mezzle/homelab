# Powder Setup Guide

Step-by-step instructions for deploying powder (Oracle Cloud Always Free — Ampere A1).

Powder runs external monitoring (Uptime Kuma + Alertmanager) and a Dockge agent, connected to the homelab via Tailscale.

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

## Step 4: Clone the repo and sync secrets

```bash
# SSH in
ssh mez@powder

# Clone the repo
cd /srv
git clone <your-repo-url> .

# Install 1Password CLI (one-time)
sudo rpm-ostree install 1password-cli
sudo systemctl reboot

# After reboot, set up the service account token
ssh mez@powder
echo "OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxx" | sudo tee /etc/1password-service-account.env
sudo chmod 600 /etc/1password-service-account.env

# Sync secrets for powder's stacks
./scripts/sync-secrets.sh docker/powder/infra
./scripts/sync-secrets.sh docker/powder/monitoring
```

## Step 5: Start the stacks

The systemd units should auto-start the stacks if the compose files exist. If they haven't started yet:

```bash
# Start everything
make -C /srv/docker/powder up-all

# Or individually
make -C /srv/docker/powder/infra up
make -C /srv/docker/powder/monitoring up

# Verify
docker ps
```

You should see:
- `dockge` + `ts-dockge-powder` (infra)
- `uptime-kuma` + `ts-uptime-kuma` (monitoring)
- `alertmanager` + `ts-alertmanager` (monitoring)

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
# Install jq if needed
sudo rpm-ostree install jq && sudo systemctl reboot

# Or run from your laptop
cd /srv/docker/powder/monitoring
UPK_USER=<your-utk-username> \
UPK_PASS=<your-utk-password> \
TAILNET=<your-tailnet> \
./scripts/seed-uptime-kuma.sh
```

This creates monitors for all services + host ping checks.

### Connect Dockge to the primary

From the primary Dockge UI on pancake:

1. Open https://dockge.\<tailnet\>.ts.net
2. Go to **Settings → Agents → Add Agent**
3. URL: `ws://dockge-powder.<tailnet>.ts.net/terminal-socket`
4. Powder's stacks should now appear in the Dockge UI

### Alertmanager — verify Prometheus connectivity

On **pancake**, Prometheus is configured to send alerts to `powder:9093`. Verify:

```bash
# From pancake
curl -s http://powder:9093/-/healthy
# Should return: OK

# Alertmanager on powder receives alerts from any future monitoring setup
```

## Step 7: Verify everything

```bash
# On powder — check all containers are healthy
docker ps --format "table {{.Names}}\t{{.Status}}"

# Check Tailscale
tailscale status

# Check gitops-sync timer is active
systemctl status gitops-sync.timer

# Check from your laptop
curl -s https://uptime-kuma.<tailnet>.ts.net  # Should load
curl -s https://alertmanager.<tailnet>.ts.net/-/healthy  # Should return OK
curl -s https://dockge-powder.<tailnet>.ts.net  # Should load
```

## Ongoing maintenance

```bash
# SSH in
ssh mez@powder

# Check stack status
make -C /srv/docker/powder status

# View logs
make -C /srv/docker/powder/monitoring logs
make -C /srv/docker/powder/monitoring logs s=uptime-kuma

# Update OS
rpm-ostree upgrade && sudo systemctl reboot

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
│   └── Dockge (agent → managed from pancake)
└── docker/powder/monitoring/
    ├── Uptime Kuma (external monitoring of all services)
    └── Alertmanager (receives alerts from Prometheus on pancake)
```
