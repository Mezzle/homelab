#!/usr/bin/env python3
"""
add-container-monitors.py — Add PUSH monitors for background containers.

Several homelab containers are background workers with no HTTP port to probe
(recyclarr, rclone-seedbox, backup, docktail, etc.). They are monitored via
Uptime Kuma PUSH monitors: a per-host heartbeat script (container-heartbeat.sh)
checks each container's docker state/health and pings the monitor's push URL
only while it is healthy. If a container dies or goes unhealthy, the ping stops
and Kuma flips the monitor Down -> fires the Discord + Hermes-agent webhooks.

This script is idempotent: it creates each monitor only if a monitor of the
same name does not already exist, attaches BOTH notifications (Discord=1,
Hermes=2), places it under the right host group, and prints the push token for
each so the heartbeat config can be generated.

Auth: reads UPK_USER/UPK_PASS (and optional UPK_TOTP_SECRET for a TOTP code)
from the environment. Run via add-container-monitors.sh which sources them from
1Password.

    python add-container-monitors.py            # create missing, print tokens
    python add-container-monitors.py --tokens    # just print existing tokens
"""

import os
import sys

try:
    from uptime_kuma_api import MonitorType, UptimeKumaApi
except ImportError:
    print("ERROR: pip install uptime-kuma-api")
    sys.exit(1)

UPK_URL = os.environ.get("UPK_URL", "http://localhost:3001")
UPK_USER = os.environ.get("UPK_USER", "")
UPK_PASS = os.environ.get("UPK_PASS", "")
UPK_TOTP = os.environ.get("UPK_TOTP", "")  # optional live 6-digit code

TOKENS_ONLY = "--tokens" in sys.argv

# Background containers to monitor, grouped by their host group name in Kuma.
# interval = how often Kuma expects a heartbeat (seconds); the heartbeat cron
# must run at least twice per interval. We use 120s interval / 60s cron.
CONTAINER_MONITORS: dict[str, list[str]] = {
    "pancake": [
        "recyclarr",
        "rclone-seedbox",
        "backup",
        "speedtest",
        "portainer",
        "docktail (pancake)",
    ],
    "charm": [
        "docktail (charm)",
    ],
    "powder": [
        "docktail (powder)",
    ],
}

PUSH_INTERVAL = 120
NOTIFICATION_IDS = [1, 2]  # 1 = Discord, 2 = Hermes Agent webhook


def log(msg: str) -> None:
    print(f"[add-monitors] {msg}")


def main() -> None:
    if not all([UPK_USER, UPK_PASS]):
        print("Usage: UPK_USER=.. UPK_PASS=.. [UPK_TOTP=123456] python add-container-monitors.py")
        sys.exit(1)

    with UptimeKumaApi(UPK_URL) as api:
        if UPK_TOTP:
            api.login(UPK_USER, UPK_PASS, UPK_TOTP)
        else:
            api.login(UPK_USER, UPK_PASS)
        log("Logged in.")

        mons = api.get_monitors()
        by_name = {m["name"]: m for m in mons}
        group_id = {m["name"]: m["id"] for m in mons if m.get("type") == "group"}

        if TOKENS_ONLY:
            for m in mons:
                if m.get("type") == "push":
                    print(f"TOKEN {m['name']}\t{m.get('pushToken')}")
            return

        created = 0
        tokens: dict[str, str] = {}

        for grp, names in CONTAINER_MONITORS.items():
            if grp not in group_id:
                log(f"FAIL: group '{grp}' not found — skipping its monitors")
                continue
            for name in names:
                if name in by_name:
                    m = by_name[name]
                    if m.get("type") == "push":
                        tokens[name] = m.get("pushToken", "")
                        log(f"SKIP: {name} (exists, id={m['id']})")
                    else:
                        log(f"WARN: {name} exists but is type={m.get('type')}, not push")
                    continue
                try:
                    result = api.add_monitor(
                        type=MonitorType.PUSH,
                        name=name,
                        interval=PUSH_INTERVAL,
                        parent=group_id[grp],
                        notificationIDList=NOTIFICATION_IDS,
                    )
                    mid = result["monitorID"]
                    # fetch the token that Kuma generated
                    fresh = api.get_monitor(mid)
                    tokens[name] = fresh.get("pushToken", "")
                    log(f"OK: {name} (id={mid}) token={tokens[name]}")
                    created += 1
                except Exception as e:
                    log(f"FAIL: {name} — {e}")

        log(f"Done. created={created}")
        print("---TOKENS---")
        for name, tok in tokens.items():
            print(f"{name}\t{tok}")


if __name__ == "__main__":
    main()
