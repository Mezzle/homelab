# Working on this repo

Read this before editing. It is the list of things that have already gone wrong once.

## What a push does

A push to `main` is a deploy. Every host pulls within 5 minutes and runs `docker compose up -d` on any stack whose directory changed, and installs any changed file in `coreos/os-configs/manifest.conf`. There is no staging. Run `./scripts/validate.sh` first.

Butane files under `coreos/` only run at install. Editing a `.bu` changes nothing on a live host. If it needs to reach a host now, it has to be a file in `coreos/os-configs/` listed in the manifest, and the `.bu` should reference that same file with `local:` or `contents_local:`.

## Hosts

- **pancake** (laptop, x86, GPU) runs the media stacks. NAS shares are systemd CIFS automounts under `/var/mnt/nas/`, bind-mounted into containers with `rslave`. If a mount goes stale, `nas-mount-check.timer` repairs it; don't restart the mount unit by hand while containers hold it.
- **charm** (Mac Mini, 4GB) runs home automation and the AdGuard replica.
- **powder** (Oracle Cloud, aarch64) runs off-site monitoring and the Hermes agent. Its 350M `/boot` has no room for a second aarch64 deployment: `rpm-ostree install` and OS upgrades fail. Do not layer packages; containerise. `op` is a hand-placed binary in `/usr/local/bin`.
- SSH as `mez` over Tailscale. All hosts are SELinux enforcing.

## Things that bite

- **SELinux and systemd.** A unit cannot `ExecStart=` a script under `/srv` directly (`203/EXEC`). Use `ExecStart=/bin/bash /srv/scripts/x.sh`, or install the script to `/usr/local/sbin` via the manifest.
- **`$` in `.env`.** Compose interpolates `$` in env files. Scrypt and bcrypt hashes arrive mangled. Store plaintext secrets and keep `$` out of passwords.
- **1Password item names** are the stack path with dots: `docker.pancake.arr`. Fields are the keys in `.env.example`. `sync-secrets.sh` never removes a key from `.env`.
- **Docker socket in containers** on these hosts needs `security_opt: label=disable`; SELinux blocks it otherwise.
- **`/mnt` is `/var/mnt`** on Fedora CoreOS. Use `/var/mnt` in compose files. `/` is composefs and `df /` always says 100%; the disk is `/var`.
- **Immich** server, ML and database versions move together. `IMMICH_VERSION` is pinned in the compose file; bump it there.
- **Uptime Kuma** is pinned to 1.x. The seed scripts use its Socket.IO API, which 2.x changes.
- **Stack units** are `stack@<name>.service`: `compose up -d` on start, `compose stop` on stop, never pull, never `down`. Dependencies on mounts and on other stacks are drop-ins in `coreos/os-configs/<host>/`. Don't put `compose down` back in a unit; it removes networks other stacks join.
- **New systemd units** installed via the manifest still need `systemctl enable --now` once on each existing host. The manifest reloads; it doesn't enable. gitops-sync only installs files that changed in the pull it just did; `gitops-sync.sh --apply-os-configs` installs everything.
- **Host-side git commits** (there is a `pancake` remote) make the next `--ff-only` pull fail. gitops-sync now notifies on that, but the fix is to push from the laptop.

## Conventions

- One directory per stack, `docker-compose.yml` plus `.env.example`. `stack.sh` is a symlink to `scripts/stack.sh`; stack-specific commands go in `stack.local.sh`.
- Every service carries the `x-logging` anchor, a memory limit, `no-new-privileges` unless it needs the socket, and `docktail.service.*` labels if it should be reachable over the tailnet.
- Floating tags are the default. Pin only where a major bump breaks something, and say why in a comment.
- Every check that could be a timer should be a timer. The Hermes agent is for unknown unknowns, not for anything found twice.
