# Rollout: os-configs restructure (September 2026)

One-time steps for the commit that moved systemd units into `coreos/os-configs/`,
replaced the per-stack units with `stack@`, and added the disk and backup
monitors. pancake and charm need the host steps; watch only needs the Kuma
monitors and the sysctl cleanup. Delete this file once all three are done.

## Before pushing

1. 1Password: `docker.pancake.immich`: remove `IMMICH_VERSION`. It is pinned in compose now.
2. Uptime Kuma on watch: create the new push monitors and note their tokens:
   ```bash
   cd /srv/docker/watch/monitoring
   UPK_USER=.. UPK_PASS=.. ./scripts/.venv/bin/python scripts/add-container-monitors.py
   ```
   New: `disk /var` and `host-backup` for pancake and charm, plus
   `disk /var/mnt/storage (pancake)`. (`backup` with no suffix is pancake's
   arr container; leave it.)

## Push

`./scripts/validate.sh && git push`. Within five minutes each host pulls. The
old gitops-sync applies the compose changes (sonarr and radarr recreate once
for the removed dependency; watch recreates uptime-kuma on the `1` tag). It
does not install the new units: it doesn't understand `common/` or the
drop-in directories. That is the next step.

## On pancake and charm

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

# enable and start the replacements. --now is a no-op for running containers
# but marks the unit active so its ExecStop (compose stop) runs at shutdown.
# pancake:
sudo systemctl enable --now stack@arr stack@immich stack@music stack@speedtest stack@infra
# charm:
sudo systemctl enable --now stack@home stack@monitoring stack@infra

# retired timer, old sysctl files, hand-installed heartbeat copy
sudo systemctl disable --now docker-update-check.timer
sudo rm /etc/systemd/system/docker-update-check.{service,timer}
sudo rm -f /etc/sysctl.d/90-{pancake,home}-tuning.conf
sudo rm -f /etc/sysctl.d/90-arr-tuning.conf            # charm only: now pancake-only
sudo sysctl --system --quiet
sudo rm -f /usr/local/sbin/container-heartbeat.sh   # unit now runs the copy in /srv

# Cockpit is no longer enabled by the Butane configs
sudo systemctl disable --now cockpit.socket

# timers. The manifest installs units but never enables them.
# both:
sudo systemctl enable --now backup.timer container-heartbeat.timer gitops-sync.timer
# pancake:
sudo systemctl enable --now nas-mount-check.timer speedtest-usb-routing.timer
systemctl list-timers

# token map: add the disk and backup lines
sudoedit /srv/docker/$(hostname -s)/monitoring/heartbeat-tokens.env
#   disk:/var<TAB><token>
#   disk:/var/mnt/storage<TAB><token>      (pancake only)
#   host-backup<TAB><token>
sudo /bin/bash /srv/scripts/container-heartbeat.sh     # should print nothing and exit 0
sudo /bin/bash /srv/scripts/backup-host.sh             # first backup, check the size and Kuma
```

## On watch

gitops-sync there installs the unscoped manifest entries but skips `common/`.
The arr tuning file that the old manifest installed everywhere is now
pancake-only:

```bash
sudo rm -f /etc/sysctl.d/90-arr-tuning.conf
sudo sysctl --system --quiet
```

## Check

- `systemctl show -p Environment gitops-sync.service` on pancake and charm prints `GITOPS_SERVER_DIR=docker/<hostname>`, confirming the `%H` expansion.
- `systemctl status stack@arr` shows `active (exited)` after the next reboot, and `journalctl -b -u stack@infra` has no "network not found" error.
- `ss -ltnp | grep 9090` prints nothing on pancake and charm.
- Kuma shows the five new monitors green after the first backup run.
