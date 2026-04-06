#!/usr/bin/env python3
"""
seed-uptime-kuma.py — Create monitors for all homelab services.

Run once after Uptime Kuma is deployed and you've created an account:
    pip install uptime-kuma-api
    python scripts/seed-uptime-kuma.py

Required env vars:
    UPK_URL   — Uptime Kuma URL (default: https://uptime-kuma.${TAILNET}.ts.net)
    UPK_USER  — admin username
    UPK_PASS  — admin password
    TAILNET   — Tailscale tailnet name

Optional env vars (for deep checks):
    MQTT_USER / MQTT_PASS   — Mosquitto broker credentials
    MYSQL_USER / MYSQL_PASS — MySQL on charm
    MYSQL_DB                — MySQL database (default: homeassistant)

Idempotent — running again won't create duplicates (checks by name).
Monitors are organized into groups by server/function.

Pass --reset to delete all existing monitors and re-create from scratch.
"""

import os
import sys

try:
    from uptime_kuma_api import MonitorType, UptimeKumaApi
except ImportError:
    print("ERROR: pip install uptime-kuma-api")
    sys.exit(1)

RESET = "--reset" in sys.argv

# ── Configuration ────────────────────────────────────────────────────────────

TAILNET = os.environ.get("TAILNET", "")
UPK_URL = os.environ.get("UPK_URL", f"https://uptime-kuma.{TAILNET}.ts.net")
UPK_USER = os.environ.get("UPK_USER", "")
UPK_PASS = os.environ.get("UPK_PASS", "")

MQTT_USER = os.environ.get("MQTT_USER", "")
MQTT_PASS = os.environ.get("MQTT_PASS", "")
MYSQL_USER = os.environ.get("MYSQL_USER", "")
MYSQL_PASS = os.environ.get("MYSQL_PASS", "")
MYSQL_DB = os.environ.get("MYSQL_DB", "homeassistant")

if not all([UPK_USER, UPK_PASS, TAILNET]):
    print("Usage: UPK_USER=admin UPK_PASS=password TAILNET=tail1234 python seed-uptime-kuma.py")
    print("  UPK_URL defaults to https://uptime-kuma.<TAILNET>.ts.net")
    print()
    print("Optional (for deep checks):")
    print("  MQTT_USER / MQTT_PASS   — Mosquitto broker auth")
    print("  MYSQL_USER / MYSQL_PASS — MySQL connection check")
    sys.exit(1)

TS = f"{TAILNET}.ts.net"


def log(msg: str) -> None:
    print(f"[seed] {msg}")


# ── Monitor definitions ──────────────────────────────────────────────────────
#
# Structure: dict of group_name -> list of monitor dicts.
# Groups are created as MonitorType.GROUP, children get parent=<group_id>.

GROUPS: dict[str, list[dict]] = {
    # ═══════════════════════════════════════════════════════════════════════
    # pancake — Media, Photos, Music, Infra
    # ═══════════════════════════════════════════════════════════════════════
    "pancake": [
        dict(
            type=MonitorType.KEYWORD,
            name="Plex",
            url=f"https://plex.{TS}/identity",
            keyword="machineIdentifier",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="Sonarr",
            url=f"https://sonarr.{TS}/ping",
            keyword="Sonarr",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="Radarr",
            url=f"https://radarr.{TS}/ping",
            keyword="Radarr",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="Prowlarr",
            url=f"https://prowlarr.{TS}/ping",
            keyword="Prowlarr",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="Bazarr",
            url=f"https://bazarr.{TS}",
            keyword="Bazarr",
            interval=60,
        ),
        dict(
            type=MonitorType.HTTP,
            name="Scrypted",
            url=f"https://scrypted.{TS}",
            ignoreTls=True,
            interval=60,
        ),
        dict(
            type=MonitorType.JSON_QUERY,
            name="Immich",
            url=f"https://immich.{TS}/api/server/ping",
            jsonPath="res",
            expectedValue="pong",
            interval=60,
        ),
        dict(
            type=MonitorType.HTTP,
            name="Music Assistant",
            url=f"https://music.{TS}",
            interval=60,
        ),
        dict(
            type=MonitorType.HTTP,
            name="Portainer",
            url=f"https://portainer.{TS}",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="Homepage",
            url=f"https://homepage.{TS}",
            keyword="Homepage",
            interval=60,
        ),
        dict(
            type=MonitorType.PING,
            name="pancake (host)",
            hostname=f"pancake.{TS}",
            interval=120,
        ),
    ],

    # ═══════════════════════════════════════════════════════════════════════
    # charm — Home automation, DNS
    # ═══════════════════════════════════════════════════════════════════════
    "charm": [
        dict(
            type=MonitorType.HTTP,
            name="Zigbee2MQTT",
            url=f"https://z2m.{TS}",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="AdGuard Home",
            url=f"https://adguard.{TS}",
            keyword="AdGuard",
            interval=60,
        ),
        dict(
            type=MonitorType.PORT,
            name="Portainer Agent (charm)",
            hostname=f"portainer-charm.{TS}",
            port=9001,
            interval=60,
        ),
        dict(
            type=MonitorType.PING,
            name="charm (host)",
            hostname=f"charm.{TS}",
            interval=120,
        ),
    ],

    # ═══════════════════════════════════════════════════════════════════════
    # powder — Monitoring, Infra (Oracle Cloud)
    # ═══════════════════════════════════════════════════════════════════════
    "powder": [
        dict(
            type=MonitorType.HTTP,
            name="Uptime Kuma",
            url=f"https://uptime-kuma.{TS}",
            interval=60,
        ),
        dict(
            type=MonitorType.PORT,
            name="Portainer Agent (powder)",
            hostname=f"portainer-powder.{TS}",
            port=9001,
            interval=60,
        ),
        dict(
            type=MonitorType.PING,
            name="powder (host)",
            hostname=f"powder.{TS}",
            interval=120,
        ),
    ],

    # ═══════════════════════════════════════════════════════════════════════
    # External — non-Docker services (Dell box, Raspberry Pi)
    # ═══════════════════════════════════════════════════════════════════════
    "external": [
        dict(
            type=MonitorType.JSON_QUERY,
            name="Home Assistant",
            url="https://ha.67l.uk/api/",
            jsonPath="message",
            expectedValue="API running.",
            interval=60,
        ),
        dict(
            type=MonitorType.KEYWORD,
            name="AdGuard (Pi)",
            url="https://ag.67l.uk",
            keyword="AdGuard",
            interval=60,
        ),
    ],

    # ═══════════════════════════════════════════════════════════════════════
    # DNS ��� resolution checks across both AdGuard instances
    # ═══════════════════════════════════════════════════════════════════════
    "dns": [
        dict(
            type=MonitorType.DNS,
            name="DNS (AdGuard charm)",
            hostname="google.com",
            dns_resolve_server=f"adguard.{TS}",
            dns_resolve_type="A",
            port=53,
            interval=300,
        ),
        dict(
            type=MonitorType.DNS,
            name="DNS (AdGuard Pi)",
            hostname="google.com",
            dns_resolve_server="ag.67l.uk",
            dns_resolve_type="A",
            port=53,
            interval=300,
        ),
    ],
}


