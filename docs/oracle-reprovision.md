# Rebuild `powder` as a tailnet-only development machine

`powder` is an Ubuntu 24.04 ARM64 development workstation on Oracle's A1
shape. It is deliberately disposable: configuration lives in this repository
and `Mezzle/dotfiles`; work that matters must be pushed.

The existing `watch` instance is already the monitoring host. Its default 50 GB
boot volume counts against OCI's 200 GB Always Free block-volume allowance, so
request about 150 GB for `powder` only after checking that the tenancy has no
other retained boot or block volumes.

## Before destroying the old instance

1. Confirm Uptime Kuma is healthy on `watch` and has its expected monitors and
   notification links.
2. Push and merge the configuration in this repository, including the
   `homelab-operator` deployment.
3. On `pancake` and `charm`, let GitOps pull the change, then verify as `mez`:

   ```sh
   sudo /usr/local/sbin/homelab-operator-install.sh
   id homelab-operator
   sudo -u homelab-operator sudo /usr/local/sbin/homelab-operator summary
   ```

4. Confirm there is no data on old `powder` worth retaining. Terminating it is
   intentional and irreversible.

## Tailscale policy

Create `tag:dev` and `tag:homelab` in the Tailscale admin console, then tag
`pancake` and `charm` with `tag:homelab`. The one-off cloud-init auth key must
be pre-authorized, non-ephemeral, expire soon, and carry `tag:dev`.

Replace `YOUR_TAILSCALE_LOGIN` with the exact login shown in the Tailscale admin
console, then merge the following rules into the tailnet policy. Keep existing
rules that other machines need; this is a focused addition, not a replacement
policy.

```jsonc
{
  "tagOwners": {
    "tag:dev": ["autogroup:admin"],
    "tag:homelab": ["autogroup:admin"]
  },
  "acls": [
    // Existing ACLs remain here.
    {
      "action": "accept",
      "src": ["YOUR_TAILSCALE_LOGIN"],
      "dst": ["tag:dev:443"]
    }
  ],
  "ssh": [
    // Your ordinary tailnet identity reaches the Powder workstation.
    {
      "action": "check",
      "src": ["YOUR_TAILSCALE_LOGIN"],
      "dst": ["tag:dev"],
      "users": ["mez"],
      "checkPeriod": "12h"
    },
    // Agents on Powder can only become the restricted home-lab operator.
    {
      "action": "accept",
      "src": ["tag:dev"],
      "dst": ["tag:homelab"],
      "users": ["homelab-operator"]
    }
  ]
}
```

Manual verification after the policy saves:

```sh
ssh mez@powder true
curl --fail https://powder.<tailnet>.ts.net/
ssh homelab-operator@pancake 'sudo /usr/local/sbin/homelab-operator summary'
ssh homelab-operator@charm 'sudo /usr/local/sbin/homelab-operator summary'
ssh core@pancake true # this must fail from powder
```

`homelab-operator restart`, `gitops`, and `reboot` are intentionally permitted
by the wrapper. Agents must ask before using them. Scheduled diagnostics use
only `summary`, `logs`, `status`, `containers`, and `gitops-status`.

## Create Powder

1. In 1Password, add `POWDER_TS_AUTHKEY` to the `Homelab/coreos` item. Put the
   short-lived one-off tagged key there. It is consumed once during cloud-init.
2. Render the user-data locally. The rendered file contains secrets and is
   ignored by Git:

   ```sh
   ./cloud/render-cloud-init.sh powder
   ```

3. Create an Oracle Ubuntu Server 24.04 ARM64 A1 VM with 2 OCPUs, 12 GB RAM,
   and the remaining Always Free boot storage. Paste the rendered file as
   cloud-init user data. Do not create an OCI ingress rule, including SSH.
4. Wait for cloud-init to finish. If the tailnet key or firewall setup fails,
   use the OCI serial console rather than opening public SSH.
5. Once it appears as `powder` in Tailscale, connect from your laptop:

   ```sh
   ssh mez@powder
   ```

6. Authenticate GitHub, clone this repository, and run the user bootstrap:

   ```sh
   gh auth login
   gh auth setup-git
   git clone https://github.com/Mezzle/homelab.git ~/dev/homelab
   cd ~/dev/homelab
   ./cloud/powder/bootstrap.sh
   ```

   The bootstrap requests Powder's read-only 1Password service-account token
   without echoing it. It stores the token at
   `~/.config/1password/service-account.env` with mode `0600`, then applies
   `Mezzle/dotfiles`. Select `devMachine = true` when chezmoi prompts.

7. Log out and in again. Docker membership and the zsh login shell apply on
   the next session.

## Signing and agent setup

Load the service-account environment before restoring a signing key:

```sh
set -a
. ~/.config/1password/service-account.env
set +a
~/dev/homelab/cloud/powder/setup-signing-key.sh
```

The service account is normally read-only. Create the `powder-signing-key` SSH
Key item in 1Password from a trusted laptop before a rebuild, or temporarily
grant create access to store a newly generated key. Register the generated
public key in GitHub as a signing key if `gh` did not do it automatically.

Authenticate providers separately. Do not point Codex or Claude at z.ai by
default:

```sh
codex login                 # ChatGPT subscription
claude auth login           # Claude subscription
opencode auth login         # select Z.AI Coding Plan
```

Install and pair the persistent T3 service over Tailscale HTTPS:

```sh
npx t3@latest service install
npx t3@latest service status
npx t3 pair --tailscale
```

Add `mez@powder` as a T3 Code SSH environment. Use the same target with
JetBrains Gateway / IntelliJ Remote Development; open projects under `~/dev`.
Start with a 3 GB IDE backend heap because the host has only two cores.

## Operations

Run the explicit update command when you are ready to disrupt active tools:

```sh
~/dev/homelab/scripts/powder-update.sh
```

It updates Ubuntu packages, chezmoi, Mise-managed developer tools, and the T3
background service. It reports a reboot requirement but does not reboot.

`watch` should monitor Powder's T3 HTTPS endpoint, Tailscale/SSH reachability,
disk space, failed units, and pending reboot state. Local systemd and Docker
restart policies handle automatic recovery. `watch` alerts; it does not repair
Powder.

## Acceptance checklist

- Reboot and reconnect through Tailscale with no OCI ingress.
- Pair T3 over tailnet HTTPS and open a persistent session.
- Use Codex, Claude Code, and OpenCode with their separate subscriptions.
- Clone a repository under `~/dev` and open it through IntelliJ Remote
  Development.
- Verify `node` and `pnpm` in zsh, non-interactive SSH, IntelliJ, and T3.
- Make a signed test commit and confirm GitHub marks it verified.
- Run `homelab-operator summary` on Pancake and Charm from Powder.
- Restart an approved service only after an explicit confirmation.
- Confirm `core` login from Powder is denied.
- Confirm Watch sees Powder's health checks and an OCI reboot restores
  Tailscale, Docker, and T3 without manual repair.
