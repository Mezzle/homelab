# Hermes Agent for Homelab Operations — Plan

A plan for introducing [Hermes Agent](https://github.com/NousResearch/hermes-agent)
(Nous Research) as an operational agent for this homelab.

**Status:** proposal, nothing deployed.

---

## Why — the actual gap

On 2026-08-22 an investigation into "unreliable seedbox transfers" found three
independent failures. None of them were subtle, and none had been noticed:

| Failure | Duration | Why nothing caught it |
|---|---|---|
| Sonarr/Radarr OOM-killed mid-import, 143× | ~2 months | Kernel-level event; nothing reads `journalctl -k` |
| NAS CIFS mounts stale (ESTALE) | days | systemd still reported the unit `active (mounted)` |
| arr backups failing | since 18 Jun | Script died before it reached its own notify path |
| `portainer-agent` on powder unhealthy | 2 weeks | Uptime Kuma checks reachability, not container health |

The homelab already has plenty of monitoring:

- **Uptime Kuma** — is the host/port reachable?
- **Diun** — is there a newer image?
- **Homepage** — dashboard
- **Portainer** — container state, on demand
- **autoheal** — restart containers that fail their own healthcheck
- **nas-mount-check.timer** — remount stale CIFS mounts

Every one of these answers a question someone thought to ask in advance. What
none of them do is **correlate signals across hosts and notice that the system
is not actually working**. A backup that has silently not run since June is
green on every dashboard here.

That gap — not "network management" in the SNMP sense — is what an LLM agent is
genuinely good at, because it is the job a human does by reading logs and
joining the dots.

## The governing principle

> **Every failure the agent finds twice should stop being the agent's job.**

When a repeatable failure mode is identified, encode it as a deterministic
check (a systemd timer, a healthcheck, an Uptime Kuma monitor) and take it off
the agent's plate. `nas-mount-check.timer` is the model: a stale-mount detector
does not need an LLM, it needs fifteen lines of bash on a timer.

The agent's job is **unknown-unknowns** — the thing nobody wrote a check for
yet. Judge it on how many deterministic checks it causes to be written, not on
how many things it does itself. An agent that has become load-bearing for a
known failure mode is a design smell.

---

## Where it runs: powder

| | pancake | charm | powder |
|---|---|---|---|
| Spare capacity | busy (media, GPU, imports) | 4GB RAM, weak | **2 ARM cores, 8.7GB free, 77GB disk** |
| Location | on-site | on-site | **off-site (Oracle Cloud)** |
| Current role | workloads | home automation | **monitoring (Uptime Kuma)** |
| Cost | — | — | **Always Free** |

**powder**, for one reason above all the others: *a watchdog must not live on the
thing it watches.* An agent on pancake cannot tell you pancake is down. powder is
already the external-monitoring host, it is off-site, it has idle capacity, and
it is free.

Caveat to verify first: powder is `aarch64`. Hermes is Python 3.11 + Node, so it
should be fine, but confirm before committing — the install script has not been
validated on ARM here.

## How it fits GitOps — the hard constraint

**The repo is the source of truth. `gitops-sync.timer` overwrites the live host
every 5 minutes.**

An agent that "fixes" a container by editing a compose file on the box, or by
running `docker compose up -d` with local changes, will have its work silently
reverted within five minutes — and will then likely observe the problem
recurring and try again. That is a loop worth designing out from the start.

So the agent gets exactly two ways to change things:

```
  observe  ─────────────────────────────►  report to Discord
     │
     └─── propose ───►  git branch + PR  ───►  human merges  ───► gitops-sync applies
                                                                    (existing path)
```

Anything persistent goes through git. The only direct actions it may ever take
are transient, reversible ones (see Phase 3). This also gives every change the
agent makes a diff, a review step, and an audit trail for free.

---

## Security model

An agent with SSH to every host, a shell, and an LLM deciding what to type has a
very large blast radius. Treat trust as something it earns in phases.

### Non-negotiables

1. **No inbound ports. No public exposure.** Use the Discord gateway
   (outbound-only) as the sole interface. This sidesteps web-dashboard exposure
   entirely — there is no dashboard to expose. Discord is already the
   notification channel (`scripts/notify.sh`), so this fits.
2. **Dedicated unprivileged user**, `hermes` — never `mez`. `mez` is in `wheel`
   with `NOPASSWD: ALL` and in `docker` (which is root-equivalent).
3. **Never in the `docker` group.** Use the existing
   `tecnativa/docker-socket-proxy` pattern from the arr stack instead, with
   `CONTAINERS=1`, `POST=0`, everything else `0`. Read-only container
   visibility, no exec, no ability to start or stop anything.
4. **No access to secrets.** Verify `hermes` cannot read:
   - `/etc/1password-service-account.env` — vault-wide token
   - `/etc/nas-*.credentials`
   - `/srv/docker/*/*/.env`
   - `/srv/docker/pancake/arr/config/seedbox/id_ed25519`
5. **Read-only sudo allowlist**, not blanket sudo. Roughly:
   `journalctl`, `systemctl status|is-active|list-timers|list-units`,
   `df`, `mount`, `findmnt`, `stat`, `ip -s link`, `smartctl`.
   No `restart`, no `stop`, no shell, no `-u root` variants.

### Prerequisites found on 2026-08-22

Fix both **before** adding any agent user:

- `/etc/1password-service-account.env` is `0644` — world-readable, and it grants
  read access to the entire Homelab vault (PIA, seedbox, Discord, deploy key).
  The README says `chmod 600`, but `gitops-sync.service` runs `User=mez`, so the
  correct fix is `chown root:mez` + `chmod 640`.
- `/etc/discord-webhook.env` does not exist, so `notify.sh` resolves no webhook
  on the host. Host-level alerting is currently inert — including
  `nas-mount-check.timer`. Create it (root:root, 0600) before relying on any
  alert path, agent or otherwise.

---

## Phase 1 — read-only observer

**Goal:** does it find anything a dashboard didn't?

Scope: SSH read-only to pancake, charm, powder. Discord gateway. No write access
anywhere, no sudo beyond the allowlist.

```bash
# On powder, as a dedicated user
sudo useradd -m -s /bin/bash hermes
sudo -u hermes bash -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash'
```

One scheduled task to start with — a daily health digest that answers the
questions today's investigation had to ask by hand:

- Any OOM kills since yesterday? (`journalctl -k | grep oom-kill`)
- Every mount in `/var/mnt/*` — does `stat` on it actually succeed?
- Any container `unhealthy`, or restarting repeatedly?
- Any systemd unit `failed`, or timer that has not fired when it should have?
- Newest file in each backup destination — is it younger than its schedule?
- Disk trend on `/var`, `/var/mnt/storage`, and the NAS shares
- `gitops-sync` — last successful run, and is the working tree clean?

**Exit criteria:** after ~2 weeks, has it surfaced at least one real problem
that existing monitoring missed? If not, stop here — the honest outcome is that
the deterministic checks are sufficient and the agent is not earning its cost.

## Phase 2 — propose changes via git

Only if Phase 1 earns it.

Add: a git checkout, a deploy key with **write access to branches only** (branch
protection on `main`, no direct push), and permission to open PRs.

The agent proposes; a human merges; `gitops-sync` deploys. Nothing changes about
the existing deployment path.

Good candidates: tuning a memory limit after observing pressure, adding a
healthcheck to a service that lacks one, adding an Uptime Kuma monitor for
something unmonitored, writing the deterministic check that retires one of its
own recurring findings.

**Exit criteria:** are the PRs mergeable roughly as written, or are they mostly
noise? Diff quality is the measure.

## Phase 3 — narrow autonomous action

Only if Phase 2 earns it, and deliberately small.

A short allowlist of **transient, reversible, idempotent** actions it may take
without asking — the kind of thing where waiting for a human costs more than the
action risks:

- `docker restart <container>` for a named allowlist
- `systemctl restart` for a named allowlist of mount and timer units

Everything else stays a proposal. Every autonomous action posts to Discord with
its reasoning. Keep a documented kill switch: `systemctl stop hermes` on powder,
plus revoking the SSH key.

Note that `autoheal` and `nas-mount-check` already cover the two obvious cases
here — which is the principle working as intended. If Phase 3's allowlist stays
empty because deterministic checks got there first, that is a success.

---

## Model and cost

No useful local inference is available: pancake's GTX 970M is Maxwell with 3GB
VRAM, and powder is CPU-only ARM. So this is an API-backed agent — Nous Portal,
OpenRouter, or Anthropic.

The cost driver is **cron frequency × context size**, and an agent that reads
logs pulls large contexts. Start at one digest per day, not hourly. Set a hard
spend cap at the provider. Revisit frequency only when there is evidence the
daily cadence is missing things.

## What this is explicitly not

- **Not a replacement** for Uptime Kuma, Diun, autoheal, or the systemd timers.
  It sits on top and reads them.
- **Not a config manager.** GitOps already does that, better and
  deterministically.
- **Not in the data path.** It never touches media, imports, or backups
  directly — it observes them.
- **Not a chatbot for the homelab.** The value is the scheduled digest and the
  correlation, not conversational lookup.

## Open decisions

1. **Trust ceiling** — is Phase 3 ever acceptable, or should this stay
   observe-and-propose permanently? Reasonable to say no to Phase 3 up front.
2. **Provider** — Nous Portal (native, subscription bundles web search and
   browser) vs OpenRouter (flexible) vs Anthropic (best tool-calling). Affects
   cost and quality.
3. **Discord vs Telegram** — Discord matches existing tooling; Telegram is the
   more common Hermes path and may be better supported.
4. **Does the agent get NAS/Unraid visibility?** The NAS is a 2GB Unraid box
   with no agent capacity, so this would mean SMB/SNMP polling from powder, or
   nothing. Its health was a factor in two of the four failures above.
5. **ARM validation** — confirm Hermes installs cleanly on `aarch64` before
   committing to powder.

## Success criteria

Worth keeping if, after a month:

- It has found ≥1 real problem existing monitoring missed
- It has caused ≥1 deterministic check to be written
- It has produced zero unexplained changes to the live system
- The daily digest is something you actually read

If the digest becomes noise you skim past, it has failed — turn it off.

## References

- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent)
- [Hermes Agent docs](https://hermes-agent.nousresearch.com/docs)
- `docs/powder-setup.md` — powder deployment
- `docs/1password-setup.md` — secrets handling
