# Rollout: os-configs restructure (September 2026)

One-time steps for the commit that moved systemd units into `coreos/os-configs/`,
replaced the per-stack units with `stack@`, and added the disk and backup
monitors. Delete this file once all three hosts are done.

## Before pushing

1. 1Password, so the first sync has the values:
   - `docker.powder.agent`: add `TAILNET` and `TAILSCALE_IP` (powder's `tailscale ip -4`).
   - `docker.powder.monitoring`: create the item with `TAILSCALE_IP`.
   - `docker.pancake.immich`: remove `IMMICH_VERSION`. It is pinned in compose now.
2. Uptime Kuma: create the new push monitors and note their tokens:
   ```bash
   cd /srv/docker/powder/monitoring
   UPK_USER=.. UPK_PASS=.. ./scripts/.venv/bin/python scripts/add-container-monitors.py
   ```
   New: `disk /var (host)` for all three, `disk /var/mnt/storage (pancake)`, `host-backup (host)` for all three. (`backup` with no suffix is pancake's arr container; leave it.)

## Push

`./scripts/validate.sh && git push`. Within five minutes each host pulls. The
old gitops-sync applies the compose changes (sonarr and radarr recreate once
for the removed dependency; powder gains socket-proxy and recreates autoheal
and uptime-kuma). It does not install the new units: it doesn't understand
`common/` or the drop-in directories. That is the next step.

## On each host

```bash
sudo -v
cd /srv
# remove the IMMICH_VERSION line so the compose pin takes effect (pancake only)
sed -i '/^IMMICH_VERSION=/d' docker/pancake/immich/.env

# install every manifest entry, then load them
/bin/bash scripts/gitops-sync.sh --apply-os-configs
sudo systemctl daemon-reload

# the old per-stack units: disable WITHOUT --now (their ExecStop is compose down)
# pancake:
sudo systemctl disable arr-stack immich-stack music-stack infra-stack observability-stack
sudo rm /etc/systemd/system/{arr,immich,music,infra,observability}-stack.service
ls -la /srv/docker/pancake/observability               # not in git; if it is only the old
                                                       # Prometheus stack, remove the directory
# charm:
sudo systemctl disable home-stack monitoring-stack infra-stack
sudo rm /etc/systemd/system/{home,monitoring,infra}-stack.service
# powder:
sudo systemctl disable infra-stack monitoring-stack
sudo rm /etc/systemd/system/{infra,monitoring}-stack.service

# enable and start the replacements. --now is a no-op for running containers
# but marks the unit active so its ExecStop (compose stop) runs at shutdown.
# pancake:  stack@{arr,immich,music,speedtest,infra}
# charm:    stack@{home,monitoring,infra}
# powder:   stack@{infra,monitoring,agent}
sudo systemctl enable --now stack@arr stack@immich stack@music stack@speedtest stack@infra

# retired timer, duplicate sysctl file, hand-installed heartbeat copy
sudo systemctl disable --now docker-update-check.timer
sudo rm /etc/systemd/system/docker-update-check.{service,timer}
sudo rm -f /etc/sysctl.d/90-{pancake,home,powder}-tuning.conf
sudo rm -f /usr/local/sbin/container-heartbeat.sh   # unit now runs the copy in /srv

# new timer
sudo systemctl daemon-reload
sudo systemctl enable --now backup.timer
systemctl list-timers backup.timer container-heartbeat.timer gitops-sync.timer

# token map: add the disk and backup lines
sudoedit /srv/docker/$(hostname -s)/monitoring/heartbeat-tokens.env
#   disk:/var<TAB><token>
#   disk:/var/mnt/storage<TAB><token>      (pancake only)
#   host-backup<TAB><token>
sudo /bin/bash /srv/scripts/container-heartbeat.sh     # should print nothing and exit 0
sudo /bin/bash /srv/scripts/backup-host.sh             # first backup, check the size and Kuma
```

## Check

- `systemctl show -p Environment gitops-sync.service` prints `GITOPS_SERVER_DIR=docker/<hostname>`, confirming the `%H` expansion.
- `systemctl status stack@arr` shows `active (exited)` after the next reboot, and `journalctl -b -u stack@infra` has no "network not found" error.
- `docker ps` on powder shows `socket-proxy`, and `ss -ltnp | grep -E '3001|9119|8644'` binds to the Tailscale address, not `0.0.0.0`.
- Kuma shows the six new monitors green after the first backup run.