# ── Conditional monitors (require credentials) ──────────────────────────────

def add_conditional_monitors() -> None:
    """Add monitors that depend on optional credentials."""
    if MQTT_USER and MQTT_PASS:
        GROUPS["charm"].append(dict(
            type=MonitorType.MQTT,
            name="Mosquitto (MQTT)",
            hostname=f"mosquitto.{TS}",
            port=1883,
            mqttUsername=MQTT_USER,
            mqttPassword=MQTT_PASS,
            mqttTopic="uptime-kuma/ping",
            interval=60,
        ))
    else:
        log("INFO: Set MQTT_USER/MQTT_PASS to add MQTT broker check (falling back to TCP port)")
        GROUPS["charm"].append(dict(
            type=MonitorType.PORT,
            name="Mosquitto (TCP)",
            hostname=f"mosquitto.{TS}",
            port=1883,
            interval=60,
        ))

    if MYSQL_USER and MYSQL_PASS:
        GROUPS["charm"].append(dict(
            type=MonitorType.MYSQL,
            name="MySQL (charm)",
            databaseConnectionString=f"mysql://{MYSQL_USER}:{MYSQL_PASS}@charm:3306/{MYSQL_DB}",
            databaseQuery="SELECT 1",
            interval=120,
        ))
    else:
        log("INFO: Set MYSQL_USER/MYSQL_PASS to add MySQL check (falling back to TCP port)")
        GROUPS["charm"].append(dict(
            type=MonitorType.PORT,
            name="MySQL (TCP)",
            hostname="charm",
            port=3306,
            interval=120,
        ))


# ── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    add_conditional_monitors()

    log(f"Connecting to Uptime Kuma at {UPK_URL}...")
    with UptimeKumaApi(UPK_URL) as api:
        api.login(UPK_USER, UPK_PASS)
        log("Logged in.")

        # Build a name -> id map of existing monitors
        existing: dict[str, int] = {m["name"]: m["id"] for m in api.get_monitors()}
        log(f"Found {len(existing)} existing monitor(s).")

        if RESET and existing:
            log("--reset: deleting all existing monitors...")
            for name, mid in existing.items():
                try:
                    api.delete_monitor(mid)
                    log(f"  DEL: {name} (id={mid})")
                except Exception as e:
                    log(f"  DEL FAIL: {name} — {e}")
            existing.clear()

        created = 0
        skipped = 0
        failed = 0

        for group_name, monitors in GROUPS.items():
            # Create or find the group
            if group_name in existing:
                group_id = existing[group_name]
                log(f"SKIP: group '{group_name}' (already exists, id={group_id})")
            else:
                try:
                    result = api.add_monitor(
                        type=MonitorType.GROUP,
                        name=group_name,
                    )
                    group_id = result["monitorID"]
                    existing[group_name] = group_id
                    log(f"  OK: group '{group_name}' (id={group_id})")
                    created += 1
                except Exception as e:
                    log(f"FAIL: group '{group_name}' — {e}")
                    failed += 1
                    continue

            # Create child monitors under the group
            for monitor in monitors:
                name = monitor["name"]
                if name in existing:
                    log(f"SKIP: {name} (already exists)")
                    skipped += 1
                    continue
                try:
                    result = api.add_monitor(**monitor, parent=group_id)
                    existing[name] = result["monitorID"]
                    log(f"  OK: {name}")
                    created += 1
                except Exception as e:
                    log(f"FAIL: {name} — {e}")
                    failed += 1

        log(f"Done. created={created} skipped={skipped} failed={failed}")
        log(f"Open {UPK_URL} to review monitors and set up notifications.")


if __name__ == "__main__":
    main()
