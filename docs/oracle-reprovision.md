# Oracle reprovisioning runbook

This runbook moves Uptime Kuma from `powder` to an E2.1.Micro instance named
`watch`, then rebuilds the Ampere A1 instance as an Ubuntu development host.

Do not terminate `powder` until the monitoring cutover passes the checks below.
The final copy stops Kuma, so monitor history cannot split across two databases.

## 1. Create watch

Create an Oracle `VM.Standard.E2.1.Micro` instance with Ubuntu Server 24.04,
a 50 GB boot volume, and a public IP for initial setup. The OCI security list
only needs temporary TCP 22 ingress from your current public IP. Do not expose
port 3001.

Render the cloud-init file on your Mac:

```bash
./cloud/render-cloud-init.sh watch
```

Paste `cloud/watch/cloud-init.rendered.yaml` into the instance cloud-init field.
It contains a Tailscale auth key, so delete the local rendered file and revoke a
single-use key after `watch` appears in the tailnet.
Wait for `/var/lib/cloud/instance/boot-finished`, then connect:

```bash
ssh mez@watch
git clone git@github.com:mezzle/homelab.git ~/homelab
cd ~/homelab
./cloud/watch/bootstrap.sh
```

Cloud-init joins Tailscale and enables Tailscale SSH. The bootstrap clones the
repository to `/srv`, starts Kuma, enables the five-minute GitOps timer, and publishes Kuma at
`https://watch.<tailnet>.ts.net` with Tailscale Serve.

Remove public SSH ingress after `ssh mez@watch` works through Tailscale.

## 2. Cut over Uptime Kuma

The migration script stops the old container before its final archive. It leaves
the source data intact, so rollback is `docker start uptime-kuma` on old powder.

```bash
./scripts/migrate-uptime-kuma.sh
./scripts/migrate-uptime-kuma.sh --confirm
```

Then verify:

```bash
curl -fsS https://watch.<tailnet>.ts.net/ >/dev/null
ssh mez@watch 'docker ps && systemctl status monitoring-stack gitops-sync.timer'
```

In Kuma, check monitor history, notification settings, and push monitors. Stop a
non-critical test service and wait for its alert before proceeding.

The heartbeat sender now defaults to `https://watch.corgi-justice.ts.net`.
Override `TAILNET` if the tailnet DNS suffix changes. Reinstall the tracked
script and service on `pancake` and `charm`:

```bash
sudo install -m 0755 scripts/container-heartbeat.sh /usr/local/sbin/container-heartbeat.sh
sudo install -m 0644 coreos/os-configs/common/container-heartbeat.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart container-heartbeat.timer
```

## 3. Rebuild powder

Back up any files under `/workspaces` or the old `/srv` that are not in Git.
Terminate the old A1 instance only after the monitoring checks pass.

Create `powder` as an Ubuntu Server 24.04 ARM64 A1 instance with 2 OCPUs,
12 GB RAM, and the remaining Always Free boot-volume allocation. Use this
rendered cloud-init:

```bash
./cloud/render-cloud-init.sh powder
```

After cloud-init finishes:

```bash
ssh mez@<powder-public-ip>
git clone git@github.com:mezzle/homelab.git ~/homelab
cd ~/homelab
./cloud/powder/bootstrap.sh
```

Sign out once after bootstrap so the new Docker group applies. Confirm access
over Tailscale, then remove public SSH ingress.

## 4. Connect development clients

For T3 Code, add an SSH remote environment for `mez@powder`. Its launcher finds
Node through the mise shims configured in `~/.profile` and starts T3 on a remote
loopback port.

For IntelliJ IDEA, choose Remote Development, add the same SSH target, and put
projects under `/workspaces`. Start with a 3 GB backend heap. Powder has enough
RAM, but only two cores, so indexing several large projects at once will hurt.

Run `codex login` and `claude` in an SSH terminal on powder. Their credentials
remain in the development user's home directory. Do not copy laptop credential
directories wholesale.

## Rollback

If the restored Kuma instance is unhealthy:

```bash
ssh mez@watch 'sudo systemctl stop monitoring-stack.service'
ssh mez@powder 'docker start uptime-kuma'
```

No migration step deletes the old Kuma data. Oracle instance termination is the
first irreversible step in this runbook.
